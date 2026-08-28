#!/bin/bash
# Slim onstart for the FULLY-BAKED krea2-tab1 image
# (hassanhamza930/combi-krea2:baked). Models are already inside the image at
# /opt/workspace-internal/ComfyUI/models, so there is NOTHING to download.
# Just stage the benchmark workflow and start the serverless supervisor stack
# (comfyui + api-wrapper + pyworker). The pyworker is what heartbeats idleness
# to the autoscaler for scale-to-zero.
#
# [FIX-9] DO NOT name the idle-heartbeat service anywhere in this file. The
# image ships a supervisor script that greps this file for its own name and
# self-disables on a match; that once broke scale-to-zero. Keep it unnamed.
set -euo pipefail

COMFY_SRC="/opt/workspace-internal/ComfyUI"
mkdir -p /var/log/portal /workspace

# benchmark workflow where the pyworker's BENCHMARK_JSON_PATH looks for it
install -m 644 /opt/krea2/benchmark.json /workspace/benchmark.json 2>/dev/null || true
ln -sfn "$COMFY_SRC" /workspace/ComfyUI

# start the full serverless supervisor stack if comfyui isn't already up
if ! curl -s -o /dev/null --max-time 3 http://127.0.0.1:18188/system_stats; then
  echo "starting serverless supervisor stack (comfyui + api-wrapper + pyworker)"
  SERVERLESS=true setsid supervisord -c /etc/supervisor/supervisord.conf \
    >> /var/log/portal/supervisord.log 2>&1 || true
  for i in $(seq 1 90); do
    curl -s -o /dev/null --max-time 3 http://127.0.0.1:18188/system_stats && { echo "comfyui up after ${i}x2s"; break; }
    sleep 2
  done
  supervisorctl status || true
fi

echo "baked worker onstart complete; models already present:"
ls -la "$COMFY_SRC/models/diffusion_models" "$COMFY_SRC/models/text_encoders" "$COMFY_SRC/models/vae" "$COMFY_SRC/models/loras" 2>/dev/null || true
