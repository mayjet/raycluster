#!/usr/bin/env bash
set -euo pipefail
IMAGE=${1:-registry.example.com/project:py311-uv}
NODES=("vm01" "vm02" "vm03")  # replace
for h in "${NODES[@]}"; do
  echo "Deploy to $h"
  ssh "$h" "docker pull ${IMAGE} || true; docker rm -f ray-node || true; docker run -d --name ray-node --network host -v /var/local/cache/project:/var/local/cache/project -v /full/path/to/project/workspace_code:/workspace/code:ro -v /full/path/to/authorized_keys:/root/.ssh/authorized_keys:ro -e CONSUL_HTTP_ADDR=http://127.0.0.1:8500 ${IMAGE}"
done