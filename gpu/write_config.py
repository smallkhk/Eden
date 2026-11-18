"""Write the LightX2V runtime config for live Eden 5B on an RTX 5090.

Uses the FP8 profile (~25 fps) when its checkpoints and kernel are present,
otherwise the BF16 profile (~12 fps). Output: /workspace/lc/runtime.json
"""
import json
import os
import sys
from pathlib import Path

LC = Path(os.environ.get("LC", "/workspace/lc"))
X2V = LC / "models/EdenLive-x2v"
PROFILES = LC / "LightX2V/configs/edenlive/realtime"


def fp8_kernel_ok():
    try:
        from lightx2v.common.ops.mm.fp8_f16_accum import fp8_f16_accum_mm_available
        return bool(fp8_f16_accum_mm_available())
    except Exception:
        return False


def main():
    q = X2V / "quantized"
    fp8_files = [q / "dit-5b-fp8-f16-accum-qmax14.safetensors", q / "t5-fp8-f16-accum-qmax14.safetensors", q / "proxy-dino-int8-convrot.safetensors"]
    use_fp8 = os.environ.get("LC_PROFILE", "auto") != "bf16" and all(f.exists() for f in fp8_files) and fp8_kernel_ok()
    name = "wan22_5b_ar_fp8_f16_accum_sage_lighttae_async_5090.json" if use_fp8 else "wan22_5b_ar_bf16_sage_lighttae_async_5090.json"
    cfg = json.loads((PROFILES / name).read_text())

    cfg.pop("prompt_travel", None)          # live prompts come from the app
    # CUDA graph capture crashes on the RunPod 5090 driver; compile + FP8 still apply. LC_CUDA_GRAPH=1 re-enables.
    cfg["use_cuda_graph"] = os.environ.get("LC_CUDA_GRAPH") == "1"
    cfg["tae_path"] = str(X2V / "decoder-5b/lighttaew2_2.pth")
    if use_fp8:
        cfg["dit_quantized_ckpt"] = str(fp8_files[0])
        cfg["t5_quantized_ckpt"] = str(fp8_files[1])
        cfg["proxy_quantized_ckpt"] = str(fp8_files[2])
        cfg["t5_original_ckpt"] = str(X2V / "umt5/text_encoder/model.safetensors")
        cfg["t5_tokenizer_path"] = str(X2V / "umt5/tokenizer")
    cfg["request_defaults"] = {"size": [704, 1280], "num_frames": 24 * 600 + 1}

    out = LC / "runtime.json"
    out.write_text(json.dumps(cfg, indent=2) + "\n")
    (LC / "profile.txt").write_text("fp8\n" if use_fp8 else "bf16\n")
    print(f"wrote {out} ({'FP8 ~25fps' if use_fp8 else 'BF16 ~12fps'})")


if __name__ == "__main__":
    sys.exit(main())
