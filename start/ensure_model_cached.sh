#!/usr/bin/env bash
set -euo pipefail
MODEL_ID="${1:?model-id}"
LOCAL_ROOT="${2:-/var/local/cache/project/models}"
SOURCE="${3:-/workspace/models-store}"

mkdir -p "$LOCAL_ROOT"
LOCK_DIR="/var/lock/project_model_locks"
mkdir -p "$LOCK_DIR"
LOCAL_TARGET="${LOCAL_ROOT}/${MODEL_ID}"
TEMP_TARGET="${LOCAL_TARGET}.partial"
LOCK_FILE="${LOCK_DIR}/${MODEL_ID}.lock"

exec 9>"$LOCK_FILE"
flock -x 9

if [ -d "$LOCAL_TARGET" ] && [ -f "${LOCAL_TARGET}/.complete" ]; then
  echo "Model ${MODEL_ID} already cached locally"
  flock -u 9
  exit 0
fi

rm -rf "$TEMP_TARGET" && mkdir -p "$TEMP_TARGET"

if [[ "$SOURCE" == /* || "$SOURCE" == file://* ]]; then
  if [[ "$SOURCE" == file://* ]]; then SOURCE_PATH="${SOURCE#file://}"; else SOURCE_PATH="$SOURCE"; fi
  if [ -d "${SOURCE_PATH}/${MODEL_ID}" ]; then
    rsync -a --delete --partial "${SOURCE_PATH}/${MODEL_ID}/" "${TEMP_TARGET}/"
  else
    echo "Model not found at ${SOURCE_PATH}/${MODEL_ID}"
    flock -u 9
    exit 2
  fi
else
  echo "Downloading from HF: ${MODEL_ID}"
  python3 - <<PY
from huggingface_hub import snapshot_download
snapshot_download(repo_id="${MODEL_ID}", local_dir="${TEMP_TARGET}", resume_download=True)
PY
fi

mv "$TEMP_TARGET" "$LOCAL_TARGET"
touch "${LOCAL_TARGET}/.complete"
flock -u 9
echo "Model cached at ${LOCAL_TARGET}"