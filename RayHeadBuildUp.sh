#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Ray Head one-shot bootstrap script (no CLI args)
# Run: ./RayHeadBuildUp.sh
#
# Edit only this block when environment changes.
# ============================================================
RAY_IMAGE="${RAY_IMAGE:-lyon-raycluster:py311-gpu}"
RAY_DOCKERFILE="${RAY_DOCKERFILE:-docker/Dockerfile.gpu}"
AUTO_BUILD_IMAGE="${AUTO_BUILD_IMAGE:-1}"
RAY_NODE_HOSTNAME="${RAY_NODE_HOSTNAME:-$(hostname -f 2>/dev/null || hostname -s)}"
RAY_WORKSPACE_PATH="${RAY_WORKSPACE_PATH:-$HOME/raycluster/workspace}"
RAY_CONTAINER_NAME="${RAY_CONTAINER_NAME:-ray-head-candidate}"
RAY_SSH_KEY_PATH="${RAY_SSH_KEY_PATH:-$HOME/.ssh/authorized_keys}"

CONSUL_BOOTSTRAP_EXPECT="${CONSUL_BOOTSTRAP_EXPECT:-2}"
CONSUL_RETRY_JOIN="${CONSUL_RETRY_JOIN:-lyon002.cloud.cs.priv.teu.ac.jp lyon004.cloud.cs.priv.teu.ac.jp}"
TAILSCALE_CONTAINER_NAME="${TAILSCALE_CONTAINER_NAME:-consul-tailscale}"
TAILSCALE_IP="${TAILSCALE_IP:-}"
# ============================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONSUL_CLUSTER_SH="${ROOT_DIR}/consul_cluster.sh"
RAY_CLUSTER_SH="${ROOT_DIR}/ray_cluster.sh"
CONSUL_COMPOSE_FILE="${ROOT_DIR}/consul/server-compose.yml"

log() {
  printf '[RayHeadBuildUp] %s\n' "$*"
}

fail() {
  printf '[RayHeadBuildUp] ERROR: %s\n' "$*" >&2
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
  require_file "${CONSUL_CLUSTER_SH}"
  require_file "${RAY_CLUSTER_SH}"
  chmod +x "${CONSUL_CLUSTER_SH}" "${RAY_CLUSTER_SH}" || true
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
      echo "[RayHeadBuildUp] Open this URL and login:"
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

start_consul() {
  log "Starting Consul server (+tailscale)"
  if [ -n "${TAILSCALE_IP}" ]; then
    "${CONSUL_CLUSTER_SH}" up \
      --tailscale-ip "${TAILSCALE_IP}" \
      --bootstrap-expect "${CONSUL_BOOTSTRAP_EXPECT}" \
      --retry-join "${CONSUL_RETRY_JOIN}" \
      --tailscale-container "${TAILSCALE_CONTAINER_NAME}"
  else
    "${CONSUL_CLUSTER_SH}" up \
      --bootstrap-expect "${CONSUL_BOOTSTRAP_EXPECT}" \
      --retry-join "${CONSUL_RETRY_JOIN}" \
      --tailscale-container "${TAILSCALE_CONTAINER_NAME}"
  fi
}

start_ray_head() {
  log "Starting Ray head container"
  RAY_NODE_IP="${TAILSCALE_IP}" "${RAY_CLUSTER_SH}" up head \
    --tailscale 1 \
    --image "${RAY_IMAGE}" \
    --node-hostname "${RAY_NODE_HOSTNAME}" \
    --workspace "${RAY_WORKSPACE_PATH}" \
    --container-name "${RAY_CONTAINER_NAME}" \
    --ssh-key "${RAY_SSH_KEY_PATH}"
}

apply_ssh_key_and_restart_sshd() {
  [ -f "${RAY_SSH_KEY_PATH}" ] || fail "authorized_keys not found: ${RAY_SSH_KEY_PATH}"

  log "Applying authorized_keys into ${RAY_CONTAINER_NAME}"
  docker exec "${RAY_CONTAINER_NAME}" sh -lc 'mkdir -p /root/.ssh && chmod 700 /root/.ssh'
  docker cp "${RAY_SSH_KEY_PATH}" "${RAY_CONTAINER_NAME}:/root/.ssh/authorized_keys"
  docker exec "${RAY_CONTAINER_NAME}" sh -lc 'chmod 600 /root/.ssh/authorized_keys'

  log "Restarting sshd in ${RAY_CONTAINER_NAME}"
  docker exec "${RAY_CONTAINER_NAME}" sh -lc 'pkill -x sshd >/dev/null 2>&1 || true; /usr/sbin/sshd'
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
  echo "[consul leader]"
  docker exec consul-server sh -lc "curl -sS http://${consul_endpoint}:8500/v1/status/leader || true"
  echo
  echo "[ray status]"
  docker exec "${RAY_CONTAINER_NAME}" sh -lc 'ray status || true'
  echo
  echo "[sshd]"
  docker exec "${RAY_CONTAINER_NAME}" sh -lc 'ps -ef | grep "[s]shd" || true'
}

main() {
  require_cmd docker
  ensure_scripts_ready
  ensure_image_ready
  wait_for_tailscale_login

  start_consul
  start_ray_head
  apply_ssh_key_and_restart_sshd
  print_quick_checks
}

main "$@"
