#!/bin/bash
# Entry onstart for the krea2-tab1 serverless template (vastai/comfy base image).
# v2: commit-pinned URLs (raw.githubusercontent CDN can serve stale blobs for
# minutes; a pinned commit hash is immutable and always correct).
# 1. Stage benchmark workflow + provisioning script from the pinned commit.
# 2. Persist tokens to /root/hf_token (the provision script prefers it; the
#    instance env may hold a stale HF token).
# 3. Run provisioning (aria2c downloads + supervisord stack incl. pyworker)
#    while the /.provisioning gate is held.
set -euo pipefail

PIN="e150265529825af6375ef6760fd62fc75ce3688c"
BASE="https://raw.githubusercontent.com/hassanhamza930/combi-krea2/${PIN}"

mkdir -p /var/log/portal /workspace
wget -qO /root/benchmark.json "$BASE/benchmark.json"
wget -qO /root/onstart_provision.sh "$BASE/onstart_provision.sh"
chmod +x /root/onstart_provision.sh

# persist HF token where provisioning reads it (fixes stale-env issue)
if [ -n "${HF_TOKEN:-}" ]; then
  printf '%s' "$HF_TOKEN" > /root/hf_token
  chmod 600 /root/hf_token
fi

touch /.provisioning
bash /root/onstart_provision.sh >> /var/log/portal/provision.log 2>&1
