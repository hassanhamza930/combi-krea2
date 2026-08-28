#!/bin/bash
# Entry onstart for the krea2-tab1 serverless template (vastai/comfy base image).
# 1. Stage the benchmark workflow + provisioning script from this repo.
# 2. Run provisioning (aria2c model downloads) while /.provisioning gate is held;
#    the image's supervisor (SERVERLESS=true) auto-starts ComfyUI, api-wrapper
#    and the pyworker bootstrap once the gate is released.
set -euo pipefail

BASE="https://raw.githubusercontent.com/hassanhamza930/combi-krea2/main"

mkdir -p /var/log/portal /workspace
wget -qO /root/benchmark.json "$BASE/benchmark.json"
wget -qO /root/onstart_provision.sh "$BASE/onstart_provision.sh"
chmod +x /root/onstart_provision.sh

touch /.provisioning
bash /root/onstart_provision.sh >> /var/log/portal/provision.log 2>&1
