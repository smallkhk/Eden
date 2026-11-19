"""Live Eden 5B on LightX2V: webcam frames in, rendered frames out.

LightX2V's EdenLive AR runner reads the proxy video one chunk at a time
(get_proxy_chunk -> recording_reader.next_chunk) and hands decoded chunks to a
callback. We swap the file reader for a live webcam feed and keep the output
streaming, so one "request" is one live session.
"""
import collections
import os
import random
import threading
import time

import numpy as np
try:
    import torch          # Eden only; the lite pod (face engines) runs without it
except ImportError:
    torch = None

LC = os.environ.get("LC", "/workspace/lc")
FPS = int(os.environ.get("LC_FPS", "24"))
H, W = 1280, 704   # portrait: whole face in frame
CHUNK = 3                       # latent frames per chunk = 12 output frames = 0.5 s
DEFAULT_PROMPT = "A realistic person facing the camera, natural lighting, detailed, consistent identity."


class StopLive(Exception):
    """Raised inside the generation loop to end or restart a session."""


class LiveFeed:
    """Webcam proxy frames, sampled every 4 output frames (one per latent frame)."""

    def __init__(self, fps=FPS, chunk=CHUNK):
        self.period = 4.0 / fps
        self.chunk = chunk
        self.cv = threading.Condition()
        self.latest = None
        self.samples = collections.deque(maxlen=chunk * 4)
        self.count = 0
        self.taken = 0
        self.interrupted = False
        self.closed = False
        threading.Thread(target=self._sample, name="lc-sampler", daemon=True).start()

    def push(self, rgb):
        """rgb: HxWx3 uint8 at model size."""
        with self.cv:
            self.latest = rgb

    def _sample(self):
        due = time.monotonic()
        while not self.closed:
            with self.cv:
                if self.latest is not None:
                    self.samples.append(self.latest)
                    self.count += 1
                    self.cv.notify_all()
            due += self.period
            lag = time.monotonic() - due
            if lag > 1.0:
                due = time.monotonic()
            time.sleep(max(0.0, due - time.monotonic()))

    def wait_first(self, timeout=15):
        with self.cv:
            return self.cv.wait_for(lambda: self.latest is not None or self.closed, timeout)

    def next_chunk(self):
        """Newest `chunk` samples, waiting for fresh ones so output stays real time."""
        with self.cv:
            ok = self.cv.wait_for(lambda: self.closed or self.interrupted or self.count - self.taken >= self.chunk, timeout=10)
            if self.closed or self.interrupted:
                self.interrupted = False
                raise StopLive("stopped")
            if not ok:
                raise StopLive("camera stalled")
            frames = list(self.samples)[-self.chunk:]
            while len(frames) < self.chunk:
                frames.insert(0, frames[0])
            self.taken = self.count
        return torch.from_numpy(np.stack(frames)).permute(3, 0, 1, 2).contiguous()   # C,T,H,W uint8

    def interrupt(self):
        with self.cv:
            self.interrupted = True
            self.cv.notify_all()

    def close(self):          # LightX2V calls this at the end of a request; only end_session really closes
        pass

    def shutdown(self):
        with self.cv:
            self.closed = True
            self.cv.notify_all()


class LiveSession:
    def __init__(self, max_seconds, on_frames, on_event):
        self.feed = LiveFeed()
        self.prompt = DEFAULT_PROMPT
        self.cover_path = None
        self.on_frames = on_frames          # callback(list of HxWx3 uint8)
        self.on_event = on_event            # callback(dict) -> data channel
        seconds = max(10, min(int(max_seconds), 600))
        self.num_frames = 4 * ((FPS * seconds) // 4) + 1
        self.restart = False
        self.ended = False


class LiveMixin:
    """Mixed into the LightX2V runner class at load time."""
    live = None

    @property
    def streaming_video_only(self):
        return True             # never collect the whole video in memory

    def load_recording(self, height, width, fps, prepared_cover=None):
        from lightx2v.models.input_encoders.hf.edenlive.recording import prepare_cover
        self.recording_reader = self.live.feed
        image = prepared_cover.result() if prepared_cover is not None else prepare_cover(self.input_info.image_path, height, width)
        return None, image, self.live.num_frames

    def _prepare_text_inputs(self, start):
        text = self.live.prompt or DEFAULT_PROMPT
        if text not in self.prompt_embeddings:
            original = self.input_info.prompt
            try:
                self.input_info.prompt = text
                self.prompt_embeddings[text] = self.run_text_encoder(self.input_info)
            finally:
                self.input_info.prompt = original
            self.live.on_event({"type": "prompt_applied"})
        self.inputs["text_encoder_output"] = self.prompt_embeddings[text]


class EdenEngine:
    """Loads Eden once, then runs one live session at a time on the GPU thread."""

    def __init__(self, set_stage):
        self.set_stage = set_stage
        self.runner = None
        self.base_request = None
        self.lock = threading.Lock()

    def load(self):
        from lightx2v.models.runners.registry import get_model_spec
        from lightx2v.models.runners.runner_factory import build_runner
        from lightx2v.utils.cli import parse_cli_inputs

        model_path = f"{LC}/models/EdenLive-x2v"
        placeholder = f"{LC}/placeholder_{W}x{H}.mp4"
        if not os.path.exists(placeholder):   # blank clip in the live orientation
            import av
            c = av.open(placeholder, "w"); st = c.add_stream("libx264", rate=24)
            st.width, st.height, st.pix_fmt = W, H, "yuv420p"
            for _ in range(48):
                for pk in st.encode(av.VideoFrame.from_ndarray(np.zeros((H, W, 3), np.uint8), format="rgb24")): c.mux(pk)
            for pk in st.encode(): c.mux(pk)
            c.close()
        cover = "/tmp/lc_cover_boot.png"
        from PIL import Image
        Image.new("RGB", (W, H), (40, 40, 40)).save(cover)
        argv = ["--model_cls", "wan22_edenlive_ar", "--task", "v2v", "--model_path", model_path,
                "--config_json", f"{LC}/runtime.json", "--prompt", DEFAULT_PROMPT,
                "--image_path", cover, "--video_path", placeholder, "--seed", "1"]
        args, config, request = parse_cli_inputs(argv)
        request.pop("save_result_path", None)
        self.base_request = request
        self.set_stage("loading Eden 5B (compile + warmup, a few minutes)")
        runner = build_runner(config)
        runner.__class__ = type("LiveEdenRunner", (LiveMixin, runner.__class__), {})
        get_model_spec(config["model_cls"]).prepare_runner(runner, args)
        self.runner = runner

    def run(self, live):
        """Blocking: generate until the session ends. Restarts on a new character."""
        with self.lock:
            r = self.runner
            r.live = live
            frame_times = collections.deque(maxlen=8)

            def on_chunk(pixels, index, is_last):
                from lightx2v.utils.streaming_video import video_chunk_to_uint8
                frames = video_chunk_to_uint8(pixels, layout="BCTHW", value_range=(-1, 1)).numpy()
                frame_times.append((time.monotonic(), len(frames)))
                if len(frame_times) > 1:
                    span = frame_times[-1][0] - frame_times[0][0]
                    n = sum(c for _, c in list(frame_times)[1:])
                    live.fps = n / span if span > 0 else None
                live.on_frames(list(frames))

            r.set_chunk_callback(on_chunk)
            while not live.ended:
                live.restart = False
                req = dict(self.base_request, prompt=live.prompt or DEFAULT_PROMPT, image_path=live.cover_path, seed=random.randint(1, 2**31 - 1))
                try:
                    r.run_request(r.prepare_request(req))
                    # clip finished: loop straight into the next one so the stream never ends
                except StopLive:
                    pass
                except Exception as e:  # report and stop this session; the engine stays loaded
                    live.on_event({"type": "error", "error": f"{type(e).__name__}: {e}"[:300], "retryable": False})
                    live.ended = True
                finally:
                    for fn in ("clear_warmup_state",):
                        try:
                            getattr(r, fn)()
                        except Exception:
                            pass
                    torch.cuda.empty_cache()
                if live.restart and not live.ended:
                    live.on_event({"type": "reset_applied"})
            r.live = None
            r.set_chunk_callback(None)


class StubEngine:
    """No GPU: echoes the webcam with a tint. For testing the app end to end."""

    def __init__(self, set_stage):
        self.set_stage = set_stage

    def load(self):
        self.set_stage("stub engine")

    def run(self, live):
        while not live.ended:
            live.restart = False
            try:
                while not live.ended and not live.restart:
                    chunk = live.feed.next_chunk().permute(1, 2, 3, 0).numpy()   # T,H,W,C
                    frames = []
                    for f in chunk:
                        g = f.copy()
                        g[..., 0] = np.clip(g[..., 0].astype(np.int16) + 60, 0, 255)
                        frames += [g] * 4
                    live.fps = 24.0
                    live.on_frames(frames)
            except StopLive:
                pass
            if live.restart and not live.ended:
                live.on_event({"type": "reset_applied"})
