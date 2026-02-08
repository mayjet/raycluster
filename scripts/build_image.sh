#!/bin/bash
set -e

IMAGE_NAME=lyon-raycluster:py311-gpu

docker build \
  --network=host \
  -f docker/Dockerfile.gpu \
  -t ${IMAGE_NAME} .
