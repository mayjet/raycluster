#!/usr/bin/env bash
CACHE_DIR="${1:-/var/local/cache/project}"
MAX_BYTES="${2:-50000000000}"  # default 50GB

current_size=$(du -sb "$CACHE_DIR" | awk '{print $1}' || echo 0)
if [ "$current_size" -le "$MAX_BYTES" ]; then
  echo "Cache under limit ($current_size <= $MAX_BYTES)"
  exit 0
fi

echo "Cleaning cache ($current_size > $MAX_BYTES)"
for d in $(find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -n | awk '{print $2}'); do
  echo "Removing $d"
  rm -rf "$d"
  current_size=$(du -sb "$CACHE_DIR" | awk '{print $1}')
  if [ "$current_size" -le "$MAX_BYTES" ]; then
    echo "Cache cleaned to $current_size"
    break
  fi
done