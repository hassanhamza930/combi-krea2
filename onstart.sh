#!/bin/bash
# Entry onstart for the krea2-tab1 serverless template (vastai/comfy base image).
# v2: commit-pinned URLs (raw.githubusercontent CDN can serve stale blobs for
# minutes; a pinned commit hash is immutable and always correct).
# 1. Stage benchmark workflow + provisioning script from the pinned commit.
# 2. Persist tokens to /root/hf_token (the provision script prefers it; the
#    instance env may hold a stale HF token).
# 3. Run provisioning (aria2c downloads + the supervisor stack).
#
# [FIX-9] DO NOT name the idle-heartbeat service in this file, in any form.
# The image ships a supervisor script for it that greps THIS file for its own
# name; on a match it assumes onstart bootstraps the service and exits. One
# mention inside a comment was enough to disable it: the heartbeat never ran,
# Vast never saw the worker go idle, inactivity_timeout never fired, and
# workers billed forever. Keeping that name out of this file lets the image
# start and supervise the service itself, which is the intended path - it
# already waits for the /.provisioning gate on its own.
set -euo pipefail

PIN="fb4def9538baf287779100574eb2389344ce9651"
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
