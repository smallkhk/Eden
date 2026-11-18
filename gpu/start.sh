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

# 3. Python packages for this boot (container disk is wiped on every stop).
stage "installing packages"
pip install -q --no-deps -e "$LC/LightX2V"
pip install -q "$LC"/wheels/*.whl --no-deps 2>/dev/null || true
pip install -q --ignore-installed --find-links "$LC/wheels" cryptography pyOpenSSL
pip install -q --find-links "$LC/wheels" aiortc aiohttp av
pip install -q -U "comfy-kitchen>=0.2.15"   # needs its full deps for int8_linear (FP8 profile)

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
exec python3 eden_server.py
