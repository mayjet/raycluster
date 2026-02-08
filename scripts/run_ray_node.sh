#!/bin/bash
set -e

IMAGE=ray-gpu-cu124
CONTAINER=ray-node

docker rm -f ${CONTAINER} 2>/dev/null || true

docker run -d \
  --name ${CONTAINER} \
  --restart unless-stopped \
  --gpus all \
  --network host \
  -v $(pwd)/workspace:/workspace \
  ${IMAGE}
