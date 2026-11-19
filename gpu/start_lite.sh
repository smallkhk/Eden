#!/usr/bin/env bash
# LiveChar "lite" GPU pod: Face swap (HyperSwap 256 from a photo) + Trained face (.dfm).
# No Eden, no PyTorch: ONNX Runtime GPU only, so it runs on cheap cards (RTX A4000/A4500/A5000...)
# with the small RunPod base image. Everything installs once onto the network volume.
set -uo pipefail

export LC=/workspace/lc
export LC_CODE_URL="${LC_CODE_URL:-https://raw.githubusercontent.com/smallkhk/Eden/main/gpu}"
export LC_PORT="${LC_PORT:-8000}" LC_FPS="${LC_FPS:-30}" LC_EDEN_AT_START=0 LC_LITE=1
export PIP_ROOT_USER_ACTION=ignore PIP_CACHE_DIR=/tmp/pip-cache
mkdir -p "$LC/app" "$LC/apt" "$LC/logs" "$LC/dlc/models" "$LC/dfm"
exec > >(tee -a "$LC/logs/start.log") 2>&1
echo "=== LiveChar lite GPU start $(date -u +%FT%TZ) ==="

stage() { printf '{"ready":false,"stage":"%s"}\n' "$1" > "$LC/status.json"; echo ">>> $1"; }

PY=$(command -v python3.12 || command -v python3)

# Tiny status page on $LC_PORT while we set up.
stage "booting"
"$PY" - <<'PY' &
import http.server, os
LC = os.environ["LC"]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/log") and os.environ.get("LC_SECRET") and self.path.endswith("k=" + os.environ["LC_SECRET"]):
            try: body = b"".join(open(f"{LC}/logs/start.log", "rb").readlines()[-150:])
            except OSError: body = b"no log"
            self.send_response(200); self.send_header("Content-Type", "text/plain"); self.end_headers(); self.wfile.write(body); return
        try: body = open(f"{LC}/status.json", "rb").read()
        except OSError: body = b'{"ready":false,"stage":"booting"}'
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*"); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("0.0.0.0", int(os.environ["LC_PORT"])), H).serve_forever()
PY
STATUS_PID=$!

fail() { stage "load failed: $1"; wait $STATUS_PID; exit 1; }

# 1. Latest server code (GitHub contents API: not CDN-cached).
stage "fetching code"
API_URL=$(echo "$LC_CODE_URL" | sed -nE 's#^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.*)$#https://api.github.com/repos/\1/\2/contents/\4|\3#p')
fetch() {
  if [[ -n "$API_URL" ]]; then
    curl -fsSL -H "Accept: application/vnd.github.raw" "${API_URL%%|*}/$1?ref=${API_URL##*|}" -o "$2" && return 0
  fi
  curl -fsSL "$LC_CODE_URL/$1?nocache=$(date +%s)" -o "$2"
}
for f in eden_server.py live_runner.py faceswap.py dfm.py; do
  fetch "$f" "$LC/app/$f.new" && mv "$LC/app/$f.new" "$LC/app/$f" || echo "warn: could not fetch $f, using cached copy"
done

# 2. Python packages onto the volume (one time, ~3 min). ONNX Runtime GPU for CUDA 12 runs on
#    every current RunPod driver; its CUDA/cuDNN libraries come as pip packages.
PYENV="$LC/pyenv"
if [[ ! -f "$PYENV/.v2" ]]; then
  stage "installing packages (one time, ~3 min)"
  "$PY" -m pip --version >/dev/null 2>&1 || curl -fsSL https://bootstrap.pypa.io/get-pip.py | "$PY" - -q --break-system-packages \
    || fail "could not install pip"
  rm -rf "$PYENV"
  "$PY" -m pip install -q --break-system-packages --target "$PYENV" \
      "onnxruntime-gpu[cuda,cudnn]==1.22.0" "numpy<2.3" opencv-python-headless aiortc aiohttp av pillow onnx \
    && date > "$PYENV/.v2" || fail "package install failed"
fi
export PYTHONPATH="$PYENV"
for d in "$PYENV"/nvidia/*/lib; do export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$d"; done

# 3. Models (one time, ~2.5 GB).
stage "downloading models (one time)"
M="$LC/dlc/models"
get() {   # get <dest file> <url>
  [[ -s "$1" ]] && return 0
  curl -fsSL --retry 3 -o "$1.part" "$2" && mv -f "$1.part" "$1"
}
HFB=https://huggingface.co/hacksider/deep-live-cam/resolve/main
get "$M/det_10g.onnx"        "$HFB/buffalo_l/buffalo_l/det_10g.onnx"   || fail "model download failed (det_10g)"
get "$M/w600k_r50.onnx"      "$HFB/buffalo_l/buffalo_l/w600k_r50.onnx" || fail "model download failed (w600k_r50)"
get "$M/2d106det.onnx"       "$HFB/buffalo_l/buffalo_l/2d106det.onnx"  || fail "model download failed (2d106det)"
get "$M/GFPGANv1.4.onnx"     "$HFB/GFPGANv1.4.onnx"                     || fail "model download failed (GFPGAN)"
get "$M/inswapper_128_fp16.onnx" "$HFB/inswapper_128_fp16.onnx"    || fail "model download failed (inswapper)"
if [[ ! -s "$M/emap.npy" ]]; then
  "$PY" -c "
import onnx, numpy as np
from onnx import numpy_helper
m = onnx.load('$M/inswapper_128_fp16.onnx')
np.save('$M/emap.npy', numpy_helper.to_array(m.graph.initializer[-1]).astype('float32'))" || fail "emap extract failed"
fi
for v in 1a; do
  get "$M/hyperswap_${v}_256.onnx" "https://huggingface.co/facefusion/models-3.3.0/resolve/main/hyperswap_${v}_256.onnx" \
    || fail "model download failed (hyperswap $v)"
done

# 4. Self-test: GPU provider + the whole server imports.
stage "checking GPU"
ERR=$(cd "$LC/app" && "$PY" -c "
import onnxruntime as ort
try: ort.preload_dlls()
except Exception: pass
assert 'CUDAExecutionProvider' in ort.get_available_providers(), 'no CUDA provider'
import faceswap, dfm, eden_server
s = faceswap._session('det_10g.onnx', [('CUDAExecutionProvider', {}), 'CPUExecutionProvider'])
print('ok', ort.__version__, s.get_providers()[0])" 2>&1 | tail -1)
echo ">>> self-test: $ERR"
[[ "$ERR" == ok* ]] || fail "${ERR//\"/\'}"

# 5. TURN relay: browsers reach the pod's WebRTC through TCP 3478.
stage "starting relay"
if ! command -v turnserver >/dev/null; then
  apt-get -o Dir::Cache::archives="$LC/apt" update -qq >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get -o Dir::Cache::archives="$LC/apt" install -y -qq coturn >/dev/null
fi
PRIV_IP=$(hostname -I | awk '{print $1}')
turnserver --listening-port 3478 --listening-ip "$PRIV_IP" --relay-ip "$PRIV_IP" \
  --min-port 49152 --max-port 49999 --use-auth-secret --static-auth-secret "${LC_SECRET:?LC_SECRET missing}" \
  --realm livechar --fingerprint --no-tls --no-dtls --no-cli --no-multicast-peers \
  --log-file "$LC/logs/turn.log" --simple-log >/dev/null 2>&1 &

# 6. The server takes over the port (face engines load on first use, a few seconds).
kill $STATUS_PID 2>/dev/null; wait $STATUS_PID 2>/dev/null
cd "$LC/app"
"$PY" eden_server.py 2>&1 | tee "$LC/logs/server.log"
LAST=$(grep -E "Error|error|Exception" "$LC/logs/server.log" | tail -1 | cut -c1-240)
stage "load failed: server crashed: ${LAST//\"/\'}"
"$PY" - <<'PY'
import http.server, os
LC = os.environ["LC"]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = open(f"{LC}/status.json", "rb").read()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("0.0.0.0", int(os.environ["LC_PORT"])), H).serve_forever()
PY
