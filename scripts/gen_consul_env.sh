#!/usr/bin/env bash
set -euo pipefail

# Generate consul/.env with CONSUL_BIND/ADVERTISE and optional retry-join list.
# Usage:
#   CONSUL_BIND_HOSTNAME=lyon002.cloud.cs.priv.teu.ac.jp \
#   CONSUL_BOOTSTRAP_EXPECT=2 \
#   CONSUL_RETRY_JOIN="lyon002.cloud.cs.priv.teu.ac.jp lyon004.cloud.cs.priv.teu.ac.jp" \
#   ./scripts/gen_consul_env.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_SHORT="$(hostname -s)"
ENV_PATH_DEFAULT="${ROOT_DIR}/consul/.env.${HOST_SHORT}"
ENV_PATH="${CONSUL_ENV_PATH:-${ENV_PATH_DEFAULT}}"

CONSUL_BOOTSTRAP_EXPECT="${CONSUL_BOOTSTRAP_EXPECT:-2}"
CONSUL_BIND="${CONSUL_BIND:-}"
CONSUL_BIND_HOSTNAME="${CONSUL_BIND_HOSTNAME:-${RAY_NODE_HOSTNAME:-}}"
CONSUL_BIND_IFACE="${CONSUL_BIND_IFACE:-}"
CONSUL_RETRY_JOIN="${CONSUL_RETRY_JOIN:-}"

resolve_ip() {
  local host="$1"
  getent hosts "$host" | awk '{print $1}' | head -n1
}

ip_is_local() {
  local ip="$1"
  ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$ip"
}

if [ -z "$CONSUL_BIND" ]; then
  if [ -n "$CONSUL_BIND_HOSTNAME" ]; then
    CONSUL_BIND="$(resolve_ip "$CONSUL_BIND_HOSTNAME" || true)"
    if [ -n "$CONSUL_BIND" ] && ! ip_is_local "$CONSUL_BIND"; then
      echo "Resolved IP ${CONSUL_BIND} is not on this host; ignoring." >&2
      CONSUL_BIND=""
    fi
  fi
fi

if [ -z "$CONSUL_BIND" ]; then
  if [ -n "$CONSUL_BIND_IFACE" ]; then
    CONSUL_BIND="$(ip -o -4 addr show dev "$CONSUL_BIND_IFACE" | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
  fi
fi

if [ -z "$CONSUL_BIND" ]; then
  CONSUL_BIND="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  if [ -n "$CONSUL_BIND" ] && ! ip_is_local "$CONSUL_BIND"; then
    CONSUL_BIND=""
  fi
fi

if [ -z "$CONSUL_BIND" ]; then
  echo "Failed to detect CONSUL_BIND. Set CONSUL_BIND or CONSUL_BIND_HOSTNAME." >&2
  exit 1
fi

CONSUL_ADVERTISE="${CONSUL_ADVERTISE:-$CONSUL_BIND}"

RETRY_JOIN_ARGS=""
if [ -n "$CONSUL_RETRY_JOIN" ]; then
  for host in $CONSUL_RETRY_JOIN; do
    RETRY_JOIN_ARGS="${RETRY_JOIN_ARGS} -retry-join=${host}"
  done
fi

cat >"$ENV_PATH" <<EOF
CONSUL_BIND=${CONSUL_BIND}
CONSUL_ADVERTISE=${CONSUL_ADVERTISE}
CONSUL_BOOTSTRAP_EXPECT=${CONSUL_BOOTSTRAP_EXPECT}
CONSUL_RETRY_JOIN=${RETRY_JOIN_ARGS}
EOF

echo "Wrote ${ENV_PATH}"
