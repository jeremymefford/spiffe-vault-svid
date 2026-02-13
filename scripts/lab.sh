#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: ./scripts/lab.sh <command>

Commands:
  up               Bring the lab up (kind + Nomad + Vault + SPIRE + modern app)
  down             Tear the lab down
  verify           Run the federation verification
  verify-negative  Run the negative federation test (expects failure)
  legacy           Run the legacy app job in Nomad
  status           Show a quick status of Kubernetes + Nomad
  logs modern      Tail modern app logs
  logs spire       Tail SPIRE server and agent logs
  logs vault       Tail Vault allocation logs
  help             Show this help
USAGE
}

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

cmd="${1:-}"
shift || true

case "${cmd}" in
  up)
    exec "${ROOT_DIR}/scripts/lab-up.sh" "$@"
    ;;
  down)
    exec "${ROOT_DIR}/scripts/lab-down.sh" "$@"
    ;;
  verify)
    exec "${ROOT_DIR}/scripts/verify-federation.sh" "$@"
    ;;
  verify-negative)
    exec "${ROOT_DIR}/scripts/verify-federation.sh" --negative
    ;;
  legacy)
    exec "${ROOT_DIR}/scripts/run-legacy.sh" "$@"
    ;;
  status)
    require kubectl
    require nomad
    echo "Kubernetes: spire"
    kubectl get pods -n spire || true
    echo
    echo "Kubernetes: modern"
    kubectl get pods -n modern || true
    echo
    echo "Nomad: vault"
    nomad status vault || true
    ;;
  logs)
    target="${1:-}"
    case "${target}" in
      modern)
        require kubectl
        kubectl -n modern logs deploy/modern-app --tail=200
        ;;
      spire)
        require kubectl
        echo "spire-server"
        kubectl -n spire logs statefulset/spire-server --tail=200 || true
        echo
        echo "spire-agent"
        kubectl -n spire logs daemonset/spire-agent --tail=200 || true
        ;;
      vault)
        require nomad
        alloc_id="$(nomad job allocs vault 2>/dev/null | awk 'NR>1 && $1 !~ /^ID$/ {print $1; exit}' || true)"
        if [[ -z "${alloc_id}" ]]; then
          echo "No Vault allocation found" >&2
          exit 1
        fi
        nomad alloc logs "${alloc_id}" vault || true
        ;;
      *)
        usage
        exit 1
        ;;
    esac
    ;;
  help|--help|-h|"")
    usage
    ;;
  *)
    echo "Unknown command: ${cmd}" >&2
    usage
    exit 1
    ;;
esac
