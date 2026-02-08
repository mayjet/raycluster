#!/usr/bin/env bash
set -euo pipefail

CONSUL_HTTP=${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}
HOSTNAME=$(hostname -s)
HEAD_MODE=${HEAD_MODE:-false}
JUPYTER=${JUPYTER:-no}
LOCAL_IP=${RAY_NODE_IP:-}
if [ -z "${LOCAL_IP}" ]; then
  LOCAL_IP=$(ip -o -4 addr show scope global \
    | awk '$2 !~ /^(lo|docker|br-|virbr)/ {print $4}' \
    | cut -d/ -f1 \
    | head -n1)
fi
LOCAL_IP=${LOCAL_IP:-$(hostname -I | awk '{print $1}' || echo "127.0.0.1")}
KV_LEADER_KEY="service/ray/leader"
SESSION_NAME="ray-leader-session-${HOSTNAME}"

# Start SSH server (if authorized_keys present; allow fallback)
if [ -f /root/.ssh/authorized_keys ]; then
  echo "Starting sshd (authorized_keys present)"
  /usr/sbin/sshd
else
  echo "No /root/.ssh/authorized_keys found — sshd will start but without auth keys (not recommended)."
  /usr/sbin/sshd || true
fi

create_session() {
  curl -sS -X PUT "${CONSUL_HTTP}/v1/session/create" -d "{\"Name\":\"${SESSION_NAME}\",\"TTL\":\"20s\",\"LockDelay\":\"1s\"}" | jq -r '.ID'
}

destroy_session() {
  if [ -n "${SESSION_ID:-}" ]; then
    curl -sS -X PUT "${CONSUL_HTTP}/v1/session/destroy/${SESSION_ID}" >/dev/null || true
  fi
}

acquire_lock() {
  local sid="$1"
  curl -sS -X PUT "${CONSUL_HTTP}/v1/kv/${KV_LEADER_KEY}?acquire=${sid}" -d "${HOSTNAME}"
}

release_lock() {
  local sid="$1"
  curl -sS -X PUT "${CONSUL_HTTP}/v1/kv/${KV_LEADER_KEY}?release=${sid}" -d "${HOSTNAME}"
}

# If RAY_HEAD_ADDRESS is set, connect directly to Ray head
if [ -n "${RAY_HEAD_ADDRESS:-}" ]; then
  echo "Connecting directly to Ray head at ${RAY_HEAD_ADDRESS}"
  /usr/local/bin/start-scripts/wait-for-nvidia.sh || true
  ray stop || true
  until ray start --address="${RAY_HEAD_ADDRESS}" --block; do
    echo "Retry connecting to ${RAY_HEAD_ADDRESS}..."
    sleep 5
  done
  tail -f /dev/null
fi

# If forced to head mode via env, start head directly and register
if [ "$HEAD_MODE" = "true" ]; then
  echo "Forced HEAD_MODE=true: starting ray head now"
  /usr/local/bin/start-scripts/wait-for-nvidia.sh || true
  ray stop || true
  ray start --head --port=6379 --dashboard-host=0.0.0.0 --block &
  # register service
  cat <<EOF >/tmp/ray-head-service.json
{
  "Name": "ray-head",
  "ID": "ray-head-${HOSTNAME}",
  "Address": "${LOCAL_IP}",
  "Port": 6379,
  "Tags": ["ray","head"]
}
EOF
  curl -sS -X PUT "${CONSUL_HTTP}/v1/agent/service/register" -d @/tmp/ray-head-service.json || true
  if [ "$JUPYTER" = "yes" ]; then
    mkdir -p /workspace/logs
    nohup jupyter lab --ip=0.0.0.0 --allow-root --NotebookApp.token='' --NotebookApp.password='' > /workspace/logs/jupyter.log 2>&1 &
  fi
  tail -f /dev/null
fi

# normal operation: try to become leader using Consul session
while true; do
  SESSION_ID=$(create_session)
  echo "Created session ${SESSION_ID}"
  ok=$(acquire_lock "${SESSION_ID}" || echo "false")
  if [ "$ok" = "true" ]; then
    echo "Acquired leadership as ${HOSTNAME}"
    /usr/local/bin/start-scripts/wait-for-nvidia.sh || true
    ray stop || true
    ray start --head --port=6379 --dashboard-host=0.0.0.0 --block &
    # register service
    cat <<EOF >/tmp/ray-head-service.json
{
  "Name": "ray-head",
  "ID": "ray-head-${HOSTNAME}",
  "Address": "${LOCAL_IP}",
  "Port": 6379,
  "Tags": ["ray","head"]
}
EOF
    curl -sS -X PUT "${CONSUL_HTTP}/v1/agent/service/register" -d @/tmp/ray-head-service.json || true

    if [ "$JUPYTER" = "yes" ]; then
      mkdir -p /workspace/logs
      nohup jupyter lab --ip=0.0.0.0 --allow-root --NotebookApp.token='' --NotebookApp.password='' > /workspace/logs/jupyter.log 2>&1 &
    fi

    # keep session alive (renew)
    while true; do
      curl -sS -X PUT "${CONSUL_HTTP}/v1/session/renew/${SESSION_ID}" >/dev/null 2>&1 || break
      sleep 5
    done

    echo "Leadership lost; deregistering"
    curl -sS -X PUT "${CONSUL_HTTP}/v1/agent/service/deregister/ray-head-${HOSTNAME}" || true
    destroy_session || true
  else
    destroy_session || true
    # find current leader via catalog service
    svc=$(curl -sS "${CONSUL_HTTP}/v1/catalog/service/ray-head" || true)
    ip=$(echo "$svc" | jq -r '.[0].ServiceAddress // .[0].Address' 2>/dev/null || true)
    if [ -n "$ip" ] && [ "$ip" != "null" ]; then
      echo "Joining head at ${ip}"
      until ray start --address="${ip}:6379" --block; do
        echo "Retry join to ${ip}..."
        sleep 5
      done
      tail -f /dev/null
    fi
    # nothing to join -> retry acquiring
    sleep 5
  fi
done
