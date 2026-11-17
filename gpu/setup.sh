#!/usr/bin/env bash
# One-time setup on the network volume: LightX2V, Eden Live 5B weights,
# conversion, FP8 quantization for the RTX 5090, and (if missing) the FP8 kernel.
# Safe to re-run: every step skips work that is already done.
set -euo pipefail

LC="${LC:-/workspace/lc}"
LX2V_REF="${LX2V_REF:-211495fe504bfa0238c832fa1a501487486fb334}"
RAW="$LC/models/EdenLive"
X2V="$LC/models/EdenLive-x2v"
export PIP_CACHE_DIR="$LC/pip-cache" HF_HOME="$LC/hf-home" HF_HUB_ENABLE_HF_TRANSFER=1
mkdir -p "$LC/models" "$LC/wheels"
log() { echo "[setup $(date +%T)] $*"; printf '{"ready":false,"stage":"setup: %s"}\n' "$*" > "$LC/status.json"; }

log "checking GPU"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader

# 1. LightX2V, pinned to the commit this was written against.
log "LightX2V"
if [[ ! -d "$LC/LightX2V/.git" ]]; then
  git clone https://github.com/ModelTC/LightX2V.git "$LC/LightX2V"
fi
git -C "$LC/LightX2V" fetch --depth 1 origin "$LX2V_REF" && git -C "$LC/LightX2V" checkout -q FETCH_HEAD
pip install -q --no-deps -e "$LC/LightX2V"
pip install -q -U "huggingface_hub[hf_transfer]" "comfy-kitchen>=0.2.15" aiortc aiohttp
# keep wheels for fast reinstall on every boot
pip download -q -d "$LC/wheels" aiortc aiohttp "comfy-kitchen>=0.2.15" || true

# 2. Eden Live 5B weights only (~30 GB instead of the full 210 GB release).
if [[ ! -f "$X2V/.converted" ]]; then
  log "downloading Eden 5B weights"
  hf download VAST-AI/EdenLive --local-dir "$RAW" \
    --include "dit-5b/*" "vae-5b/*" "decoder-5b/*" "umt5/*" "vision-encoder/*" "model_index.json"

  # 3. Convert to LightX2V layout (5B + text encoder; no CLIP, no 14B, no FLUX).
  log "converting weights"
  python3 - "$RAW" "$X2V" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, "/workspace/lc/LightX2V")
from tools.convert.convert_edenlive import convert_dit, convert_encoder, copy_tree
src, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
convert_dit(src / "dit-5b", out / "dit-5b", False)
convert_encoder(src / "umt5/text_encoder", out / "umt5/text_encoder", "t5", False)
skip = {Path("dit-5b/config.json"), Path("umt5/text_encoder/config.json")}
skip |= {p.relative_to(src) for d in ("dit-5b", "umt5/text_encoder") for p in (src / d).glob("*.safetensors")}
copy_tree(src, out, False, exclude=skip)
(out / ".converted").write_text("ok\n")
PY
fi

# 4. FP8 kernel for the 5090 (SM120). Built once into the volume if the image lacks it.
fp8_ok() { python3 -c "from lightx2v.common.ops.mm.fp8_f16_accum import fp8_f16_accum_mm_available as a; import sys; sys.exit(0 if a() else 1)" 2>/dev/null; }
if ! fp8_ok && ! ls "$LC"/wheels/lightx2v_kernel*.whl >/dev/null 2>&1; then
  log "building FP8 kernel (one time, ~20 min)"
  pip install -q scikit_build_core uv
  [[ -d "$LC/cutlass" ]] || git clone --depth 1 https://github.com/NVIDIA/cutlass.git "$LC/cutlass"
  ( cd "$LC/LightX2V/lightx2v_kernel/nvidia" && \
    MAX_JOBS=$(nproc) CMAKE_BUILD_PARALLEL_LEVEL=$(nproc) uv build --wheel -Cbuild-dir=build . \
      -Ccmake.define.CUTLASS_PATH="$LC/cutlass" --no-build-isolation -o "$LC/wheels" ) || log "kernel build failed - will use BF16"
fi
ls "$LC"/wheels/lightx2v_kernel*.whl >/dev/null 2>&1 && pip install -q --force-reinstall --no-deps "$LC"/wheels/lightx2v_kernel*.whl

# 5. FP8 checkpoints (DiT + T5) and INT8 proxy encoder.
if fp8_ok; then
  log "quantizing to FP8"
  ( cd "$LC/LightX2V" && EDEN_MODEL="$X2V" QUANT_DEVICE=cuda:0 PYTHON_BIN=python3 \
      bash scripts/edenlive/prepare_fp8_f16_accum_5090.sh ) || log "FP8 quantization failed - will use BF16"
fi

# 6. Free the raw download (converted files are hard links or copies).
rm -rf "$RAW"

# 7. Placeholder recording (the live server replaces it with the webcam).
python3 - "$LC/placeholder.mp4" <<'PY'
import sys, av, numpy as np
c = av.open(sys.argv[1], "w"); s = c.add_stream("libx264", rate=24); s.width, s.height, s.pix_fmt = 1280, 704, "yuv420p"
for _ in range(48):
    for p in s.encode(av.VideoFrame.from_ndarray(np.zeros((704, 1280, 3), np.uint8), format="rgb24")): c.mux(p)
for p in s.encode(): c.mux(p)
c.close()
PY

# 8. Runtime configs (FP8 if available, BF16 fallback).
log "writing config"
python3 "$LC/app/write_config.py"

date -u +%FT%TZ > "$LC/setup.done"
log "done"
du -sh "$LC" || true
