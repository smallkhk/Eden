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
for f in setup.sh eden_server.py live_runner.py write_config.py faceswap.py; do
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
  export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$LC/env/syslib"
  export LIBRARY_PATH="/usr/local/cuda/lib64/stubs"
  ldconfig 2>/dev/null || true
  # Self-test the full server import. If a system library is missing, find the Ubuntu package
  # that ships it (apt-file), install it (debs cached on the volume) and remember it for next boot.
  APTDIR="$LC/apt"; APTPK="$LC/env/light-apt.txt"; mkdir -p "$APTDIR"; touch "$APTPK"
  apt_q() { DEBIAN_FRONTEND=noninteractive apt-get -o Dir::Cache::archives="$APTDIR" -y -qq --no-install-recommends "$@" >/dev/null 2>&1; }
  if [[ -s "$APTPK" ]]; then stage "installing saved system libraries"; apt_q update; apt_q install $(sort -u "$APTPK"); fi
  selftest() { (cd "$LC/app" && python3 -c "
import torch, sageattention, av, aiohttp, aiortc, numpy, PIL, lightx2v
from aiortc.codecs import h264, vp8
import eden_server
print('ok', torch.__version__, torch.cuda.is_available())" 2>&1 | tail -1); }
  ERR=$(selftest); tries=0
  while [[ "$ERR" != ok* && $tries -lt 8 ]]; do
    tries=$((tries + 1))
    LIB=$(echo "$ERR" | grep -oE 'lib[A-Za-z0-9_+.-]+\.so[.0-9]*' | head -1)
    [[ -z "$LIB" ]] && break
    stage "light image: installing $LIB"
    if ! command -v apt-file >/dev/null; then apt_q update; apt_q install apt-file; apt-file update >/dev/null 2>&1; fi
    PKG=$(apt-file search -l "/$LIB" 2>/dev/null | grep -vE -- '-dev$|-dbg$' | head -1)
    [[ -z "$PKG" ]] && break
    apt_q install "$PKG" && echo "$PKG" >> "$APTPK"
    ldconfig 2>/dev/null || true
    ERR=$(selftest)
  done
  echo ">>> light self-test: $ERR"
  if [[ "$ERR" != ok* ]]; then stage "load failed: light image: ${ERR//\"/\'}"; wait $STATUS_PID; exit 1; fi
fi

# Housekeeping: drop caches and leftovers that are not needed once setup is done.
if [[ -f "$LC/setup.done" ]]; then
  rm -rf "$LC/pip-cache" "$LC/hf-home" "$LC/cutlass" "$LC/env/extra" "$LC/models/EdenLive" 2>/dev/null
  find "$LC/logs" -name '*.log' -size +20M -delete 2>/dev/null
  # FP8 copies are only used with LC_PROFILE=fp8; BF16 is the default, so free ~12 GB.
  [[ "${LC_PROFILE:-bf16}" != "fp8" ]] && rm -rf "$LC/models/EdenLive-x2v/quantized" 2>/dev/null
fi

if ! python3 -c "import torch" 2>/dev/null && [[ -z "${LC_LIGHT:-}" ]]; then
  stage "load failed: env missing on volume (needs the full image once)"; wait $STATUS_PID; exit 1
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
  # v4: system libraries that compiled packages link to (libvpx, opus, srtp, ffmpeg...).
  # ldd every .so in the saved env and keep anything that is not core glibc.
  if [[ -f "$LC/env/.v3" && ! -f "$LC/env/.v4" ]]; then
    stage "saving system libraries to volume (one time)"
    mkdir -p "$LC/env/syslib"
    find "$LC/env/site" "$LC/env/app" -name '*.so*' -type f 2>/dev/null \
      | xargs -r -P 8 -n 50 ldd 2>/dev/null | awk '/=> \//{print $3}' | sort -u \
      | grep -E '^/(usr/)?lib/x86_64-linux-gnu/' \
      | grep -vE '/(libc|libm|libpthread|libdl|librt|ld-linux-x86-64|libstdc\+\+|libgcc_s|libresolv|libutil)\.so' \
      | while read -r lib; do cp -nL "$lib" "$LC/env/syslib/" 2>/dev/null; done
    date > "$LC/env/.v4" && echo ">>> system libs saved: $(ls "$LC/env/syslib" | wc -l) files, $(du -sh "$LC/env/syslib" | cut -f1)"
  fi

fi

# Face swap (Deep-Live-Cam pipeline): models + ONNX Runtime GPU (CUDA 13 build) on the volume. One time.
if [[ ! -f "$LC/dlc/.done" ]]; then
  stage "installing face swap (one time, ~3 min)"
  mkdir -p "$LC/dlc/models" "$LC/dlc/pkgs"
  HFB=https://huggingface.co/hacksider/deep-live-cam/resolve/main
  ok=1
  for f in buffalo_l/buffalo_l/det_10g.onnx buffalo_l/buffalo_l/w600k_r50.onnx inswapper_128_fp16.onnx GFPGANv1.4.onnx; do
    out="$LC/dlc/models/$(basename "$f")"
    if [[ ! -s "$out" ]]; then
      if curl -fsSL --retry 3 -o "$out.part" "$HFB/$f"; then mv -f "$out.part" "$out"; else ok=0; fi
    fi
  done
  python3 -m pip install -q --no-deps --target "$LC/dlc/pkgs" "onnxruntime-gpu==1.32.0" flatbuffers onnx || ok=0
  PYTHONPATH="$LC/dlc/pkgs:${PYTHONPATH:-}" python3 -c "
import onnx, numpy as np
from onnx import numpy_helper
m = onnx.load('$LC/dlc/models/inswapper_128_fp16.onnx')
np.save('$LC/dlc/models/emap.npy', numpy_helper.to_array(m.graph.initializer[-1]).astype('float32'))
print('emap saved')" || ok=0
  [[ $ok == 1 ]] && date > "$LC/dlc/.done" || echo "warn: face swap install failed - Eden still works"
fi
export PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$LC/dlc/pkgs"

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
python3 eden_server.py 2>&1 | tee "$LC/logs/server.log"
# The server only exits on a crash: report the last error line so the app shows it and stops the pod.
LAST=$(grep -E "Error|error|Exception" "$LC/logs/server.log" | tail -1 | cut -c1-240)
stage "load failed: model server crashed: ${LAST//\"/\'}"
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
