#!/bin/bash
# onstart provisioning for the krea2-tab1 serverless template (vastai/comfy base).
# Installs the comfyui-json PyWorker stack: downloads the Tab 1 model stack with
# aria2c (16 connections, authenticated URLs, no rate limiting), stages the
# benchmark workflow, then releases the /.provisioning gate so the image's own
# supervisor starts ComfyUI + api-wrapper + pyworker.
# Idempotent: skips anything already downloaded and verified.
set -euo pipefail

COMFY_SRC="/opt/workspace-internal/ComfyUI"
MODELS="$COMFY_SRC/models"

CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"
HF_TOKEN="${HF_TOKEN:-}"
[ -n "$CIVITAI_TOKEN" ] || { echo "FATAL: CIVITAI_TOKEN not set"; exit 1; }
[ -n "$HF_TOKEN" ] || { echo "FATAL: HF_TOKEN not set (required for the Alice LoRA)"; exit 1; }

mkdir -p "$MODELS/diffusion_models" "$MODELS/text_encoders" "$MODELS/vae" "$MODELS/loras" /workspace

command -v aria2c >/dev/null 2>&1 || {
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq aria2
}

size_at_least() { [ -f "$1" ] && [ "$(stat -c%s "$1")" -ge "$2" ]; }

adl() { # adl <outfile-abs-path> <url>
  local out="$1" url="$2" input i dir base
  dir="$(dirname "$out")"; base="$(basename "$out")"
  mkdir -p "$dir"
  for i in 1 2 3 4 5; do
    input="$(mktemp)"; chmod 600 "$input"
    printf '%s\n  out=%s\n' "$url" "$base" > "$input"
    if aria2c -c -x16 -s16 -k8M --file-allocation=none -d "$dir" \
         --console-log-level=warn --summary-interval=0 --input-file="$input"; then
      rm -f -- "$input"; return 0
    fi
    rm -f -- "$input"; echo "retry $i for $out"; sleep 5
  done
  echo "FATAL: download failed: $url"; return 1
}

# 1) FinePorn v4 NVFP4 checkpoint (~7.7 GB, CivitAI authenticated, 16-conn)
UNET="$MODELS/diffusion_models/krea2_turbo_fineporn_v4_nvfp4.safetensors"
EXPECTED_SHA="11441bcc57f9e846e47bbab17044c7d4d848ee13ebf717d08a0280f6d1d2b9cf"
if [ -s "$UNET" ] && printf '%s  %s\n' "$EXPECTED_SHA" "$UNET" | sha256sum -c - >/dev/null 2>&1; then
  echo "have verified fineporn_v4_nvfp4"
elif [ -s "$UNET" ] && [ ! -f "$UNET.done" ]; then
  echo "file present but unverified; verifying in place (no re-download)"
  if printf '%s  %s\n' "$EXPECTED_SHA" "$UNET" | sha256sum -c - >/dev/null 2>&1; then
    touch "$UNET.done"; echo "checksum OK (existing file)"
  else
    echo "checksum mismatch; re-downloading"
    adl "$UNET" "https://civitai.red/api/download/models/3215452?fileId=3097278&token=$CIVITAI_TOKEN"
    printf '%s  %s\n' "$EXPECTED_SHA" "$UNET" | sha256sum -c - && touch "$UNET.done"
  fi
else
  echo "downloading FinePorn v4 NVFP4 (~7.7 GB, aria2c x16)"
  adl "$UNET" "https://civitai.red/api/download/models/3215452?fileId=3097278&token=$CIVITAI_TOKEN"
  printf '%s  %s\n' "$EXPECTED_SHA" "$UNET" | sha256sum -c - && touch "$UNET.done"
fi

# 2) Qwen3-VL 4B text encoder, fp8 scaled (~5.0 GB, HF authenticated, 16-conn)
CLIP="$MODELS/text_encoders/qwen3vl_4b_fp8_scaled.safetensors"
if ! size_at_least "$CLIP" 4000000000; then
  echo "downloading Qwen3-VL 4B fp8 text encoder (~5.0 GB, aria2c x16)"
  adl "$CLIP" --header="Authorization: Bearer $HF_TOKEN" \
    "https://huggingface.co/Comfy-Org/Krea-2/resolve/main/text_encoders/qwen3vl_4b_fp8_scaled.safetensors"
fi

# 3) Qwen-Image VAE (~242 MB)
VAE="$MODELS/vae/qwen_image_vae.safetensors"
if ! size_at_least "$VAE" 200000000; then
  echo "downloading Qwen-Image VAE (~242 MB, aria2c x16)"
  adl "$VAE" "https://huggingface.co/Comfy-Org/Krea-2/resolve/main/vae/qwen_image_vae.safetensors"
fi

# 4) Alice character LoRA (private HF repo, ~109 MB, HF authenticated)
ALICE="$MODELS/loras/alice_character_v1.safetensors"
if ! size_at_least "$ALICE" 100000000; then
  echo "downloading Alice LoRA (~109 MB, aria2c x16)"
  adl "$ALICE" --header="Authorization: Bearer $HF_TOKEN" \
    "https://huggingface.co/freakH2O/alic3-krea2-lora/resolve/main/alice_character_v1.safetensors"
fi

# 5) Benchmark workflow where the pyworker's BENCHMARK_JSON_PATH looks
install -m 644 /root/benchmark.json /workspace/benchmark.json 2>/dev/null || true

# 6) Expose ComfyUI where the image's supervisor scripts expect it
#    (symlink: instant, no copy; /workspace is persistent per-worker)
mkdir -p /workspace
ln -sfn "$COMFY_SRC" /workspace/ComfyUI

echo "model provisioning complete; releasing /.provisioning gate"
rm -f /.provisioning
ls -la "$MODELS/diffusion_models" "$MODELS/text_encoders" "$MODELS/vae" "$MODELS/loras"
