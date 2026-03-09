#!/usr/bin/env bash
set -euo pipefail

# Simple Ray operator for this repository.
# Edit defaults here for your VM fleet.
DEFAULT_IMAGE="${RAY_IMAGE:-lyon-raycluster:py311-gpu}"
DEFAULT_WORKSPACE="${RAY_WORKSPACE_PATH:-$HOME/raycluster/workspace}"
DEFAULT_SSH_KEY_PATH="${RAY_SSH_KEY_PATH:-$HOME/.ssh/authorized_keys}"
DEFAULT_NODE_HOSTNAME="${RAY_NODE_HOSTNAME:-$(hostname -f 2>/dev/null || hostname -s)}"
DEFAULT_USE_TAILSCALE="${USE_TAILSCALE:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONSUL_DIR="${ROOT_DIR}/consul"

ACTION="${1:-help}"
ROLE="${2:-}"
shift 2 || true

RAY_NODE_HOSTNAME_VALUE="${DEFAULT_NODE_HOSTNAME}"
USE_TAILSCALE_VALUE="${DEFAULT_USE_TAILSCALE}"
RAY_CONTAINER_NAME_VALUE=""
RAY_IMAGE_VALUE="${DEFAULT_IMAGE}"
RAY_WORKSPACE_VALUE="${DEFAULT_WORKSPACE}"
SSH_KEY_PATH_VALUE="${DEFAULT_SSH_KEY_PATH}"

usage() {
  cat <<USAGE
Usage:
  ./ray_cluster.sh up <head|worker> [options]
  ./ray_cluster.sh down <head|worker> [options]
  ./ray_cluster.sh status
  ./ray_cluster.sh logs <head|worker>

Options:
  --tailscale <0|1>         Use existing consul-tailscale network (default: ${DEFAULT_USE_TAILSCALE})
  --node-hostname <name>    Value for RAY_NODE_HOSTNAME (default: ${DEFAULT_NODE_HOSTNAME})
  --container-name <name>   Override container_name in compose
  --image <image>           Override Ray image (default: ${DEFAULT_IMAGE})
  --workspace <path>        Override workspace bind path (head only)
  --ssh-key <path>          Copy this key into head container after start

Notes:
  - This script keeps your existing compose structure and just orchestrates it.
  - For tailscale mode, it uses consul/ray-only-head.yml or consul/ray-only-worker.yml.
USAGE
}

log() {
  printf '[ray_cluster] %s\n' "$*"
}

fail() {
  printf '[ray_cluster] ERROR: %s\n' "$*" >&2
  exit 1
}

ensure_image_exists() {
  local image="$1"
  if docker image inspect "${image}" >/dev/null 2>&1; then
    return 0
  fi
  fail "Docker image '${image}' is not available on this VM. Build it first: docker build -f docker/Dockerfile.gpu -t ${image} ."
}

require_role() {
  case "${ROLE}" in
    head|worker) ;;
    *) fail "Role must be 'head' or 'worker'" ;;
  esac
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tailscale)
        USE_TAILSCALE_VALUE="${2:-}"
        shift 2
        ;;
      --node-hostname)
        RAY_NODE_HOSTNAME_VALUE="${2:-}"
        shift 2
        ;;
      --container-name)
        RAY_CONTAINER_NAME_VALUE="${2:-}"
        shift 2
        ;;
      --image)
        RAY_IMAGE_VALUE="${2:-}"
        shift 2
        ;;
      --workspace)
        RAY_WORKSPACE_VALUE="${2:-}"
        shift 2
        ;;
      --ssh-key)
        SSH_KEY_PATH_VALUE="${2:-}"
        shift 2
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done
}

compose_file_for_role() {
  if [ "${USE_TAILSCALE_VALUE}" = "1" ]; then
    if [ "${ROLE}" = "head" ]; then
      echo "${CONSUL_DIR}/ray-only-head.yml"
    else
      echo "${CONSUL_DIR}/ray-only-worker.yml"
    fi
  else
    if [ "${ROLE}" = "head" ]; then
      echo "${CONSUL_DIR}/head-compose.yml"
    else
      echo "${CONSUL_DIR}/worker-compose.yml"
    fi
  fi
}

container_for_role() {
  if [ -n "${RAY_CONTAINER_NAME_VALUE}" ]; then
    echo "${RAY_CONTAINER_NAME_VALUE}"
    return
  fi

  if [ "${ROLE}" = "head" ]; then
    echo "ray-head-candidate"
  else
    echo "ray-worker-node"
  fi
}

up_node() {
  require_role
  parse_args "$@"

  local file
  local container
  file="$(compose_file_for_role)"
  container="$(container_for_role)"

  if [ "${USE_TAILSCALE_VALUE}" = "1" ]; then
    docker ps --format '{{.Names}}' | grep -Fxq consul-tailscale || \
      fail "consul-tailscale container is required for --tailscale 1"
  fi

  log "Compose file: ${file}"
  log "Role=${ROLE}, Container=${container}, NodeHostname=${RAY_NODE_HOSTNAME_VALUE}"
  ensure_image_exists "${RAY_IMAGE_VALUE}"

  (
    cd "${CONSUL_DIR}"
    RAY_NODE_HOSTNAME="${RAY_NODE_HOSTNAME_VALUE}" \
    RAY_CONTAINER_NAME="${container}" \
    RAY_IMAGE="${RAY_IMAGE_VALUE}" \
    RAY_WORKSPACE_PATH="${RAY_WORKSPACE_VALUE}" \
      docker compose -f "${file}" up -d
  )

  if [ "${ROLE}" = "head" ] && [ -f "${SSH_KEY_PATH_VALUE}" ]; then
    docker exec "${container}" sh -lc 'mkdir -p /root/.ssh && chmod 700 /root/.ssh' || true
    docker cp "${SSH_KEY_PATH_VALUE}" "${container}:/root/.ssh/authorized_keys" || true
    docker exec "${container}" sh -lc 'chmod 600 /root/.ssh/authorized_keys' || true
    log "SSH authorized_keys copied to ${container}"
  fi
}

down_node() {
  require_role
  parse_args "$@"

  local container
  container="$(container_for_role)"
  docker rm -f "${container}" >/dev/null 2>&1 || true
  log "Removed ${container}"
}

show_status() {
  if command -v rg >/dev/null 2>&1; then
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | rg 'ray-|consul|tailscale|NAMES' -N || true
  else
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E 'ray-|consul|tailscale|NAMES' || true
  fi
}

show_logs() {
  require_role
  parse_args "$@"

  local container
  container="$(container_for_role)"
  docker logs --tail 120 "${container}" || true
}

case "${ACTION}" in
  up)
    up_node "$@"
    ;;
  down)
    down_node "$@"
    ;;
  status)
    show_status
    ;;
  logs)
    show_logs "$@"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    fail "Unknown action: ${ACTION}"
    ;;
esac
