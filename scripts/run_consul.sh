#!/bin/bash
set -e

docker run -d \
  --name consul \
  --restart unless-stopped \
  --network host \
  consul:1.15 \
  agent \
  -server \
  -bootstrap-expect=1 \
  -ui \
  -client=0.0.0.0
