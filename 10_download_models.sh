#!/bin/bash
# First-boot provisioning for the krea2-tab1 serverless image.
# Downloads the Tab 1 model stack into the ComfyUI model dirs and stages the
# benchmark workflow. Skips anything already present and size-verified, so
# warm restarts on the same worker are a no-op.
set -euo pipefail

COMFY_DIR="/opt/comfyui/ComfyUI"
MODELS="$COMFY_DIR/models"

CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"
HF_TOKEN="${HF_TOKEN:-}"
[ -n "$CIVITAI_TOKEN" ] || { echo "FATAL: CIVITAI_TOKEN not set"; exit 1; }
[ -n "$HF_TOKEN" ] || { echo "FATAL: HF_TOKEN not set (required for the Alice LoRA)"; exit 1; }

mkdir -p "$MODELS/diffusion_models" "$MODELS/text_encoders" "$MODELS/vae" "$MODELS/loras" /workspace

fetch() { # fetch <outfile> <url...>
  local out="$1"; shift
  local i
  for i in 1 2 3 4 5; do
    if curl -L --fail --retry 3 --retry-delay 5 -C - --connect-timeout 30 -o "$out" "$@"; then
      return 0
    fi
    echo "retry $i for $out"
    sleep 10
  done
  echo "FATAL: download failed: $*"
  return 1
}

size_at_least() { # size_at_least <file> <min_bytes>
  [ -f "$1" ] && [ "$(stat -c%s "$1")" -ge "$2" ]
}

# 1) FinePorn v4 NVFP4 checkpoint (Blackwell-only format; ~7.7 GB)
UNET="$MODELS/diffusion_models/krea2_turbo_fineporn_v4_nvfp4.safetensors"
EXPECTED_SHA="11441bcc57f9e846e47bbab17044c7d4d848ee13ebf717d08a0280f6d1d2b9cf"
if [ -s "$UNET" ] && printf '%s  %s\n' "$EXPECTED_SHA" "$UNET" | sha256sum -c - >/dev/null 2>&1; then
  echo "have verified fineporn_v4_nvfp4"
else
  echo "downloading FinePorn v4 NVFP4 (~7.7 GB)"
  fetch "$UNET" "https://civitai.red/api/download/models/3215452?fileId=3097278&token=$CIVITAI_TOKEN"
  printf '%s  %s\n' "$EXPECTED_SHA" "$UNET" | sha256sum -c -
fi

# 2) Qwen3-VL 4B text encoder, fp8 scaled (~5.2 GB)
CLIP="$MODELS/text_encoders/qwen3vl_4b_fp8_scaled.safetensors"
if ! size_at_least "$CLIP" 5000000000; then
  echo "downloading Qwen3-VL 4B fp8 text encoder (~5.2 GB)"
  fetch "$CLIP" "https://huggingface.co/Comfy-Org/Krea-2/resolve/main/text_encoders/qwen3vl_4b_fp8_scaled.safetensors"
fi

# 3) Qwen-Image VAE (~254 MB)
VAE="$MODELS/vae/qwen_image_vae.safetensors"
if ! size_at_least "$VAE" 200000000; then
  echo "downloading Qwen-Image VAE (~254 MB)"
  fetch "$VAE" "https://huggingface.co/Comfy-Org/Krea-2/resolve/main/vae/qwen_image_vae.safetensors"
fi

# 4) Alice character LoRA (private HF repo, ~114 MB)
ALICE="$MODELS/loras/alice_character_v1.safetensors"
if ! size_at_least "$ALICE" 100000000; then
  echo "downloading Alice LoRA (~114 MB)"
  fetch "$ALICE" --header "Authorization: Bearer $HF_TOKEN" \
    "https://huggingface.co/freakH2O/alic3-krea2-lora/resolve/main/alice_character_v1.safetensors"
fi

# 5) Benchmark workflow -> /workspace (provisioning runs before the pyworker
#    clone, so it cannot write into the worker tree; BENCHMARK_JSON_PATH points here)
install -m 644 /opt/krea2/benchmark.json /workspace/benchmark.json

echo "provisioning complete"
