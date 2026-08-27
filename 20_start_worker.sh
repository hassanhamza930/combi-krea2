#!/bin/bash
# Container entrypoint for the krea2-tab1 serverless worker.
# 1. Download models (no-op when already present).
# 2. Start the ComfyUI stack (supervisord from the vastai/comfy layout).
# 3. Wait until ComfyUI (18188) and the api-wrapper (18288) answer, then exec
#    the PyWorker start_server.sh, which clones PYWORKER_REPO and runs
#    workers.comfyui-json.worker with BACKEND=comfyui.
set -e

mkdir -p /var/log/portal /workspace
touch /var/log/portal/api-wrapper.log

echo "=== krea2-tab1 provisioning ==="
/provisioning/10_download_models.sh || {
  echo "FATAL: model provisioning failed"
  exit 1
}

# Start the ComfyUI stack unless something already listens on the wrapper port.
if ! curl -sf http://127.0.0.1:18288/health >/dev/null 2>&1; then
  if [ -f /etc/supervisor/supervisord.conf ]; then
    echo "starting supervisord (ComfyUI + api-wrapper)"
    /usr/bin/supervisord -c /etc/supervisor/supervisord.conf &
  else
    echo "FATAL: no supervisord config found in base image; cannot start ComfyUI stack"
    exit 1
  fi
fi

echo "waiting for ComfyUI stack readiness (max 10 min)"
for i in $(seq 1 300); do
  if curl -sf http://127.0.0.1:18188/system_stats >/dev/null 2>&1 \
     && curl -sf http://127.0.0.1:18288/health >/dev/null 2>&1; then
    echo "ComfyUI stack ready after $((i * 2))s"
    break
  fi
  sleep 2
done

curl -sf http://127.0.0.1:18288/health >/dev/null 2>&1 || {
  echo "FATAL: api-wrapper never became reachable; see container logs"
  exit 1
}

echo "=== handing over to PyWorker ==="
export BENCHMARK_JSON_PATH=/workspace/benchmark.json
export BACKEND="${BACKEND:-comfyui}"
[ -f /workspace/vast-pyworker/start_server.sh ] || { echo "FATAL: start_server.sh not found in /workspace/vast-pyworker"; exit 1; }
exec bash /workspace/vast-pyworker/start_server.sh
