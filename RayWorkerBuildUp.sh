#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Ray Worker one-shot bootstrap script (no CLI args)
# Run: ./RayWorkerBuildUp.sh
#
# Edit only this block when environment changes.
# ============================================================
RAY_IMAGE="${RAY_IMAGE:-lyon-raycluster:py311-gpu}"
RAY_DOCKERFILE="${RAY_DOCKERFILE:-docker/Dockerfile.gpu}"
AUTO_BUILD_IMAGE="${AUTO_BUILD_IMAGE:-1}"
RAY_NODE_HOSTNAME="${RAY_NODE_HOSTNAME:-$(hostname -f 2>/dev/null || hostname -s)}"
RAY_CONTAINER_NAME="${RAY_CONTAINER_NAME:-ray-worker-node}"

CONSUL_RETRY_JOIN="${CONSUL_RETRY_JOIN:-}"
TAILSCALE_CONTAINER_NAME="${TAILSCALE_CONTAINER_NAME:-consul-tailscale}"
TAILSCALE_IP="${TAILSCALE_IP:-}"
# ============================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAY_CLUSTER_SH="${ROOT_DIR}/ray_cluster.sh"
CONSUL_COMPOSE_FILE="${ROOT_DIR}/consul/server-compose.yml"

log() {
  printf '[RayWorkerBuildUp] %s\n' "$*"
}

fail() {
  printf '[RayWorkerBuildUp] ERROR: %s\n' "$*" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || fail "Missing file: $1"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

filter_ps_lines() {
  if command -v rg >/dev/null 2>&1; then
    rg 'consul|tailscale|ray|NAMES' -N || true
  else
    grep -E 'consul|tailscale|ray|NAMES' || true
  fi
}

ensure_scripts_ready() {
  require_file "${RAY_CLUSTER_SH}"
  chmod +x "${RAY_CLUSTER_SH}" || true
}

validate_consul_retry_join() {
  if [ -z "${CONSUL_RETRY_JOIN}" ]; then
    fail "CONSUL_RETRY_JOIN is empty. Set Tailscale-reachable Consul server IPs, e.g. CONSUL_RETRY_JOIN=\"100.x.x.x 100.y.y.y\""
  fi
  if printf '%s' "${CONSUL_RETRY_JOIN}" | grep -Eq 'cloud\.cs\.priv\.teu\.ac\.jp'; then
    fail "CONSUL_RETRY_JOIN uses VPN hostnames. Use Tailscale-reachable IPs instead, e.g. 100.x.x.x 100.y.y.y"
  fi
}

ensure_image_exists() {
  docker image inspect "${RAY_IMAGE}" >/dev/null 2>&1 || \
    fail "Image '${RAY_IMAGE}' not found. Build first: docker build -f docker/Dockerfile.gpu -t ${RAY_IMAGE} ."
}

ensure_image_ready() {
  if docker image inspect "${RAY_IMAGE}" >/dev/null 2>&1; then
    return 0
  fi

  if [ "${AUTO_BUILD_IMAGE}" != "1" ]; then
    ensure_image_exists
  fi

  [ -f "${ROOT_DIR}/${RAY_DOCKERFILE}" ] || fail "Dockerfile not found: ${ROOT_DIR}/${RAY_DOCKERFILE}"
  log "Image '${RAY_IMAGE}' not found. Building it now..."
  (
    cd "${ROOT_DIR}"
    docker build -f "${RAY_DOCKERFILE}" -t "${RAY_IMAGE}" .
  )
}

start_tailscale_container() {
  if docker ps --format '{{.Names}}' | grep -Fxq "${TAILSCALE_CONTAINER_NAME}"; then
    return 0
  fi
  log "Starting tailscale container: ${TAILSCALE_CONTAINER_NAME}"
  (
    cd "${ROOT_DIR}/consul"
    HOSTNAME="$(hostname -s)" docker compose -f "${CONSUL_COMPOSE_FILE}" up -d tailscale
  )
}

detect_tailscale_ip() {
  docker exec "${TAILSCALE_CONTAINER_NAME}" tailscale ip -4 2>/dev/null | head -n1 || true
}

detect_tailscale_auth_url() {
  docker exec "${TAILSCALE_CONTAINER_NAME}" tailscale status --json 2>/dev/null \
    | tr -d '\n' \
    | sed -n 's/.*"AuthURL"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n1 || true
}

wait_for_tailscale_login() {
  local host_short ip login_url shown_url tick
  host_short="$(hostname -s)"
  shown_url=""
  tick=0

  if [ -n "${TAILSCALE_IP}" ]; then
    log "Using preset TAILSCALE_IP=${TAILSCALE_IP}"
    return 0
  fi

  start_tailscale_container

  ip="$(detect_tailscale_ip)"
  if [ -n "${ip}" ]; then
    TAILSCALE_IP="${ip}"
    log "Detected tailscale IP=${TAILSCALE_IP}"
    return 0
  fi

  log "Running tailscale login command in container and waiting for browser auth..."
  docker exec "${TAILSCALE_CONTAINER_NAME}" tailscale up \
    --accept-dns=false \
    --hostname="consul-${host_short}" \
    --timeout=5s >/dev/null 2>&1 || true

  while true; do
    ip="$(detect_tailscale_ip)"
    if [ -n "${ip}" ]; then
      TAILSCALE_IP="${ip}"
      log "Tailscale login confirmed. IP=${TAILSCALE_IP}"
      return 0
    fi

    login_url="$(detect_tailscale_auth_url)"
    if [ -n "${login_url}" ] && [ "${login_url}" != "${shown_url}" ]; then
      shown_url="${login_url}"
      echo "[RayWorkerBuildUp] Open this URL and login:"
      echo "${login_url}"
    fi

    tick=$((tick + 1))
    if [ $((tick % 6)) -eq 0 ]; then
      docker exec "${TAILSCALE_CONTAINER_NAME}" tailscale up \
        --accept-dns=false \
        --hostname="consul-${host_short}" \
        --timeout=5s >/dev/null 2>&1 || true
    fi

    sleep 5
  done
}

start_consul_client() {
  local join_args=()
  local host
  for host in ${CONSUL_RETRY_JOIN}; do
    join_args+=("-retry-join=${host}")
  done

  log "Starting Consul client (+tailscale network namespace)"
  docker rm -f consul-server >/dev/null 2>&1 || true
  docker rm -f consul-client >/dev/null 2>&1 || true

  docker run -d \
    --name consul-client \
    --network "container:${TAILSCALE_CONTAINER_NAME}" \
    --restart unless-stopped \
    consul:1.14 \
    agent \
    -client=0.0.0.0 \
    -bind="${TAILSCALE_IP}" \
    "${join_args[@]}" >/dev/null
}

wait_for_consul_servers() {
  local i leader
  log "Waiting for consul-client to discover Consul servers..."
  for i in $(seq 1 60); do
    leader="$(docker exec consul-client sh -lc 'curl -sS http://127.0.0.1:8500/v1/status/leader 2>/dev/null || true' || true)"
    if [ -n "${leader}" ] && [ "${leader}" != "\"\"" ] && [ "${leader}" != "No known Consul servers" ]; then
      log "Consul leader detected: ${leader}"
      return 0
    fi
    sleep 2
  done
  docker logs --tail 80 consul-client || true
  fail "consul-client could not discover any Consul server. Check CONSUL_RETRY_JOIN (must be Tailscale IPs)."
}

start_ray_worker() {
  log "Starting Ray worker container"
  "${RAY_CLUSTER_SH}" up worker \
    --tailscale 1 \
    --image "${RAY_IMAGE}" \
    --node-hostname "${RAY_NODE_HOSTNAME}" \
    --container-name "${RAY_CONTAINER_NAME}"
}

print_quick_checks() {
  local consul_endpoint ts_ip ts_dns
  ts_ip="$(docker exec "${TAILSCALE_CONTAINER_NAME}" tailscale ip -4 2>/dev/null | head -n1 || true)"
  ts_dns="$(docker exec "${TAILSCALE_CONTAINER_NAME}" tailscale status --json 2>/dev/null | sed -n 's/.*"DNSName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 || true)"
  ts_dns="${ts_dns%.}"
  consul_endpoint="${ts_dns:-${ts_ip:-127.0.0.1}}"

  echo
  echo "===== QUICK CHECKS ====="
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | filter_ps_lines
  echo
  echo "[consul endpoint]"
  echo "${consul_endpoint}"
  echo
  echo "[consul members]"
  docker exec consul-client consul members || true
  echo
  echo "[consul leader]"
  docker exec consul-client sh -lc 'curl -sS http://127.0.0.1:8500/v1/status/leader || true'
  echo
  echo "[worker logs tail]"
  docker logs --tail 60 "${RAY_CONTAINER_NAME}" || true
}

main() {
  require_cmd docker
  ensure_scripts_ready
  ensure_image_ready
  wait_for_tailscale_login
  validate_consul_retry_join

  start_consul_client
  wait_for_consul_servers
  start_ray_worker
  print_quick_checks
}

main "$@"
