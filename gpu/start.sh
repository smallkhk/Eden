#!/usr/bin/env bash
# LiveChar GPU pod entrypoint (RunPod). Runs on every pod start.
#
# The LiveChar server creates the pod with this as its start command:
#   bash -c "curl -fsSL $LC_CODE_URL/start.sh -o /tmp/lc-start.sh && bash /tmp/lc-start.sh"
#
# Everything heavy lives on the network volume (/workspace/lc), so only the
# first start is slow (one-time setup); later starts load and go.
set -uo pipefail

export LC=/workspace/lc
export LC_CODE_URL="${LC_CODE_URL:-https://raw.githubusercontent.com/smallkhk/Eden/main/gpu}"
export LC_PORT="${LC_PORT:-8000}"
export PIP_CACHE_DIR="$LC/pip-cache" HF_HOME="$LC/hf-home" PIP_ROOT_USER_ACTION=ignore
export TRITON_CACHE_DIR="$LC/cache/triton" TORCH_EXTENSIONS_DIR="$LC/cache/torch_ext" \
       FLASHINFER_WORKSPACE_BASE="$LC/cache" TORCHINDUCTOR_CACHE_DIR="$LC/cache/inductor" XDG_CACHE_HOME="$LC/cache"
mkdir -p "$LC/app" "$LC/wheels" "$LC/apt" "$LC/logs"
exec > >(tee -a "$LC/logs/start.log") 2>&1
echo "=== LiveChar GPU start $(date -u +%FT%TZ) ==="

stage() { printf '{"ready":false,"stage":"%s"}\n' "$1" > "$LC/status.json"; echo ">>> $1"; }

# Tiny status page on $LC_PORT while we set up, so the app can show progress.
stage "booting"
python3 - <<'PY' &
import http.server, os, json
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

# 1. Latest server code from GitHub (keep the cached copy if GitHub is down).
stage "fetching code"
for f in setup.sh eden_server.py live_runner.py write_config.py; do
  curl -fsSL "$LC_CODE_URL/$f" -o "$LC/app/$f.new" && mv "$LC/app/$f.new" "$LC/app/$f" || echo "warn: could not fetch $f, using cached copy"
done

# 2. One-time setup (models, conversion, FP8, kernels). Skipped once done.
if [[ ! -f "$LC/setup.done" ]]; then
  stage "first-time setup (20-40 min, only once)"
  if ! bash "$LC/app/setup.sh"; then
    stage "setup failed - see /workspace/lc/logs/start.log"
    wait $STATUS_PID; exit 1
  fi
fi

# Light mode: small RunPod base image. Put the full image's folders back at their original
# paths (symlinks into the volume) so every hard-coded path keeps working.
if ! python3 -c "import torch" 2>/dev/null && [[ -f "$LC/env/.done" && -f "$LC/env/cuda/.done" && -f "$LC/env/.v3" ]]; then
  export LC_LIGHT=1
  PY312=$(command -v python3.12 || true)
  if [[ -z "$PY312" ]]; then stage "load failed: light image has no python3.12"; wait $STATUS_PID; exit 1; fi
  ln -sfn "$LC/env/app" /app
  rm -rf /usr/local/cuda && ln -s "$LC/env/cuda" /usr/local/cuda
  mkdir -p /usr/local/lib/python3.12
  rm -rf /usr/local/lib/python3.12/dist-packages && ln -s "$LC/env/site" /usr/local/lib/python3.12/dist-packages
  rm -rf /usr/local/lib/x86_64-linux-gnu && ln -s "$LC/env/usrlocal-lib" /usr/local/lib/x86_64-linux-gnu
  mkdir -p /tmp/lcbin && ln -sf "$PY312" /tmp/lcbin/python3 && ln -sf "$PY312" /tmp/lcbin/python
  printf 'import site\nsite.addsitedir("%s")\n' "$LC/env/site-deb" > /tmp/lcbin/sitecustomize.py
  export PYTHONPATH="/tmp/lcbin${PYTHONPATH:+:$PYTHONPATH}"
  export CUDA_HOME=/usr/local/cuda CUDA_PATH=/usr/local/cuda
  export PATH="/tmp/lcbin:/usr/local/cuda/bin:$LC/env/bin:$PATH"
  export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:/usr/local/cuda/lib64:$LC/env/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export LIBRARY_PATH="/usr/local/cuda/lib64/stubs"
  ldconfig 2>/dev/null || true
  python3 -c "import torch, sageattention; print('>>> light image ok: torch', torch.__version__, 'cuda', torch.cuda.is_available())" \
    || { stage "load failed: light image could not import torch/sageattention"; wait $STATUS_PID; exit 1; }
fi

# 3. Python packages for this boot (container disk is wiped on every stop).
stage "installing packages"
if [[ -z "${LC_LIGHT:-}" ]]; then
pip install -q --no-deps -e "$LC/LightX2V"
pip install -q "$LC"/wheels/*.whl --no-deps 2>/dev/null || true
pip install -q --ignore-installed --find-links "$LC/wheels" cryptography pyOpenSSL
pip install -q --find-links "$LC/wheels" aiortc aiohttp av
pip install -q -U "comfy-kitchen>=0.2.15"   # needs its full deps for int8_linear (FP8 profile)

# One-time: copy the CUDA toolkit (nvcc, headers) so light boots can JIT-compile kernels.
if [[ ! -f "$LC/env/cuda/.done" && -d /usr/local/cuda ]]; then
  stage "saving CUDA toolkit to volume (one time)"
  mkdir -p "$LC/env/cuda" && cp -aL /usr/local/cuda/. "$LC/env/cuda/" && date > "$LC/env/cuda/.done" \
    || { echo "warn: CUDA snapshot failed"; rm -rf "$LC/env/cuda"; }
fi

# One-time: snapshot this image's Python + CUDA libs onto the volume so later boots
# can use the small base image (seconds to pull instead of ~10 min).
if [[ ! -f "$LC/env/.done" ]]; then
  stage "saving environment to volume (one time)"
  SITE=$(python3 -c "import torch,os;print(os.path.dirname(os.path.dirname(torch.__file__)))")
  mkdir -p "$LC/env/site" "$LC/env/lib" "$LC/env/bin"
  mkdir -p "$LC/env/site-deb"
  cp -a "$SITE/." "$LC/env/site/" && \
  { [[ -d /usr/lib/python3/dist-packages ]] && cp -a /usr/lib/python3/dist-packages/. "$LC/env/site-deb/"; true; } && \
  { [[ -d /usr/local/cuda/lib64 ]] && cp -aL /usr/local/cuda/lib64/. "$LC/env/lib/" 2>/dev/null; true; } && \
  { cp -aL /usr/lib/x86_64-linux-gnu/libcudnn* /usr/lib/x86_64-linux-gnu/libnccl* "$LC/env/lib/" 2>/dev/null; true; } && \
  { cp -a /usr/local/bin/. "$LC/env/bin/" 2>/dev/null; true; } && \
  echo "$SITE" > "$LC/env/.done" && echo ">>> environment saved ($(du -sh "$LC/env" | cut -f1))" \
  || { echo "warn: env snapshot failed"; rm -rf "$LC/env"; }
fi
  # v3: the image installs attention kernels in place under /app (editable installs) and
  # extra libs in /usr/local/lib/x86_64-linux-gnu. Mirror them so light boots can put
  # them back at the same paths - no path rewriting needed.
  if [[ -f "$LC/env/.done" && ! -f "$LC/env/.v3" ]]; then
    stage "saving kernels to volume (one time)"
    rm -rf "$LC/pip-cache" "$LC/env/extra"
    df -h /workspace | tail -1
    mkdir -p "$LC/env/app" "$LC/env/usrlocal-lib"
    { [[ -d /app ]] && tar -C /app --exclude=.git --exclude=build --exclude=cutlass --exclude='*.o' -cf - . | tar -C "$LC/env/app" -xf -; } && \
    { [[ -d /usr/local/lib/x86_64-linux-gnu ]] && cp -a /usr/local/lib/x86_64-linux-gnu/. "$LC/env/usrlocal-lib/"; true; } && \
    date > "$LC/env/.v3" && echo ">>> kernels saved ($(du -sh "$LC/env/app" | cut -f1)); volume: $(df -h /workspace | tail -1 | awk '{print $3"/"$2}')" \
    || echo "warn: kernel copy failed (volume full?) - will keep using the full image"
  fi
fi

# 4. TURN relay: browsers reach the pod's WebRTC through TCP 3478.
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

# 5. The model server takes over the port (loads Eden, then reports ready).
stage "loading Eden 5B"
kill $STATUS_PID 2>/dev/null; wait $STATUS_PID 2>/dev/null
cd "$LC/app"
python3 eden_server.py
# The server only exits on a crash: keep reporting it so the app stops the pod instead of billing.
stage "load failed: model server exited (code $?)"
python3 - <<'PY'
import http.server, os
LC = os.environ["LC"]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = open(f"{LC}/status.json", "rb").read()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("0.0.0.0", int(os.environ["LC_PORT"])), H).serve_forever()
PY
