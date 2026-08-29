#!/bin/bash
# Slim onstart for the FULLY-BAKED krea2-tab1 image
# (hassanhamza930/combi-krea2:baked). Models are already inside the image at
# /opt/workspace-internal/ComfyUI/models, so there is NOTHING to download.
# Just stage the benchmark workflow and start the serverless supervisor stack.
# The stack's idle-reporter tells the autoscaler when the box is idle, so
# scale-to-zero keeps working.
#
# [FIX-9] DO NOT name the idle-reporting service anywhere in this file. The
# image ships a supervisor script that greps this file for its own name and
# self-disables on a match; that once broke scale-to-zero. Keep it unnamed.
set -euo pipefail

COMFY_SRC="/opt/workspace-internal/ComfyUI"
mkdir -p /var/log/portal /workspace

# benchmark workflow where the idle-reporter's BENCHMARK_JSON_PATH looks for it
install -m 644 /opt/krea2/benchmark.json /workspace/benchmark.json 2>/dev/null || true
ln -sfn "$COMFY_SRC" /workspace/ComfyUI

# start the full serverless supervisor stack if comfyui isn't already up
if ! curl -s -o /dev/null --max-time 3 http://127.0.0.1:18188/system_stats; then
  echo "starting serverless supervisor stack"
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

# [FIX-15] true scale-to-zero: vast only PARKS idle workers (storage keeps
# billing ~$3/mo). This watcher destroys the whole instance after ~9.5 min
# of real idleness, beating the engine's 10-min park, so idle costs $0.
# No re-rent loop is possible: new workers are recruited only when a request
# is queued, and this fires only after ~9.5 min of zero requests.
if [ -n "${SELFDESTRUCT_KEY:-}" ]; then
  cat > /root/idle_destroy.sh <<'EOS'
#!/bin/bash
KEY="$SELFDESTRUCT_KEY"
find_id() {
  H=$(hostname)
  if curl -s --max-time 10 -H "Authorization: Bearer $KEY" "https://console.vast.ai/api/v0/instances/$H/" | grep -q "krea2-tab1"; then
    echo "$H"; return 0
  fi
  curl -s --max-time 10 -H "Authorization: Bearer $KEY" "https://console.vast.ai/api/v0/instances/" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    lst = d.get('instances') if isinstance(d, dict) else d
    for i in lst or []:
        if 'krea2-tab1' in str(i.get('label','')) and str(i.get('actual_status'))=='running':
            print(i['id']); break
except Exception: pass
"
}
ID=""
PREVH=0
IDLE_LIMIT=${IDLE_DESTROY_SECS:-570}
for i in $(seq 1 150); do
  curl -s -o /dev/null --max-time 3 http://127.0.0.1:18188/system_stats && break
  sleep 4
done
LAST=$(date +%s)
echo "watcher armed; idle limit ${IDLE_LIMIT}s"
while true; do
  sleep 30
  NOW=$(date +%s)
  if [ -z "$ID" ]; then
    ID=$(find_id)
    echo "watcher tick: resolved instance id [$ID]"
    [ -n "$ID" ] || { LAST=$NOW; continue; }
  fi
  Q=$(curl -s --max-time 5 http://127.0.0.1:18188/queue 2>/dev/null)
  if echo "$Q" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if (d.get('queue_running') or d.get('queue_pending')) else 1)" 2>/dev/null; then
    LAST=$NOW
  fi
  H=$(curl -s --max-time 5 http://127.0.0.1:18188/history 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "$PREVH")
  if [ "$H" -gt "$PREVH" ] 2>/dev/null; then LAST=$NOW; PREVH=$H; fi
  IDLE=$((NOW - LAST))
  if [ "$IDLE" -ge "$IDLE_LIMIT" ]; then
    echo "idle ${IDLE}s -> destroying instance $ID"
    for a in 1 2 3 4 5; do
      R=$(curl -s -X DELETE -H "Authorization: Bearer $KEY" "https://console.vast.ai/api/v0/instances/$ID/")
      echo "destroy attempt $a: $R"
      echo "$R" | grep -q "success" && break
      sleep 10
    done
    break
  fi
done
EOS
  chmod +x /root/idle_destroy.sh
  setsid /root/idle_destroy.sh >> /var/log/portal/idle_destroy.log 2>&1 &
  echo "idle-destroy watcher started"
fi
