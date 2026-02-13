#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_DIR="${ROOT_DIR}/.lab"
LAB_DOCKER_CONFIG_DIR="${ROOT_DIR}/.lab/docker-config"
NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"
export NOMAD_ADDR
NOMAD_PID_FILE="${LAB_DIR}/nomad/nomad.pid"
NOMAD_LOG_FILE="${LAB_DIR}/nomad/nomad.log"
VAULT_JOB_TEMPLATE="${ROOT_DIR}/nomad/vault.nomad.tmpl.hcl"
VAULT_JOB_RENDERED="${ROOT_DIR}/.lab/generated/vault.nomad.hcl"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

require nomad
require docker
require curl

: "${LAB_VAULT_DEV_ROOT_TOKEN:?LAB_VAULT_DEV_ROOT_TOKEN must be set}"

LAB_DOCKER_HOST="${DOCKER_HOST:-}"
if [[ -z "${LAB_DOCKER_HOST}" ]]; then
  current_docker_context="$(docker context show 2>/dev/null || true)"
  if [[ -n "${current_docker_context}" ]]; then
    LAB_DOCKER_HOST="$(docker context inspect "${current_docker_context}" --format '{{ (index .Endpoints "docker").Host }}' 2>/dev/null || true)"
  fi
fi

mkdir -p "${LAB_DOCKER_CONFIG_DIR}"
if [[ ! -f "${LAB_DOCKER_CONFIG_DIR}/config.json" ]]; then
  cat > "${LAB_DOCKER_CONFIG_DIR}/config.json" <<'EOF'
{
  "auths": {}
}
EOF
fi
export DOCKER_CONFIG="${LAB_DOCKER_CONFIG_DIR}"
if [[ -n "${LAB_DOCKER_HOST}" ]]; then
  export DOCKER_HOST="${LAB_DOCKER_HOST}"
fi

nomad_ready() {
  curl -fsS "${NOMAD_ADDR}/v1/status/leader" >/dev/null 2>&1
}

if nomad_ready; then
  echo "Using existing Nomad cluster at ${NOMAD_ADDR}"
else
  mkdir -p "${LAB_DIR}/nomad" "${LAB_DIR}/nomad/data"

  loopback_iface="lo"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    loopback_iface="lo0"
  fi

  echo "Starting Nomad dev cluster at ${NOMAD_ADDR}"
  nohup nomad agent -dev \
    -bind=127.0.0.1 \
    -network-interface="${loopback_iface}" \
    -data-dir="${LAB_DIR}/nomad/data" \
    >"${NOMAD_LOG_FILE}" 2>&1 &
  echo $! > "${NOMAD_PID_FILE}"

  for _ in $(seq 1 60); do
    if nomad_ready; then
      break
    fi
    sleep 1
  done

  if ! nomad_ready; then
    echo "Nomad did not become ready. See ${NOMAD_LOG_FILE}" >&2
    exit 1
  fi
fi

mkdir -p "${ROOT_DIR}/.lab/generated"
sed "s|__LAB_VAULT_DEV_ROOT_TOKEN__|${LAB_VAULT_DEV_ROOT_TOKEN}|g" \
  "${VAULT_JOB_TEMPLATE}" > "${VAULT_JOB_RENDERED}"

echo "Submitting Vault job to Nomad"
nomad job run -detach "${VAULT_JOB_RENDERED}" >/dev/null

echo "Waiting for Vault allocation in Nomad"
vault_alloc_id=""
for _ in $(seq 1 90); do
  vault_alloc_id="$(nomad job allocs vault 2>/dev/null | awk 'NR>1 && $1 !~ /^ID$/ {print $1; exit}' || true)"
  if [[ -n "${vault_alloc_id}" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "${vault_alloc_id}" ]]; then
  echo "Vault allocation was not created in Nomad" >&2
  exit 1
fi

echo "Waiting for Vault allocation ${vault_alloc_id} to be running"
vault_client_status=""
for _ in $(seq 1 120); do
  vault_client_status="$(nomad alloc status "${vault_alloc_id}" 2>/dev/null | awk -F'= ' '/Client Status/ {print $2; exit}' | tr -d '[:space:]' || true)"
  case "${vault_client_status}" in
    running)
      break
      ;;
    complete|failed|lost)
      break
      ;;
  esac
  sleep 1
done

if [[ "${vault_client_status}" != "running" ]]; then
  echo "Vault allocation ${vault_alloc_id} is not running (status: ${vault_client_status:-unknown})" >&2
  echo "Recent allocation logs:" >&2
  nomad alloc logs "${vault_alloc_id}" >&2 || true
  exit 1
fi

echo "Waiting for Vault at http://127.0.0.1:18200"
for _ in $(seq 1 90); do
  health_code="$(curl --connect-timeout 2 --max-time 3 -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:18200/v1/sys/health?standbyok=true&perfstandbyok=true&sealedcode=503&uninitcode=501" || true)"
  if [[ "${health_code}" == "200" ]]; then
    echo "Vault is reachable"
    exit 0
  fi
  sleep 1
done

echo "Vault did not become ready in time" >&2
exit 1
