"""LiveChar GPU server: WebRTC webcam -> Eden Live 5B -> WebRTC video.

Endpoints (port LC_PORT, reached through RunPod's HTTPS proxy):
  GET  /health   {"ready", "stage", "busy", "profile"}
  POST /offer    {"sdp", "type", "token"} -> {"sdp", "type"}

The browser opens a data channel named "control" and speaks the same messages
as fal's Eden endpoint: configure / prompt / reset / ping / stop, and gets back
configured / prompt_applied / reset_applied / pong / stats / error / stream_exhausted.
Media goes through the coturn relay that start.sh runs on TCP 3478.
"""
import asyncio
import base64
import collections
import fractions
import hashlib
import hmac
import io
import json
import os
import subprocess
import threading
import time

import numpy as np
from aiohttp import ClientSession, ClientTimeout, web
from aiortc import RTCPeerConnection, RTCSessionDescription, VideoStreamTrack
from av import VideoFrame
from PIL import Image

from live_runner import FPS, H, W, EdenEngine, LiveSession, StubEngine

LC = os.environ.get("LC", "/workspace/lc")
PORT = int(os.environ.get("LC_PORT", "8000"))
SECRET = os.environ.get("LC_SECRET", "")
STUB = os.environ.get("LC_STUB") == "1"

state = {"ready": False, "stage": "starting", "busy": False, "profile": None}
engine = None
pcs = set()
current = {"sid": None, "apply": None}     # the one live session (one GPU)


def set_stage(s):
    state["stage"] = s
    print(">>>", s, flush=True)


# ---------- auth: token minted by the LiveChar server with the shared secret ----------
def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def check_token(token):
    try:
        body, sig = str(token).split(".")
        want = base64.urlsafe_b64encode(hmac.new(SECRET.encode(), body.encode(), hashlib.sha256).digest()).rstrip(b"=").decode()
        if not SECRET or not hmac.compare_digest(sig, want):
            return None
        claims = json.loads(b64d(body))
        return claims if claims.get("exp", 0) > time.time() else None
    except Exception:
        return None


# ---------- media ----------
class OutputTrack(VideoStreamTrack):
    """Plays generated frames at 24 fps; keeps latency low by dropping backlog."""

    def __init__(self):
        super().__init__()
        self.q = collections.deque()
        self.lock = threading.Lock()
        self.last = np.zeros((H, W, 3), np.uint8)
        self.start = None
        self.n = 0

    def push(self, frames):
        with self.lock:
            self.q.extend(frames)
            while len(self.q) > 30:          # > ~1.2 s behind: catch up
                self.q.popleft()

    async def recv(self):
        if self.start is None:
            self.start = time.monotonic()
        self.n += 1
        wait = self.start + self.n / FPS - time.monotonic()
        if wait > 0:
            await asyncio.sleep(wait)
        elif wait < -1:
            self.start, self.n = time.monotonic(), 0
        with self.lock:
            if self.q:
                self.last = self.q.popleft()
        frame = VideoFrame.from_ndarray(self.last, format="rgb24")
        frame.pts = int(self.n * 90000 / FPS)
        frame.time_base = fractions.Fraction(1, 90000)
        return frame


async def read_camera(track, live):
    try:
        while not live.ended:
            frame = await track.recv()
            if frame.width != W or frame.height != H:
                # cover-crop to 1280x704
                scale = max(W / frame.width, H / frame.height)
                frame = frame.reformat(width=round(frame.width * scale), height=round(frame.height * scale))
                img = frame.to_ndarray(format="rgb24")
                y, x = (img.shape[0] - H) // 2, (img.shape[1] - W) // 2
                img = img[y:y + H, x:x + W]
            else:
                img = frame.to_ndarray(format="rgb24")
            live.feed.push(np.ascontiguousarray(img))
    except Exception:
        pass


async def load_cover(msg, live):
    """Character frame from image_url / data URL; falls back to the current camera frame."""
    src = msg.get("image_url") or msg.get("image")
    img = None
    try:
        if isinstance(src, str) and src.startswith("data:image/"):
            img = Image.open(io.BytesIO(base64.b64decode(src.split(",", 1)[1])))
        elif isinstance(src, str) and src.startswith("https://"):
            async with ClientSession(timeout=ClientTimeout(total=20)) as s:
                async with s.get(src) as r:
                    img = Image.open(io.BytesIO(await r.read()))
    except Exception as e:
        print("cover load failed:", e, flush=True)
    if img is None:
        await asyncio.get_running_loop().run_in_executor(None, live.feed.wait_first)
        img = Image.fromarray(live.feed.latest if live.feed.latest is not None else np.zeros((H, W, 3), np.uint8))
    path = f"/tmp/lc_cover_{int(time.time() * 1000)}.png"
    img.convert("RGB").save(path)
    return path


# ---------- signaling ----------
CORS = {"Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "Content-Type", "Access-Control-Allow-Methods": "GET, POST, OPTIONS"}


async def health(_req):
    env = os.path.exists(f"{LC}/env/.done")
    return web.json_response({**state, "env": env, "light": bool(os.environ.get("LC_LIGHT"))}, headers=CORS)


async def options(_req):
    return web.Response(headers=CORS)


async def offer(req):
    body = await req.json()
    claims = check_token(body.get("token"))
    if not claims:
        return web.json_response({"error": "Not authorised"}, status=403, headers=CORS)
    if not state["ready"]:
        return web.json_response({"error": f"GPU not ready: {state['stage']}"}, status=503, headers=CORS)
    if state["busy"]:
        return web.json_response({"error": "GPU is busy with another session"}, status=409, headers=CORS)
    state["busy"] = True

    loop = asyncio.get_running_loop()
    pc = RTCPeerConnection()
    pcs.add(pc)
    out = OutputTrack()
    channel = {"dc": None}

    def send(msg):
        def _s():
            dc = channel["dc"]
            if dc and dc.readyState == "open":
                dc.send(json.dumps(msg))
        loop.call_soon_threadsafe(_s)

    live = LiveSession(claims.get("max", 300), out.push, send)
    live.fps = None
    # big images (data URLs) come over HTTP, not the data channel (~256 KB message limit)
    initial = {"image": body.get("image"), "prompt": body.get("prompt")}
    gen = {"thread": None, "closing": False}

    async def finish():
        if gen["closing"]:
            return
        gen["closing"] = True
        live.ended = True
        live.feed.shutdown()
        if gen["thread"]:
            await loop.run_in_executor(None, gen["thread"].join, 30)
        state["busy"] = False
        if current["apply"] is reset:
            current["sid"], current["apply"] = None, None
        await pc.close()
        pcs.discard(pc)

    def start_generation():
        t = threading.Thread(target=lambda: (engine.run(live), loop.call_soon_threadsafe(lambda: asyncio.ensure_future(finish()))), name="lc-gen", daemon=True)
        gen["thread"] = t
        t.start()

    async def stats_loop():
        while not live.ended:
            await asyncio.sleep(2)
            send({"type": "stats", "generation_fps": round(live.fps, 1) if live.fps else None, "profile": state["profile"]})

    async def reset(m):
        if m.get("prompt"):
            live.prompt = str(m["prompt"]).strip()[:1500]
        live.cover_path = await load_cover(m, live)
        live.restart = True
        live.feed.interrupt()

    current["sid"], current["apply"] = claims.get("sid"), reset

    @pc.on("datachannel")
    def on_dc(dc):
        channel["dc"] = dc

        @dc.on("message")
        def on_msg(raw):
            try:
                m = json.loads(raw)
            except Exception:
                return
            t = m.get("type")
            if t == "ping":
                dc.send(json.dumps({"type": "pong", "client_ts": m.get("ts")}))
            elif t == "configure" and gen["thread"] is None:
                async def go():
                    if not (m.get("image_url") or m.get("image")) and initial["image"]:
                        m["image"] = initial["image"]
                    live.prompt = (m.get("prompt") or initial["prompt"] or "").strip() or live.prompt
                    live.cover_path = await load_cover(m, live)
                    start_generation()
                    send({"type": "configured"})
                    asyncio.ensure_future(stats_loop())
                asyncio.ensure_future(go())
            elif t == "prompt" and m.get("prompt"):
                live.prompt = str(m["prompt"]).strip()[:1500]
            elif t == "reset":
                asyncio.ensure_future(reset(m))
            elif t == "stop":
                asyncio.ensure_future(finish())

    @pc.on("track")
    def on_track(track):
        if track.kind == "video":
            asyncio.ensure_future(read_camera(track, live))

    @pc.on("connectionstatechange")
    async def on_state():
        if pc.connectionState in ("failed", "closed"):
            await finish()

    try:
        await pc.setRemoteDescription(RTCSessionDescription(sdp=body["sdp"], type=body["type"]))
        pc.addTrack(out)
        await pc.setLocalDescription(await pc.createAnswer())
    except Exception as e:
        await finish()
        return web.json_response({"error": f"Bad offer: {e}"}, status=400, headers=CORS)

    # safety net: hard stop at the paid limit
    loop.call_later(int(claims.get("max", 300)) + 30, lambda: asyncio.ensure_future(finish()))
    return web.json_response({"sdp": pc.localDescription.sdp, "type": pc.localDescription.type}, headers=CORS)


async def reset_http(req):
    """New character for the live session, with the image in the body (no size limit)."""
    body = await req.json()
    claims = check_token(body.get("token"))
    if not claims or claims.get("sid") != current["sid"] or not current["apply"]:
        return web.json_response({"error": "No live session"}, status=403, headers=CORS)
    await current["apply"]({k: body[k] for k in ("image", "image_url", "prompt") if body.get(k)})
    return web.json_response({"ok": True}, headers=CORS)


def load_engine():
    global engine
    try:
        if not STUB:
            set_stage("writing config")
            subprocess.run(["python3", os.path.join(os.path.dirname(os.path.abspath(__file__)), "write_config.py")], check=True)
            state["profile"] = open(f"{LC}/profile.txt").read().strip()
        engine = (StubEngine if STUB else EdenEngine)(set_stage)
        engine.load()
        state["ready"] = True
        set_stage("ready")
    except Exception as e:
        set_stage(f"load failed: {type(e).__name__}: {e}"[:300])
        raise


def main():
    threading.Thread(target=load_engine, name="lc-load", daemon=True).start()
    app = web.Application(client_max_size=16 * 1024 * 1024)
    app.router.add_get("/health", health)
    app.router.add_post("/offer", offer)
    app.router.add_post("/reset", reset_http)
    app.router.add_route("OPTIONS", "/{tail:.*}", options)
    web.run_app(app, host="0.0.0.0", port=PORT, print=None)


if __name__ == "__main__":
    main()
