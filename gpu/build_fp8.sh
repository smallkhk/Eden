#!/usr/bin/env bash
# Rebuild Eden's FP8 checkpoints from the converted model if missing (called on first Eden use).
set -uo pipefail
LC=${LC:-/workspace/lc}
mkdir -p "$LC/logs"
# FP8 checkpoints (default profile). Rebuilt from the converted model if missing, a few minutes once.
Q="$LC/models/EdenLive-x2v/quantized"
if [[ "${LC_PROFILE:-fp8}" == "fp8" && ! -f "$Q/dit-5b-fp8-f16-accum-qmax14.safetensors" ]]; then
  if python3 -c "from lightx2v.common.ops.mm.fp8_f16_accum import fp8_f16_accum_mm_available as a; import sys; sys.exit(0 if a() else 1)" 2>/dev/null; then
    echo "building FP8 model (one time, ~5 min)"
    ( cd "$LC/LightX2V" && EDEN_MODEL="$LC/models/EdenLive-x2v" QUANT_DEVICE=cuda:0 PYTHON_BIN=python3 \
        bash scripts/edenlive/prepare_fp8_f16_accum_5090.sh ) >> "$LC/logs/fp8.log" 2>&1 || echo "warn: FP8 build failed - using BF16"
  else
    echo "warn: FP8 kernel unavailable - using BF16"
  fi
fi

