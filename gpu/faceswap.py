"""Live face swap (Deep-Live-Cam pipeline) on ONNX Runtime.

SCRFD face detector -> ArcFace identity of the character photo -> inswapper_128 swap
-> optional GFPGAN 1.4 sharpening, pasted back with a feathered mask. Runs on the same
pod and stream as Eden; plain onnxruntime + numpy + OpenCV, no insightface build.
Frames are RGB uint8 HxWx3 throughout.
"""
import os
import threading
import time

import cv2
import numpy as np

MODELS = os.path.join(os.environ.get("LC", "/workspace/lc"), "dlc", "models")

# 5-point templates (eyes, nose, mouth corners)
ARCFACE_112 = np.array([[38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366],
                        [41.5493, 92.3655], [70.7299, 92.2041]], np.float32)
FFHQ_512 = np.array([[192.98138, 239.94708], [318.90277, 240.19360], [256.63416, 314.01935],
                     [201.26117, 371.41043], [313.08905, 371.15118]], np.float32)


def _session(name, providers):
    try:
        import torch  # noqa: F401  - on the Eden pod, loads the CUDA/cuDNN libs ORT links to
    except ImportError:
        pass
    import onnxruntime as ort
    try:
        ort.preload_dlls()
    except Exception:
        pass
    so = ort.SessionOptions()
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    so.log_severity_level = 3
    sess = ort.InferenceSession(os.path.join(MODELS, name), so, providers=providers)
    if any((p[0] if isinstance(p, tuple) else p) == "CUDAExecutionProvider" for p in providers) \
            and "CUDAExecutionProvider" not in sess.get_providers():
        raise RuntimeError(f"face swap: GPU provider unavailable for {name} (would be too slow on CPU)")
    return sess


def _umeyama(src, dst):
    """Least-squares similarity transform src -> dst (2x3), as insightface/skimage."""
    n = src.shape[0]
    mu_s, mu_d = src.mean(0), dst.mean(0)
    sc, dc = src - mu_s, dst - mu_d
    A = dc.T @ sc / n
    d = np.ones(2)
    if np.linalg.det(A) < 0:
        d[1] = -1
    U, S, Vt = np.linalg.svd(A)
    R = U @ np.diag(d) @ Vt
    scale = (S * d).sum() / sc.var(0).sum()
    t = mu_d - scale * R @ mu_s
    return np.hstack([scale * R, t[:, None]]).astype(np.float32)


def _align(kps, template, size):
    if template is FFHQ_512:
        dst = template * (size / 512.0)
    elif size % 112 == 0:
        dst = template * (size / 112.0)
    else:                                   # insightface: 128 crops use ratio size/128 and +8*ratio in x
        r = size / 128.0
        dst = template * r
        dst = dst + np.array([8.0 * r, 0], np.float32)
    return _umeyama(kps.astype(np.float64), dst.astype(np.float64))


class Detector:
    """SCRFD (det_10g) face detector: returns [(box, 5 keypoints, score)], biggest face first."""

    def __init__(self, providers=None):
        providers = providers or [("CUDAExecutionProvider", {"cudnn_conv_algo_search": "HEURISTIC"}), "CPUExecutionProvider"]
        self.det = _session("det_10g.onnx", providers)
        self._centers = {}

    def detect(self, img, size=640, thresh=0.5):
        h, w = img.shape[:2]
        scale = size / max(h, w)
        nh, nw = int(round(h * scale)), int(round(w * scale))
        canvas = np.zeros((size, size, 3), np.uint8)
        canvas[:nh, :nw] = cv2.resize(img, (nw, nh))
        blob = ((canvas.astype(np.float32) - 127.5) / 128.0).transpose(2, 0, 1)[None]
        outs = self.det.run(None, {self.det.get_inputs()[0].name: blob})
        boxes, kpss, scores = [], [], []
        for i, stride in enumerate((8, 16, 32)):
            sc = outs[i].reshape(-1)
            bb = outs[i + 3].reshape(-1, 4) * stride
            kp = outs[i + 6].reshape(-1, 10) * stride
            gh = gw = size // stride
            key = (gh, gw, stride)
            if key not in self._centers:
                c = np.stack(np.mgrid[:gh, :gw][::-1], axis=-1).astype(np.float32).reshape(-1, 2) * stride
                self._centers[key] = np.repeat(c, 2, axis=0)      # 2 anchors per cell
            c = self._centers[key]
            keep = np.where(sc >= thresh)[0]
            if not len(keep):
                continue
            cc = c[keep]
            b = np.concatenate([cc - bb[keep, :2], cc + bb[keep, 2:]], axis=1)
            k = (kp[keep].reshape(-1, 5, 2) + cc[:, None, :])
            boxes.append(b); kpss.append(k); scores.append(sc[keep])
        if not boxes:
            return []
        boxes = np.concatenate(boxes) / scale
        kpss = np.concatenate(kpss) / scale
        scores = np.concatenate(scores)
        idx = cv2.dnn.NMSBoxes([[float(x1), float(y1), float(x2 - x1), float(y2 - y1)] for x1, y1, x2, y2 in boxes],
                               scores.tolist(), thresh, 0.4)
        idx = np.array(idx).reshape(-1)
        faces = [(boxes[i], kpss[i], float(scores[i])) for i in idx]
        faces.sort(key=lambda f: (f[0][2] - f[0][0]) * (f[0][3] - f[0][1]), reverse=True)   # biggest first
        return faces



class Smoother:
    """Temporal filter for face points: removes frame-to-frame jitter (the 'swimming' face),
    snaps straight to the new position on fast moves so it never lags behind."""

    def __init__(self, alpha=0.55):
        self.alpha, self.prev = alpha, None

    def __call__(self, pts, size):
        pts = np.asarray(pts, np.float32)
        if self.prev is None or self.prev.shape != pts.shape:
            self.prev = pts
            return pts
        move = float(np.abs(pts - self.prev).mean())
        a = 1.0 if move > 0.08 * size else self.alpha + (1 - self.alpha) * min(1.0, move / (0.04 * size))
        self.prev = a * pts + (1 - a) * self.prev
        return self.prev

    def reset(self):
        self.prev = None


SWAP_MODEL = os.environ.get("LC_SWAP_MODEL", "hyperswap_1a_256")   # or hyperswap_1c_256 / inswapper_128_fp16


class FaceSwapper:
    def __init__(self, providers=None, enhance=None, model=None):
        providers = providers or [("CUDAExecutionProvider", {"cudnn_conv_algo_search": "HEURISTIC"}), "CPUExecutionProvider"]
        self.model = model or SWAP_MODEL
        self.hyper = self.model.startswith("hyperswap")
        if enhance is None:
            enhance = not self.hyper          # HyperSwap is sharp on its own; GFPGAN only helps the 128 inswapper
        self.detector = Detector(providers)
        self.rec = _session("w600k_r50.onnx", providers)
        self.swap = _session(self.model + ".onnx", providers)
        self.gfp = _session("GFPGANv1.4.onnx", providers) if enhance else None
        self.emap = None if self.hyper else np.load(os.path.join(MODELS, "emap.npy")).astype(np.float32)
        self.enhance = enhance
        self.source = None          # (1, 512): normed ArcFace (HyperSwap) or inswapper latent
        self._mask128 = self._feather(128, 0.1)
        self._mask256 = self._feather(256, 0.06)
        self._mask512 = self._feather(512, 0.1)

    def detect(self, img, size=640, thresh=0.5):
        return self.detector.detect(img, size, thresh)

    # ---------- identity ----------
    def set_source(self, img):
        """img: RGB photo of the character. Returns False if no face is found."""
        faces = self.detect(img)
        if not faces:
            return False
        M = _align(faces[0][1], ARCFACE_112, 112)
        face = cv2.warpAffine(img, M, (112, 112), borderValue=0.0)
        blob = ((face.astype(np.float32) - 127.5) / 127.5).transpose(2, 0, 1)[None]
        emb = self.rec.run(None, {self.rec.get_inputs()[0].name: blob})[0].reshape(1, -1)
        emb = emb / np.linalg.norm(emb)
        if self.hyper:
            self.source = emb.astype(np.float32)
        else:
            latent = emb @ self.emap
            self.source = (latent / np.linalg.norm(latent)).astype(np.float32)
        return True

    # ---------- swap ----------
    @staticmethod
    def _feather(size, border):
        m = np.zeros((size, size), np.float32)
        b = int(size * border)
        m[b:size - b, b:size - b] = 1.0
        k = max(3, (b // 2) * 2 + 1)
        return cv2.GaussianBlur(m, (k, k), 0)

    @staticmethod
    def _paste(frame, face, M, mask):
        h, w = frame.shape[:2]
        IM = cv2.invertAffineTransform(M)
        warped = cv2.warpAffine(face, IM, (w, h), borderMode=cv2.BORDER_REPLICATE)
        m = cv2.warpAffine(mask, IM, (w, h))[..., None]
        ys, xs = np.nonzero(m[..., 0] > 0.001)
        if not len(ys):
            return frame
        y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
        out = frame.copy()
        roi = out[y0:y1, x0:x1].astype(np.float32)
        mm = m[y0:y1, x0:x1]
        out[y0:y1, x0:x1] = (roi * (1 - mm) + warped[y0:y1, x0:x1].astype(np.float32) * mm).astype(np.uint8)
        return out

    def process(self, frame, max_faces=1):
        if self.source is None:
            return frame
        faces = self.detect(frame)[:max_faces]
        if not hasattr(self, "_smooth"):
            self._smooth = Smoother()
        if not faces:
            self._smooth.reset()
        if len(faces) == 1:
            b = faces[0][0]
            faces = [(b, self._smooth(faces[0][1], b[2] - b[0]), faces[0][2])]
        for _box, kps, _score in faces:
            if self.hyper:
                M = _align(kps, ARCFACE_112, 256)          # facefusion "arcface_128" template at 256 px
                crop = cv2.warpAffine(frame, M, (256, 256), borderMode=cv2.BORDER_REPLICATE)
                blob = ((crop.astype(np.float32) / 255.0 - 0.5) / 0.5).transpose(2, 0, 1)[None]
                pred, pmask = self.swap.run(None, {"target": blob, "source": self.source})
                fake = ((pred[0].transpose(1, 2, 0) * 0.5 + 0.5) * 255).clip(0, 255).astype(np.uint8)
                mask = np.clip(pmask[0, 0], 0, 1).astype(np.float32)
                mask = cv2.GaussianBlur(mask, (0, 0), 3) * self._mask256      # soft edges, model's own face mask
                frame = self._paste(frame, fake, M, mask)
            else:
                M = _align(kps, ARCFACE_112, 128)
                crop = cv2.warpAffine(frame, M, (128, 128), borderValue=0.0)
                blob = (crop.astype(np.float32) / 255.0).transpose(2, 0, 1)[None]
                pred = self.swap.run(None, {"target": blob, "source": self.source})[0][0]
                fake = (pred.transpose(1, 2, 0) * 255).clip(0, 255).astype(np.uint8)
                frame = self._paste(frame, fake, M, self._mask128)
            if self.gfp is not None and self.enhance:
                M5 = _align(kps, FFHQ_512, 512)
                crop = cv2.warpAffine(frame, M5, (512, 512), borderMode=cv2.BORDER_REPLICATE)
                blob = ((crop.astype(np.float32) / 255.0 - 0.5) / 0.5).transpose(2, 0, 1)[None]
                out = self.gfp.run(None, {"input": blob})[0][0]
                sharp = ((out.transpose(1, 2, 0) + 1) * 127.5).clip(0, 255).astype(np.uint8)
                frame = self._paste(frame, sharp, M5, self._mask512)
        return frame


class FaceSwapEngine:
    """Same interface as EdenEngine: load() once, run(live) per session."""

    def __init__(self, set_stage=None):
        self.set_stage = set_stage or (lambda s: None)
        self.fs = None
        self.lock = threading.Lock()

    def load(self):
        if self.fs is None:
            self.set_stage("loading face swap")
            self.fs = FaceSwapper()
            dummy = np.zeros((1280, 704, 3), np.uint8)
            self.fs.process(dummy)            # warm up the detector

    def _load_source(self, live):
        img = cv2.imread(live.cover_path or "", cv2.IMREAD_COLOR) if live.cover_path else None
        ok = img is not None and self.fs.set_source(cv2.cvtColor(img, cv2.COLOR_BGR2RGB))
        if not ok:
            live.on_event({"type": "error", "error": "No face found in the character photo. Use a clear, front-facing photo.", "retryable": True})
        return ok

    def run(self, live):
        with self.lock:
            self.load()
            self._load_source(live)
            cover = live.cover_path
            last = None
            times = []
            while not live.ended:
                if live.restart or live.cover_path != cover:
                    live.restart = False
                    cover = live.cover_path
                    self._load_source(live)
                    live.on_event({"type": "reset_applied"})
                frame = live.feed.latest
                if frame is None or frame is last:
                    time.sleep(0.003)
                    continue
                last = frame
                out = self.fs.process(frame)
                live.on_frames([out])
                now = time.monotonic()
                times.append(now)
                times = times[-24:]
                if len(times) > 1:
                    live.fps = (len(times) - 1) / (times[-1] - times[0])


class FaceLock:
    """Runs HyperSwap on Eden's output frames in its own thread so Eden is never slowed down.
    Frames pass through untouched until the swapper is loaded and while no source face is set."""

    def __init__(self, get_swapper, push):
        import queue
        self.get_swapper, self.push = get_swapper, push
        self.q = queue.Queue(maxsize=3)
        self.enabled = True
        self.fs = None
        self.cover = None
        self.have_source = False
        self.stop = False
        self.t = threading.Thread(target=self._loop, name="lc-facelock", daemon=True)
        self.t.start()

    def frames(self, frames):
        if not self.enabled:
            return self.push(frames)
        try:
            self.q.put_nowait(frames)
        except Exception:                 # behind: drop the oldest chunk to keep latency low
            try:
                self.q.get_nowait()
            except Exception:
                pass
            self.q.put_nowait(frames)

    def set_cover(self, path):
        self.cover = path

    def close(self):
        self.stop = True
        self.q.put(None)

    def _loop(self):
        loaded_for = None
        while True:
            frames = self.q.get()
            if frames is None or self.stop:
                return
            try:
                if self.fs is None:
                    self.fs = self.get_swapper()
                if self.cover != loaded_for:
                    loaded_for = self.cover
                    img = cv2.imread(self.cover or "", cv2.IMREAD_COLOR) if self.cover else None
                    self.have_source = img is not None and self.fs.set_source(cv2.cvtColor(img, cv2.COLOR_BGR2RGB))
                if self.enabled and self.have_source:
                    frames = [self.fs.process(np.ascontiguousarray(f)) for f in frames]
            except Exception as e:
                print("face lock:", type(e).__name__, e, flush=True)
            self.push(frames)
