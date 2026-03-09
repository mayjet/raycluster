#!/usr/bin/env bash
set -euo pipefail

# Simple Consul operator for this repository.
# Edit the defaults in this block if your environment differs.
DEFAULT_BOOTSTRAP_EXPECT="${CONSUL_BOOTSTRAP_EXPECT:-2}"
DEFAULT_RETRY_JOIN="${CONSUL_RETRY_JOIN:-lyon002.cloud.cs.priv.teu.ac.jp lyon004.cloud.cs.priv.teu.ac.jp}"
DEFAULT_TAILSCALE_CONTAINER="${TAILSCALE_CONTAINER_NAME:-consul-tailscale}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONSUL_DIR="${ROOT_DIR}/consul"
COMPOSE_FILE="${CONSUL_DIR}/server-compose.yml"
HOST_SHORT="$(hostname -s)"
ENV_FILE="${CONSUL_ENV_FILE:-${CONSUL_DIR}/.env.${HOST_SHORT}.tailscale}"

ACTION="${1:-help}"
shift || true

BOOTSTRAP_EXPECT="${DEFAULT_BOOTSTRAP_EXPECT}"
RETRY_JOIN="${DEFAULT_RETRY_JOIN}"
TAILSCALE_IP="${TAILSCALE_IP:-}"
TAILSCALE_CONTAINER="${DEFAULT_TAILSCALE_CONTAINER}"

usage() {
  cat <<USAGE
Usage:
  ./consul_cluster.sh up [--tailscale-ip IP] [--retry-join "host1 host2 ..."] [--bootstrap-expect N]
  ./consul_cluster.sh down
  ./consul_cluster.sh status
  ./consul_cluster.sh logs

Notes:
  - This script preserves the existing Tailscale + Consul compose structure.
  - 'up' starts tailscale first when needed, then starts the Consul server container.
  - If --tailscale-ip is omitted, it tries: docker exec ${TAILSCALE_CONTAINER} tailscale ip -4
  - If tailscale is not logged in yet, run: docker exec -it ${TAILSCALE_CONTAINER} tailscale up
USAGE
}

log() {
  printf '[consul_cluster] %s\n' "$*"
}

fail() {
  printf '[consul_cluster] ERROR: %s\n' "$*" >&2
  exit 1
}

retry_join_args() {
  local out=""
  local host
  for host in $RETRY_JOIN; do
    out+=" -retry-join=${host}"
  done
  printf '%s' "$out"
}

detect_tailscale_ip() {
  docker exec "${TAILSCALE_CONTAINER}" tailscale ip -4 2>/dev/null | head -n1 || true
}

start_tailscale_if_needed() {
  if docker ps --format '{{.Names}}' | grep -Fxq "${TAILSCALE_CONTAINER}"; then
    return
  fi

  log "${TAILSCALE_CONTAINER} is not running. Starting tailscale service..."
  (
    cd "${CONSUL_DIR}"
    HOSTNAME="$(hostname -s)" docker compose -f "${COMPOSE_FILE}" up -d tailscale
  )
}

wait_for_tailscale_ip() {
  local tries="${1:-12}"
  local delay_sec="${2:-2}"
  local i

  for i in $(seq 1 "${tries}"); do
    TAILSCALE_IP="$(detect_tailscale_ip)"
    if [ -n "${TAILSCALE_IP}" ]; then
      return 0
    fi
    sleep "${delay_sec}"
  done

  return 1
}

run_tailscale_up_with_authkey() {
  local host_short
  host_short="$(hostname -s)"
  docker exec "${TAILSCALE_CONTAINER}" tailscale up \
    --authkey="${TAILSCALE_AUTHKEY}" \
    --hostname="consul-${host_short}" \
    --accept-dns=false >/dev/null
}

write_env() {
  local retry_args
  retry_args="$(retry_join_args)"
  cat >"${ENV_FILE}" <<EOT
CONSUL_BOOTSTRAP_EXPECT=${BOOTSTRAP_EXPECT}
CONSUL_RETRY_JOIN=${retry_args}
TAILSCALE_IP=${TAILSCALE_IP}
EOT
}

parse_up_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tailscale-ip)
        TAILSCALE_IP="${2:-}"
        shift 2
        ;;
      --retry-join)
        RETRY_JOIN="${2:-}"
        shift 2
        ;;
      --bootstrap-expect)
        BOOTSTRAP_EXPECT="${2:-}"
        shift 2
        ;;
      --tailscale-container)
        TAILSCALE_CONTAINER="${2:-}"
        shift 2
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done
}

up_server() {
  parse_up_args "$@"

  if [ -z "${TAILSCALE_IP}" ]; then
    start_tailscale_if_needed
    if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
      log "TAILSCALE_AUTHKEY is set. Running tailscale up in ${TAILSCALE_CONTAINER}..."
      run_tailscale_up_with_authkey || true
    fi
    wait_for_tailscale_ip || true
  fi
  if [ -z "${TAILSCALE_IP}" ]; then
    log "tailscale IP could not be detected from ${TAILSCALE_CONTAINER}"
    log "Hint: authenticate tailscale container and retry:"
    log "  docker exec -it ${TAILSCALE_CONTAINER} tailscale up --accept-dns=false --hostname=consul-$(hostname -s)"
    log "  # or with auth key:"
    log "  TAILSCALE_AUTHKEY=tskey-xxxx ./consul_cluster.sh up ..."
    log "  # login URL (if shown in logs):"
    log "  docker logs ${TAILSCALE_CONTAINER} 2>&1 | grep 'https://login.tailscale.com'"
    fail "TAILSCALE_IP is empty. Pass --tailscale-ip explicitly after tailscale auth."
  fi

  write_env
  log "Using TAILSCALE_IP=${TAILSCALE_IP}"
  log "Writing env: ${ENV_FILE}"

  (
    cd "${CONSUL_DIR}"
    HOSTNAME="$(hostname -s)" docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d consul
  )

  log "Consul server started"
}

down_server() {
  docker rm -f consul-server >/dev/null 2>&1 || true
  log "Consul server container removed (tailscale container kept)"
}

show_status() {
  if command -v rg >/dev/null 2>&1; then
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | rg 'consul|tailscale|NAMES' -N || true
  else
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E 'consul|tailscale|NAMES' || true
  fi
  if docker ps --format '{{.Names}}' | grep -Fxq consul-server; then
    echo
    docker exec consul-server consul members || true
  fi
}

show_logs() {
  docker logs --tail 120 consul-server || true
}

case "${ACTION}" in
  up)
    up_server "$@"
    ;;
  down)
    down_server
    ;;
  status)
    show_status
    ;;
  logs)
    show_logs
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    fail "Unknown action: ${ACTION}"
    ;;
esac
