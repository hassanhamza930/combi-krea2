# Tab 1 as a Vast.ai serverless endpoint.
#
# Base image: vastai/comfy — ComfyUI + comfyui-api-wrapper (ports 18188/18288)
# under supervisord, the same layout vast's official ComfyUI serverless
# template expects. The comfyui-json PyWorker clones itself at boot via
# start_server.sh (PYWORKER_REPO), so it is NOT baked here.
#
# Models are downloaded at first worker boot by /provisioning/10_download_models.sh
# into /workspace (persists across cold->warm cycles on the same worker), NOT at
# build time. That keeps the pushed image small, the GH Action fast, and the
# public image free of NSFW checkpoints.
FROM vastai/comfy:v0.34.0-cuda-13.2-py312

ENV DEBIAN_FRONTEND=noninteractive

# jq/curl used by provisioning.
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends jq curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Krea 2 Tab 1 benchmark workflow (real workload, not SD1.5 fallback).
COPY benchmark.json /opt/krea2/benchmark.json

# Model provisioning runs on first boot (has network + tokens from template env).
COPY 10_download_models.sh /provisioning/10_download_models.sh
RUN chmod +x /provisioning/10_download_models.sh

# Entrypoint: start the ComfyUI stack, wait for readiness, then hand over to
# vast's PyWorker bootstrap (start_server.sh clones the comfyui-json worker
# itself into /workspace/vast-pyworker on boot).
COPY 20_start_worker.sh /start_worker.sh
RUN chmod +x /start_worker.sh

ENTRYPOINT ["/start_worker.sh"]
