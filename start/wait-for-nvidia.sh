#!/usr/bin/env bash
for i in $(seq 1 60); do
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    echo "nvidia-smi OK"
    break
  fi
  echo "Waiting for nvidia driver..."
  sleep 2
done

python3 - <<'PY'
import time,sys
try:
  import torch
except Exception:
  print("torch not installed; continuing")
  sys.exit(0)
for i in range(20):
  if torch.cuda.is_available():
    print("torch.cuda available")
    sys.exit(0)
  time.sleep(1)
print("torch.cuda NOT available; proceed but GPU tasks will wait")
PY