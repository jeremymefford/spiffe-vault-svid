#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/legacy-app/lab.env"
JOB_TEMPLATE="${ROOT_DIR}/nomad/legacy-app.nomad.tmpl.hcl"
JOB_RENDERED="${ROOT_DIR}/.lab/generated/legacy-app.nomad.hcl"
MODERN_ROOT_CA_FILE="${ROOT_DIR}/infra/pki/modern-root-ca.crt"
NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"
LAB_DOCKER_CONFIG_DIR="${ROOT_DIR}/.lab/docker-config"
export NOMAD_ADDR

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}. Run scripts/lab-up.sh first." >&2
  exit 1
fi

if [[ ! -f "${MODERN_ROOT_CA_FILE}" ]]; then
  echo "Missing ${MODERN_ROOT_CA_FILE}. Run scripts/lab-up.sh first." >&2
  exit 1
fi

require nomad
require docker
require curl

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

if ! curl -fsS "${NOMAD_ADDR}/v1/status/leader" >/dev/null 2>&1; then
  echo "Nomad is not reachable at ${NOMAD_ADDR}. Run scripts/lab-up.sh first." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${ENV_FILE}"

: "${LAB_VAULT_ROLE_ID:?LAB_VAULT_ROLE_ID is required}"
: "${LAB_VAULT_SECRET_ID:?LAB_VAULT_SECRET_ID is required}"
: "${LAB_LEGACY_SPIFFE_ID:?LAB_LEGACY_SPIFFE_ID is required}"
: "${LAB_KEYSTORE_PASSWORD:?LAB_KEYSTORE_PASSWORD is required}"

LAB_VAULT_ADDR_NOMAD="${LAB_VAULT_ADDR_NOMAD:-http://host.docker.internal:18200}"
LAB_MODERN_URL_NOMAD="${LAB_MODERN_URL_NOMAD:-https://host.docker.internal:30443/hello}"

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[|&\\]/\\&/g'
}

modern_root_ca_pem="$(< "${MODERN_ROOT_CA_FILE}")"
if [[ -z "${modern_root_ca_pem}" ]]; then
  echo "Modern root CA is empty at ${MODERN_ROOT_CA_FILE}" >&2
  exit 1
fi
modern_root_ca_pem="${modern_root_ca_pem//$'\n'/\\n}"

echo "Building legacy-app image for Nomad"
docker build -t legacy-app:latest "${ROOT_DIR}/legacy-app" >/dev/null
legacy_image_ref="$(docker image inspect --format '{{.Id}}' legacy-app:latest)"
if [[ -z "${legacy_image_ref}" ]]; then
  echo "Unable to resolve local image ID for legacy-app:latest" >&2
  exit 1
fi

mkdir -p "${ROOT_DIR}/.lab/generated"

sed \
  -e "s|__LAB_LEGACY_IMAGE__|$(escape_sed_replacement "${legacy_image_ref}")|g" \
  -e "s|__LAB_VAULT_ADDR_NOMAD__|$(escape_sed_replacement "${LAB_VAULT_ADDR_NOMAD}")|g" \
  -e "s|__LAB_VAULT_ROLE_ID__|$(escape_sed_replacement "${LAB_VAULT_ROLE_ID}")|g" \
  -e "s|__LAB_VAULT_SECRET_ID__|$(escape_sed_replacement "${LAB_VAULT_SECRET_ID}")|g" \
  -e "s|__LAB_LEGACY_SPIFFE_ID__|$(escape_sed_replacement "${LAB_LEGACY_SPIFFE_ID}")|g" \
  -e "s|__LAB_MODERN_URL_NOMAD__|$(escape_sed_replacement "${LAB_MODERN_URL_NOMAD}")|g" \
  -e "s|__LAB_MODERN_ROOT_CA_PEM__|$(escape_sed_replacement "${modern_root_ca_pem}")|g" \
  -e "s|__LAB_KEYSTORE_PASSWORD__|$(escape_sed_replacement "${LAB_KEYSTORE_PASSWORD}")|g" \
  "${JOB_TEMPLATE}" > "${JOB_RENDERED}"

nomad job stop -purge -yes legacy-app >/dev/null 2>&1 || true

echo "Submitting legacy-app batch job to Nomad"
nomad job run -detach "${JOB_RENDERED}" >/dev/null

echo "Waiting for legacy-app allocation"
alloc_id=""
for _ in $(seq 1 60); do
  alloc_id="$(nomad job allocs legacy-app 2>/dev/null | awk 'NR>1 && $1 !~ /^ID$/ {print $1; exit}' || true)"
  if [[ -n "${alloc_id}" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "${alloc_id}" ]]; then
  echo "Failed to find legacy-app allocation in Nomad" >&2
  exit 1
fi

client_status=""
for _ in $(seq 1 120); do
  client_status="$(nomad alloc status "${alloc_id}" 2>/dev/null | awk -F'= ' '/Client Status/ {print $2; exit}' | tr -d '[:space:]' || true)"
  case "${client_status}" in
    complete|failed|lost)
      break
      ;;
  esac
  sleep 1
done

echo "Legacy app allocation logs:"
nomad alloc logs "${alloc_id}" || true

if [[ "${client_status}" != "complete" ]]; then
  echo "legacy-app job did not complete successfully (status: ${client_status:-unknown})" >&2
  exit 1
fi
