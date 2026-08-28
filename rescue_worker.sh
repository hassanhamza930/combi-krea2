#!/bin/bash
# One-shot rescue for recruited workers that downloaded models to the wrong
# path (aria2c relative-out bug). Moves files into the real ComfyUI tree,
# fetches remaining models, exposes /workspace/ComfyUI, releases the gate.
set -uo pipefail

SRC="/opt/workspace-internal/ComfyUI"
MODELS="$SRC/models"
HF_TOKEN="${HF_TOKEN:-}"
CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"

command -v aria2c >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq aria2; }

adl() {
  local out="$1" url="$2" input i dir base
  dir="$(dirname "$out")"; base="$(basename "$out")"; mkdir -p "$dir"
  for i in 1 2 3 4 5; do
    input="$(mktemp)"; printf '%s\n  out=%s\n' "$url" "$base" > "$input"
    aria2c -c -x16 -s16 -k8M --file-allocation=none -d "$dir" --console-log-level=warn --summary-interval=0 --input-file="$input" && { rm -f "$input"; return 0; }
    rm -f "$input"; sleep 5
  done
  return 1
}

mkdir -p "$MODELS/diffusion_models" "$MODELS/text_encoders" "$MODELS/vae" "$MODELS/loras"

# 1) checkpoint: move from wrong path if it landed under /root/opt
UNET="$MODELS/diffusion_models/krea2_turbo_fineporn_v4_nvfp4.safetensors"
if [ ! -s "$UNET" ]; then
  WRONG="/root/opt/comfyui/ComfyUI/models/diffusion_models/krea2_turbo_fineporn_v4_nvfp4.safetensors"
  [ -s "$WRONG" ] && mv "$WRONG" "$UNET" && echo "moved checkpoint into place"
fi
if [ -s "$UNET" ]; then
  printf '11441bcc57f9e846e47bbab17044c7d4d848ee13ebf717d08a0280f6d1d2b9cf  %s\n' "$UNET" | sha256sum -c - && touch "$UNET.done" || echo "WARN: checkpoint sha mismatch"
else
  adl "$UNET" "https://civitai.red/api/download/models/3215452?fileId=3097278&token=$CIVITAI_TOKEN" && touch "$UNET.done"
fi

# 2-4) encoder, VAE, Alice
CLIP="$MODELS/text_encoders/qwen3vl_4b_fp8_scaled.safetensors"
[ -s "$CLIP" ] || adl "$CLIP" --header="Authorization: Bearer $HF_TOKEN" "https://huggingface.co/Comfy-Org/Krea-2/resolve/main/text_encoders/qwen3vl_4b_fp8_scaled.safetensors"

VAE="$MODELS/vae/qwen_image_vae.safetensors"
[ -s "$VAE" ] || adl "$VAE" "https://huggingface.co/Comfy-Org/Krea-2/resolve/main/vae/qwen_image_vae.safetensors"

ALICE="$MODELS/loras/alice_character_v1.safetensors"
[ -s "$ALICE" ] || adl "$ALICE" --header="Authorization: Bearer $HF_TOKEN" "https://huggingface.co/freakH2O/alic3-krea2-lora/resolve/main/alice_character_v1.safetensors"

# 5) benchmark + symlink + release gate
install -m 644 /root/benchmark.json /workspace/benchmark.json 2>/dev/null || true
ln -sfn "$SRC" /workspace/ComfyUI
rm -f /.provisioning
echo "RESCUE COMPLETE"
ls -la "$MODELS/diffusion_models" "$MODELS/loras" | grep -v "^total\|^d"
