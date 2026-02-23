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
VAULT_LICENSE_FILE="${LAB_DIR}/vault.hclic"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

require nomad
require docker
require curl
require jq

: "${LAB_VAULT_DEV_ROOT_TOKEN:?LAB_VAULT_DEV_ROOT_TOKEN must be set}"
if [[ ! -f "${VAULT_LICENSE_FILE}" || ! -s "${VAULT_LICENSE_FILE}" ]]; then
  echo "Missing Vault Enterprise license at ${VAULT_LICENSE_FILE}" >&2
  exit 1
fi

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

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[|&\\]/\\&/g'
}

escape_hcl_string() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

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
vault_license_raw="$(< "${VAULT_LICENSE_FILE}")"
vault_license_raw="${vault_license_raw//$'\r'/}"
vault_license_raw="${vault_license_raw//$'\n'/\\n}"
vault_license_escaped="$(escape_hcl_string "${vault_license_raw}")"

vault_local_config="$(jq -c -n '{storage:{raft:{path:"/vault/data",node_id:"vault-1"}},listener:[{tcp:{address:"0.0.0.0:8200",tls_disable:1}}],api_addr:"http://127.0.0.1:18200",cluster_addr:"http://127.0.0.1:18201",ui:true,disable_mlock:true}')"
vault_local_config_escaped="$(escape_hcl_string "${vault_local_config}")"
sed \
  -e "s|__LAB_VAULT_DEV_ROOT_TOKEN__|$(escape_sed_replacement "${LAB_VAULT_DEV_ROOT_TOKEN}")|g" \
  -e "s|__LAB_VAULT_LICENSE__|$(escape_sed_replacement "${vault_license_escaped}")|g" \
  -e "s|__LAB_VAULT_LOCAL_CONFIG__|$(escape_sed_replacement "${vault_local_config_escaped}")|g" \
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
VAULT_HEALTH_URL="http://127.0.0.1:18200/v1/sys/health?standbyok=true&perfstandbyok=true&sealedcode=503&uninitcode=501"
VAULT_UNSEAL_FILE="${LAB_DIR}/vault-unseal.key"

update_env_file() {
  local file="$1"
  local key="$2"
  local value="$3"

  awk -v key="${key}" -v value="${value}" '
    BEGIN {found=0}
    $0 ~ "^export "key"=" {print "export "key"="value; found=1; next}
    {print}
    END {if (!found) print "export "key"="value}
  ' "${file}" > "${file}.tmp"
  mv "${file}.tmp" "${file}"
}

init_vault() {
  local init_resp
  init_resp="$(curl -fsS -X PUT -H "Content-Type: application/json" \
    -d '{"secret_shares":1,"secret_threshold":1}' \
    "http://127.0.0.1:18200/v1/sys/init")"

  local root_token
  local unseal_key
  root_token="$(printf '%s' "${init_resp}" | jq -r '.root_token // empty')"
  unseal_key="$(printf '%s' "${init_resp}" | jq -r '.keys_base64[0] // empty')"
  if [[ -z "${root_token}" || -z "${unseal_key}" ]]; then
    echo "Failed to initialize Vault" >&2
    exit 1
  fi

  printf '%s' "${unseal_key}" > "${VAULT_UNSEAL_FILE}"
  chmod 600 "${VAULT_UNSEAL_FILE}"

  update_env_file "${ROOT_DIR}/.lab/lab-secrets.env" "LAB_VAULT_DEV_ROOT_TOKEN" "${root_token}"
  export LAB_VAULT_DEV_ROOT_TOKEN="${root_token}"
}

unseal_vault() {
  if [[ ! -f "${VAULT_UNSEAL_FILE}" ]]; then
    echo "Missing ${VAULT_UNSEAL_FILE} to unseal Vault" >&2
    exit 1
  fi
  local unseal_key
  unseal_key="$(< "${VAULT_UNSEAL_FILE}")"
  curl -fsS -X PUT -H "Content-Type: application/json" \
    -d "{\"key\":\"${unseal_key}\"}" \
    "http://127.0.0.1:18200/v1/sys/unseal" >/dev/null
}

for _ in $(seq 1 90); do
  health_code="$(curl --connect-timeout 2 --max-time 3 -s -o /dev/null -w '%{http_code}' "${VAULT_HEALTH_URL}" || true)"
  case "${health_code}" in
    200)
      echo "Vault is reachable"
      exit 0
      ;;
    501)
      echo "Vault is uninitialized, initializing"
      init_vault
      ;;
    503)
      echo "Vault is sealed, unsealing"
      unseal_vault
      ;;
  esac
  sleep 1
done

echo "Vault did not become ready in time" >&2
exit 1
