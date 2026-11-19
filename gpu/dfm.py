"""Trained-face swap with DeepFaceLab .dfm models (the DeepFaceLive pipeline, ported).

SCRFD box -> InsightFace 2D106 landmarks -> 68-point mean -> DFL "uniform" alignment
(coverage 2.2) -> .dfm model -> face/celeb masks (erode 5, blur 25) -> RCT colour match
-> paste back. Frames are RGB uint8; the .dfm models work in BGR float [0,1].
"""
import os

import cv2
import numpy as np

from faceswap import MODELS, FFHQ_512, _align, _session, _umeyama

# DeepFaceLive xlib/face/FLandmarks2D.py
UNI_68 = np.float32([
    [0.000213256, 0.106454], [0.0752622, 0.038915], [0.18113, 0.0187482], [0.29077, 0.0344891], [0.393397, 0.0773906],
    [0.586856, 0.0773906], [0.689483, 0.0344891], [0.799124, 0.0187482], [0.904991, 0.038915], [0.98004, 0.106454],
    [0.490127, 0.203352], [0.490127, 0.307009], [0.490127, 0.409805], [0.490127, 0.515625],
    [0.36688, 0.587326], [0.426036, 0.609345], [0.490127, 0.628106], [0.554217, 0.609345], [0.613373, 0.587326],
    [0.121737, 0.216423], [0.334606, 0.231733], [0.645647, 0.231733], [0.858516, 0.216423],
    [0.254149, 0.780233], [0.726104, 0.780233]])
L106_TO_68 = [1, 9, 10, 11, 12, 13, 14, 15, 16, 2, 3, 4, 5, 6, 7, 8, 0, 0, 24, 23, 22, 21, 20, 19, 18, 32, 31, 30, 29, 28, 27, 26, 25, 17,
              43, 43, 48, 44, 49, 45, 51, 47, 50, 46,
              102, 97, 103, 98, 104, 99, 105, 100, 101, 101,
              72, 72, 73, 73, 74, 74, 86, 86, 77, 78, 78, 79, 80, 80, 85, 84, 84, 83,
              35, 35, 41, 40, 40, 42, 39, 39, 37, 33, 33, 36,
              89, 89, 95, 94, 94, 96, 93, 93, 91, 87, 87, 90,
              52, 52, 64, 64, 63, 63, 71, 71, 67, 67, 68, 68, 61, 61, 58, 58, 59, 59, 53, 53, 56, 56, 55, 55, 65, 65, 66, 66, 62, 62, 70, 70, 69, 69, 57, 57, 60, 60, 54, 54]


def _unit(a, b):
    v = (b - a).astype(np.float32)
    return v / (np.linalg.norm(v) + 1e-8)


def _affine3(src, dst):
    return cv2.getAffineTransform(np.float32(src), np.float32(dst))


class DFMSwapper:
    def __init__(self, dfm_path, detector, providers=None):
        providers = providers or [("CUDAExecutionProvider", {"cudnn_conv_algo_search": "HEURISTIC"}), "CPUExecutionProvider"]
        self.det = detector
        self.lmk = _session("2d106det.onnx", providers)
        import onnxruntime as ort
        so = ort.SessionOptions()
        so.log_severity_level = 3
        self.dfm = ort.InferenceSession(dfm_path, so, providers=providers)
        ins = self.dfm.get_inputs()
        self.res = int(ins[0].shape[1])
        self.morph = len(ins) == 2
        self.name = os.path.splitext(os.path.basename(dfm_path))[0]

    def landmarks(self, img, box):
        """InsightFace 2D106 on a 1.5x square crop around the box -> (106, 2) frame coords."""
        x0, y0, x1, y1 = box
        cx, cy, size = (x0 + x1) / 2, (y0 + y1) / 2, max(x1 - x0, y1 - y0) * 1.5
        s = 192.0 / size
        M = np.float32([[s, 0, 96 - cx * s], [0, s, 96 - cy * s]])
        crop = cv2.warpAffine(img, M, (192, 192), borderValue=0.0)
        blob = crop.astype(np.float32).transpose(2, 0, 1)[None]          # RGB, raw 0..255
        p = self.lmk.run(None, {self.lmk.get_inputs()[0].name: blob})[0].reshape(106, 2)
        p = (p + 1) * 96.0
        IM = cv2.invertAffineTransform(M)
        return p @ IM[:, :2].T + IM[:, 2]

    @staticmethod
    def cut_mat(l106, size, coverage=2.2):
        l68 = l106[L106_TO_68].reshape(68, 2, 2).mean(1)
        src = np.concatenate([l68[17:36], l68[36:37], l68[39:40], l68[42:43], l68[45:46], l68[48:49], l68[54:55]])
        m = np.vstack([_umeyama(src.astype(np.float64), UNI_68.astype(np.float64)), [0, 0, 1]])
        inv = np.linalg.inv(m)
        pts = np.float32([(0, 0), (1, 0), (1, 1), (0, 1), (0.5, 0.5)])
        g = (np.c_[pts, np.ones(5)] @ inv.T)[:, :2]
        tb, bt = _unit(g[0], g[2]), _unit(g[3], g[1])
        mod = np.linalg.norm(g[0] - g[4]) * coverage
        c = g[4]
        l_t = np.float32([c - tb * mod, c + bt * mod, c + tb * mod])
        return _affine3(l_t, [(0, 0), (size, 0), (size, size)])

    @staticmethod
    def _erode_blur(mask, erode=5, blur=25):
        H, W = mask.shape
        m = np.pad(mask, ((H, H), (W, W)))
        if erode > 0:
            m = cv2.erode(m, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3)), iterations=max(1, erode // 2))
        hc, wc = H + blur // 2, W + blur // 2
        m[:hc, :] = 0; m[-hc:, :] = 0; m[:, :wc] = 0; m[:, -wc:] = 0
        if blur > 0:
            m = cv2.GaussianBlur(m, (0, 0), blur * 0.25)
        return m[H:-H, W:-W]

    @staticmethod
    def _rct(target, source, mask):
        """Match target's LAB colour stats to source inside mask (float32 BGR 0..1)."""
        t, s = cv2.cvtColor(target, cv2.COLOR_BGR2LAB), cv2.cvtColor(source, cv2.COLOR_BGR2LAB)
        sel = mask > 0.5
        if sel.sum() < 50:
            return target
        out = t.copy()
        for c in range(3):
            tm, ts = t[..., c][sel].mean(), t[..., c][sel].std() + 1e-6
            sm, ss = s[..., c][sel].mean(), s[..., c][sel].std() + 1e-6
            out[..., c] = (t[..., c] - tm) * (ss / ts) + sm
        out[..., 0] = np.clip(out[..., 0], 0, 100)
        out[..., 1:] = np.clip(out[..., 1:], -127, 127)
        return cv2.cvtColor(out, cv2.COLOR_LAB2BGR)

    def process(self, frame, morph=0.75):
        faces = self.det.detect(frame)
        if not faces:
            return frame
        box = faces[0][0]
        l106 = self.landmarks(frame, box)
        M = self.cut_mat(l106, self.res)
        aligned = cv2.warpAffine(frame, M, (self.res, self.res), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
        bgr = aligned[..., ::-1].astype(np.float32) / 255.0
        feed = {"in_face:0": bgr[None]}
        if self.morph:
            feed["morph_value:0"] = np.float32([morph])
        face_mask, celeb, celeb_mask = self.dfm.run(None, feed)
        mask = self._erode_blur((face_mask[0, ..., 0] * celeb_mask[0, ..., 0]).astype(np.float32))
        celeb = self._rct(celeb[0].astype(np.float32), bgr, mask)
        H, W = frame.shape[:2]
        IM = cv2.invertAffineTransform(M)
        fm = cv2.warpAffine(mask, IM, (W, H))[..., None]
        fs = cv2.warpAffine(np.clip(celeb[..., ::-1] * 255, 0, 255).astype(np.float32), IM, (W, H), flags=cv2.INTER_LINEAR)
        out = (frame.astype(np.float32) * (1 - fm) + fs * fm).astype(np.uint8)
        return self._enhance(out, faces[0][1]) if self.enhance else out

    # GFPGAN 1.4 pass on the swapped face: low-res (224/320) DFM output -> sharp eyes and skin.
    _gfp = None

    @property
    def enhance(self):
        if os.environ.get("LC_DFM_ENHANCE", "1") != "1":
            return False
        if DFMSwapper._gfp is None:
            try:
                DFMSwapper._gfp = _session("GFPGANv1.4.onnx", [("CUDAExecutionProvider", {}), "CPUExecutionProvider"])
            except Exception as e:
                print("dfm enhancer unavailable:", e, flush=True)
                DFMSwapper._gfp = False
        return bool(DFMSwapper._gfp)

    _gmask = None

    def _enhance(self, frame, kps):
        M5 = _align(kps, FFHQ_512, 512)
        crop = cv2.warpAffine(frame, M5, (512, 512), borderMode=cv2.BORDER_REPLICATE)
        blob = ((crop.astype(np.float32) / 255.0 - 0.5) / 0.5).transpose(2, 0, 1)[None]
        out = DFMSwapper._gfp.run(None, {"input": blob})[0][0]
        sharp = ((out.transpose(1, 2, 0) + 1) * 127.5).clip(0, 255).astype(np.uint8)
        if DFMSwapper._gmask is None:
            m = np.zeros((512, 512), np.float32)
            m[40:472, 40:472] = 1
            DFMSwapper._gmask = cv2.GaussianBlur(m, (0, 0), 15)
        H, W = frame.shape[:2]
        IM = cv2.invertAffineTransform(M5)
        ws = cv2.warpAffine(sharp, IM, (W, H)).astype(np.float32)
        wm = cv2.warpAffine(DFMSwapper._gmask, IM, (W, H))[..., None]
        return (frame.astype(np.float32) * (1 - wm) + ws * wm).astype(np.uint8)


class DFMEngine:
    """Same interface as the other engines. Downloads the .dfm once onto the volume."""

    def __init__(self):
        import threading
        self.lock = threading.Lock()
        self.sw = None
        self.url = None

    def load(self, url):
        import urllib.request
        from faceswap import Detector
        LC = os.environ.get("LC", "/workspace/lc")
        os.makedirs(f"{LC}/dfm", exist_ok=True)
        path = f"{LC}/dfm/" + os.path.basename(url.split("?")[0])
        if not os.path.exists(path):
            urllib.request.urlretrieve(url, path + ".part")
            os.replace(path + ".part", path)
        if self.sw is None or self.url != url:
            self.sw = DFMSwapper(path, Detector())
            self.url = url
            self.sw.process(np.zeros((1280, 704, 3), np.uint8))      # warm up

    def run(self, live, url):
        import time
        with self.lock:
            live.on_event({"type": "note", "note": "Loading trained face…"})
            self.load(url)
            last, times = None, []
            while not live.ended:
                if live.restart:
                    live.restart = False
                    live.on_event({"type": "reset_applied"})
                frame = live.feed.latest
                if frame is None or frame is last:
                    time.sleep(0.003)
                    continue
                last = frame
                live.on_frames([self.sw.process(frame)])
                now = time.monotonic()
                times = (times + [now])[-24:]
                if len(times) > 1:
                    live.fps = (len(times) - 1) / (times[-1] - times[0])
