"""Live Portrait: the whole reference photo comes alive, driven by your head and face.

Official LivePortrait (KwaiVGI) networks used as a library; faces are found with the same
SCRFD detector as face swap (5 keypoints -> LivePortrait crop), so no insightface build.
Motion is relative to the first camera frame (your neutral pose), like the official
"pose-friendly" relative mode. Frames are RGB uint8 HxWx3.
"""
import os
import sys
import threading
import time

import cv2
import numpy as np
import torch

LC = os.environ.get("LC", "/workspace/lc")
LP_DIR = os.environ.get("LC_LP_DIR", os.path.join(LC, "lp"))


def _fit_portrait(img, W, H, face_xy=None):
    """Cover-fit the reference into W x H, keeping the face in frame (upper-middle)."""
    h, w = img.shape[:2]
    s = max(W / w, H / h)
    nw, nh = int(round(w * s)), int(round(h * s))
    big = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_AREA if s < 1 else cv2.INTER_CUBIC)
    cx, cy = (face_xy[0] * s, face_xy[1] * s) if face_xy is not None else (nw / 2, nh / 2)
    x0 = int(np.clip(cx - W / 2, 0, nw - W))
    y0 = int(np.clip(cy - H * 0.4, 0, nh - H))
    return big[y0:y0 + H, x0:x0 + W].copy()


class LivePortrait:
    def __init__(self, detector, cpu=False):
        if LP_DIR not in sys.path:
            sys.path.insert(0, LP_DIR)
        from src.config.inference_config import InferenceConfig
        from src.live_portrait_wrapper import LivePortraitWrapper
        from src.utils.crop import crop_image, prepare_paste_back, paste_back
        from src.utils.camera import get_rotation_matrix
        self._crop, self._prep_mask, self._paste, self._rot = crop_image, prepare_paste_back, paste_back, get_rotation_matrix
        self.cfg = InferenceConfig(flag_force_cpu=cpu, flag_use_half_precision=not cpu)
        self.lp = LivePortraitWrapper(self.cfg)
        self.det = detector
        self.src = None
        self.d0 = None              # driving reference (first frame / recalibration)
        self.smooth = None

    def set_source(self, img_rgb, W, H):
        faces = self.det.detect(img_rgb)
        if not faces:
            return False
        box = faces[0][0]
        canvas = _fit_portrait(img_rgb, W, H, ((box[0] + box[2]) / 2, (box[1] + box[3]) / 2))
        faces = self.det.detect(canvas)
        if not faces:
            return False
        crop = self._crop(canvas, faces[0][1], dsize=512, scale=2.3, vy_ratio=-0.125, flag_do_rot=True)
        with torch.no_grad():
            I_s = self.lp.prepare_source(cv2.resize(crop["img_crop"], (256, 256), interpolation=cv2.INTER_AREA))
            info = self.lp.get_kp_info(I_s)
            self.src = {
                "canvas": canvas, "M_c2o": crop["M_c2o"], "info": info, "x_c": info["kp"],
                "R": self._rot(info["pitch"], info["yaw"], info["roll"]),
                "f": self.lp.extract_feature_3d(I_s), "x": self.lp.transform_keypoint(info),
                "mask": self._prep_mask(self.cfg.mask_crop, crop["M_c2o"], dsize=(W, H)),
            }
        self.d0 = None
        self.smooth = None
        return True

    def recalibrate(self):
        self.d0 = None
        self.smooth = None

    @torch.no_grad()
    def process(self, frame):
        s = self.src
        if s is None:
            return frame
        faces = self.det.detect(frame)
        if not faces:
            return None                                   # caller repeats the last output
        crop = self._crop(frame, faces[0][1], dsize=512, scale=2.2, vy_ratio=-0.1, flag_do_rot=True)
        I_d = self.lp.prepare_source(cv2.resize(crop["img_crop"], (256, 256), interpolation=cv2.INTER_AREA))
        d = self.lp.get_kp_info(I_d)
        R_d = self._rot(d["pitch"], d["yaw"], d["roll"])
        if self.d0 is None:
            self.d0 = (d, R_d)
        d0, R_d0 = self.d0
        R_new = (R_d @ R_d0.permute(0, 2, 1)) @ s["R"]
        delta = s["info"]["exp"] + (d["exp"] - d0["exp"])
        scale = s["info"]["scale"] * (d["scale"] / d0["scale"])
        t = s["info"]["t"] + (d["t"] - d0["t"])
        t[..., 2] = 0
        x_d = scale * (s["x_c"] @ R_new + delta) + t
        self.smooth = x_d if self.smooth is None else 0.6 * x_d + 0.4 * self.smooth   # light jitter filter
        x_d = self.lp.stitching(s["x"], self.smooth)
        out = self.lp.warp_decode(s["f"], s["x"], x_d)
        I_p = self.lp.parse_output(out["out"])[0]
        return self._paste(I_p, s["M_c2o"], s["canvas"], s["mask"])


class PortraitEngine:
    """Same interface as EdenEngine / FaceSwapEngine."""

    def __init__(self, W=704, H=1280):
        self.W, self.H = W, H
        self.lp = None
        self.lock = threading.Lock()

    def load(self):
        if self.lp is None:
            from faceswap import Detector
            self.lp = LivePortrait(Detector())

    def _load_source(self, live):
        img = cv2.imread(live.cover_path or "", cv2.IMREAD_COLOR) if live.cover_path else None
        ok = img is not None and self.lp.set_source(cv2.cvtColor(img, cv2.COLOR_BGR2RGB), self.W, self.H)
        if not ok:
            live.on_event({"type": "error", "error": "No face found in the character photo. Use a clear, front-facing photo.", "retryable": True})
        return ok

    def run(self, live):
        with self.lock:
            self.load()
            have = self._load_source(live)
            cover, last, out_last, times = live.cover_path, None, None, []
            while not live.ended:
                if live.restart or live.cover_path != cover:
                    live.restart = False
                    cover = live.cover_path
                    have = self._load_source(live)
                    live.on_event({"type": "reset_applied"})
                frame = live.feed.latest
                if frame is None or frame is last:
                    time.sleep(0.003)
                    continue
                last = frame
                out = self.lp.process(frame) if have else frame
                if out is None:                  # no face this frame: hold the last picture
                    out = out_last if out_last is not None else (self.lp.src["canvas"] if have else frame)
                out_last = out
                live.on_frames([out])
                now = time.monotonic()
                times = (times + [now])[-24:]
                if len(times) > 1:
                    live.fps = (len(times) - 1) / (times[-1] - times[0])
