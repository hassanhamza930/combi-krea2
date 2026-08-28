#!/bin/bash
# onstart provisioning for the krea2-tab1 serverless template (vastai/comfy base).
# FIXED 2026-08-28 v2:
#   [FIX-1] aria2c --header= inline form got word-split by bash ("Unrecognized URI").
#           Header now passed as a separate quoted argument via adl -H flag.
#   [FIX-2] HF token: worker env may hold a stale token; prefer /root/.hf_token
#           (written by onstart.sh from template env), else $HF_TOKEN.
#   [FIX-3] pyworker must run for idle scale-to-zero. The image's pyworker.conf
#           skips itself expecting onstart to start it. We start supervisord with
#           SERVERLESS=true so comfyui + api-wrapper + pyworker all come up.
# Idempotent: skips anything already downloaded and verified.
set -euo pipefail

COMFY_SRC="/opt/workspace-internal/ComfyUI"
MODELS="$COMFY_SRC/models"

CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"
# [FIX-2] resolve the freshest HF token: onstart.sh stages it to /root/hf_token
if [ -s /root/hf_token ]; then
  HF_TOKEN="$(cat /root/hf_token)"
fi
HF_TOKEN="${HF_TOKEN:-}"
[ -n "$CIVITAI_TOKEN" ] || { echo "FATAL: CIVITAI_TOKEN not set"; exit 1; }
[ -n "$HF_TOKEN" ] || { echo "FATAL: HF_TOKEN not set (required for the Alice LoRA)"; exit 1; }
# persist for supervisor-run services (pyworker etc.) and later manual shells
grep -q '^HF_TOKEN=' /etc/environment 2>/dev/null || echo "HF_TOKEN=$HF_TOKEN" >> /etc/environment
grep -q '^CIVITAI_TOKEN=' /etc/environment 2>/dev/null || echo "CIVITAI_TOKEN=$CIVITAI_TOKEN" >> /etc/environment

mkdir -p "$MODELS/diffusion_models" "$MODELS/text_encoders" "$MODELS/vae" "$MODELS/loras" /workspace

command -v aria2c >/dev/null 2>&1 || {
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq aria2
}

size_at_least() { [ -f "$1" ] && [ "$(stat -c%s "$1")" -ge "$2" ]; }

# [FIX-1] adl <outfile> <url> [--header "<hdr>"] : header is ONE argument now
# [FIX-4] HF xet-bridge CDN returns HTTP 400 to multi-connection downloads;
#         after aria2c retries fail, fall back to curl -L -C - (resumable
#         single-stream, ~70MB/s from HF - your own rp_dl.sh documented this).
adl() {
  local out="$1" url="$2" hdr="${3:-}" input i dir base
  dir="$(dirname "$out")"; base="$(basename "$out")"
  mkdir -p "$dir"
  for i in 1 2 3 4 5; do
    input="$(mktemp)"; chmod 600 "$input"
    printf '%s\n  out=%s\n' "$url" "$base" > "$input"
    if [ -n "$hdr" ]; then
      if aria2c -c -x16 -s16 -k8M --file-allocation=none -d "$dir" \
           --header="$hdr" \
           --console-log-level=warn --summary-interval=0 --input-file="$input"; then
        rm -f -- "$input"; return 0
      fi
    else
      if aria2c -c -x16 -s16 -k8M --file-allocation=none -d "$dir" \
           --console-log-level=warn --summary-interval=0 --input-file="$input"; then
        rm -f -- "$input"; return 0
      fi
    fi
    rm -f -- "$input"; echo "retry $i for $out"; sleep 5
  done
  echo "aria2c failed 5x for $out; falling back to curl single-stream (FIX-4)"
  if [ -n "$hdr" ]; then
    curl -sS -L --retry 5 --retry-delay 5 -C - --header "$hdr" -o "$out" "$url"
  else
    curl -sS -L --retry 5 --retry-delay 5 -C - -o "$out" "$url"
  fi
}

# 1) FinePorn v4 NVFP4 checkpoint (~7.7 GB, CivitAI authenticated via URL token)
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

# 2) Qwen3-VL 4B text encoder, fp8 scaled (~5.0 GB, HF authenticated) [FIX-1][FIX-4]
CLIP="$MODELS/text_encoders/qwen3vl_4b_fp8_scaled.safetensors"
if ! size_at_least "$CLIP" 4000000000; then
  echo "downloading Qwen3-VL 4B fp8 text encoder (~5.0 GB, aria2c x16)"
  adl "$CLIP" "https://huggingface.co/Comfy-Org/Krea-2/resolve/main/text_encoders/qwen3vl_4b_fp8_scaled.safetensors" \
    --header "Authorization: Bearer $HF_TOKEN"
fi

# 3) Qwen-Image VAE (~242 MB, public HF)
VAE="$MODELS/vae/qwen_image_vae.safetensors"
if ! size_at_least "$VAE" 200000000; then
  echo "downloading Qwen-Image VAE (~242 MB, aria2c x16)"
  adl "$VAE" "https://huggingface.co/Comfy-Org/Krea-2/resolve/main/vae/qwen_image_vae.safetensors"
fi

# 4) Alice character LoRA (private HF repo, ~109 MB, HF authenticated) [FIX-1]
ALICE="$MODELS/loras/alice_character_v1.safetensors"
if ! size_at_least "$ALICE" 100000000; then
  echo "downloading Alice LoRA (~109 MB, aria2c x16)"
  adl "$ALICE" "https://huggingface.co/freakH2O/alic3-krea2-lora/resolve/main/alice_character_v1.safetensors" \
    --header "Authorization: Bearer $HF_TOKEN"
fi

# 5) Benchmark workflow where the pyworker's BENCHMARK_JSON_PATH looks
install -m 644 /root/benchmark.json /workspace/benchmark.json 2>/dev/null || true

# 6) Expose ComfyUI where the image's supervisor scripts expect it
mkdir -p /workspace
ln -sfn "$COMFY_SRC" /workspace/ComfyUI

# 7) [FIX-3] Start the full serverless supervisor stack (comfyui + api-wrapper +
#    pyworker). The pyworker is the component that heartbeats idleness to the
#    Vast autoscaler - without it, inactivity_timeout never fires and workers
#    burn forever. Idempotent: if supervisord is already running this is a no-op.
if ! curl -s -o /dev/null --max-time 3 http://127.0.0.1:18188/system_stats; then
  echo "starting serverless supervisor stack (comfyui + api-wrapper + pyworker)"
  SERVERLESS=true setsid supervisord -c /etc/supervisor/supervisord.conf \
    >> /var/log/portal/supervisord.log 2>&1 || true
  # wait for ComfyUI to be reachable (max 120s)
  for i in $(seq 1 60); do
    if curl -s -o /dev/null --max-time 3 http://127.0.0.1:18188/system_stats; then
      echo "comfyui up after ${i}x2s"; break
    fi
    sleep 2
  done
  supervisorctl status || true
fi

echo "model provisioning complete; releasing /.provisioning gate"
rm -f /.provisioning
ls -la "$MODELS/diffusion_models" "$MODELS/text_encoders" "$MODELS/vae" "$MODELS/loras"
