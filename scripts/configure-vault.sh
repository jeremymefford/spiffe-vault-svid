#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKI_DIR="${ROOT_DIR}/infra/pki"
LEGACY_ROOT_CERT="${PKI_DIR}/legacy-root-ca.crt"

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:18200}"
: "${VAULT_TOKEN:?VAULT_TOKEN must be set}"
: "${LAB_KEYSTORE_PASSWORD:?LAB_KEYSTORE_PASSWORD must be set}"
LEGACY_SPIFFE_ID="${LEGACY_SPIFFE_ID:-spiffe://legacy.lab/ns/legacy/sa/springboot}"
MODERN_URL="${LAB_MODERN_URL:-https://localhost:30443/hello}"
VAULT_ADDR_NOMAD="${LAB_VAULT_ADDR_NOMAD:-http://host.docker.internal:18200}"
MODERN_URL_NOMAD="${LAB_MODERN_URL_NOMAD:-https://host.docker.internal:30443/hello}"
ROLE_NAME="legacy-app"
PKI_ROLE_NAME="legacy-svid"

mkdir -p "${PKI_DIR}"

escape_json_file() {
  sed -e ':a' -e 'N' -e '$!ba' -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\n/\\n/g' "$1"
}

vault_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  if [[ -n "${body}" ]]; then
    curl -fsS -X "${method}" \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "${body}" \
      "${VAULT_ADDR}${path}"
  else
    curl -fsS -X "${method}" \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      "${VAULT_ADDR}${path}"
  fi
}

extract_json_value() {
  local key="$1"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1
}

echo "Checking Vault readiness at ${VAULT_ADDR}"
vault_health_url="${VAULT_ADDR}/v1/sys/health?standbyok=true&perfstandbyok=true&sealedcode=503&uninitcode=501"
vault_health_code=""
for _ in $(seq 1 60); do
  vault_health_code="$(curl --connect-timeout 2 --max-time 3 -s -o /dev/null -w '%{http_code}' "${vault_health_url}" || true)"
  if [[ "${vault_health_code}" == "200" ]]; then
    break
  fi
  sleep 1
done

if [[ "${vault_health_code}" != "200" ]]; then
  echo "Vault not ready after timeout (last health code: ${vault_health_code:-unknown})" >&2
  exit 1
fi

status_code="$(curl -s -o /dev/null -w '%{http_code}' -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/sys/mounts/pki/")"
if [[ "${status_code}" == "404" || "${status_code}" == "400" ]]; then
  echo "Enabling pki secrets engine"
  vault_request POST /v1/sys/mounts/pki '{"type":"pki","description":"SPIFFE lab pki"}' >/dev/null
fi

vault_request POST /v1/sys/mounts/pki/tune '{"max_lease_ttl":"87600h"}' >/dev/null
ca_status_code="$(curl -s -o /dev/null -w '%{http_code}' -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/pki/ca/pem" || true)"
if [[ "${ca_status_code}" != "200" ]]; then
  echo "Generating legacy trust domain root CA inside Vault"
  vault_request POST /v1/pki/root/generate/internal \
    '{"common_name":"legacy.lab SPIFFE Root","ttl":"87600h","key_type":"rsa","key_bits":4096}' >/dev/null
fi

vault_request POST /v1/pki/config/urls "{\"issuing_certificates\":\"${VAULT_ADDR}/v1/pki/ca\",\"crl_distribution_points\":\"${VAULT_ADDR}/v1/pki/crl\"}" >/dev/null

echo "Fetching legacy root CA from Vault"
curl -fsS -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/pki/ca/pem" > "${LEGACY_ROOT_CERT}"

echo "Configuring role ${PKI_ROLE_NAME}"
vault_request POST "/v1/pki/roles/${PKI_ROLE_NAME}" \
  "{\"allow_any_name\":true,\"enforce_hostnames\":false,\"require_cn\":false,\"key_type\":\"rsa\",\"key_bits\":2048,\"ttl\":\"30m\",\"max_ttl\":\"1h\",\"key_usage\":\"DigitalSignature,KeyEncipherment,KeyAgreement\",\"ext_key_usage\":\"ServerAuth,ClientAuth\",\"allowed_uri_sans\":\"${LEGACY_SPIFFE_ID}\"}" >/dev/null

policy_file="$(mktemp)"
cat > "${policy_file}" <<POLICY
path "pki/issue/${PKI_ROLE_NAME}" {
  capabilities = ["update"]
}

path "pki/cert/ca" {
  capabilities = ["read"]
}
POLICY

policy_escaped="$(escape_json_file "${policy_file}")"
rm -f "${policy_file}"

vault_request PUT "/v1/sys/policies/acl/${ROLE_NAME}" "{\"policy\":\"${policy_escaped}\"}" >/dev/null

auth_status="$(curl -s -o /dev/null -w '%{http_code}' -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/sys/auth/approle/")"
if [[ "${auth_status}" == "404" || "${auth_status}" == "400" ]]; then
  echo "Enabling approle auth method"
  vault_request POST /v1/sys/auth/approle '{"type":"approle"}' >/dev/null
fi

vault_request POST "/v1/auth/approle/role/${ROLE_NAME}" '{"token_policies":["legacy-app"],"token_ttl":"1h","token_max_ttl":"4h","secret_id_num_uses":0}' >/dev/null

role_id_json="$(vault_request GET "/v1/auth/approle/role/${ROLE_NAME}/role-id")"
secret_id_json="$(vault_request POST "/v1/auth/approle/role/${ROLE_NAME}/secret-id" '{}')"

ROLE_ID="$(printf '%s' "${role_id_json}" | extract_json_value role_id)"
SECRET_ID="$(printf '%s' "${secret_id_json}" | extract_json_value secret_id)"

if [[ -z "${ROLE_ID}" || -z "${SECRET_ID}" ]]; then
  echo "Failed to fetch AppRole credentials" >&2
  exit 1
fi

cat > "${ROOT_DIR}/legacy-app/lab.env" <<ENV
export LAB_VAULT_ADDR=${VAULT_ADDR}
export LAB_VAULT_ADDR_NOMAD=${VAULT_ADDR_NOMAD}
export LAB_VAULT_ROLE_ID=${ROLE_ID}
export LAB_VAULT_SECRET_ID=${SECRET_ID}
export LAB_LEGACY_SPIFFE_ID=${LEGACY_SPIFFE_ID}
export LAB_MODERN_URL=${MODERN_URL}
export LAB_MODERN_URL_NOMAD=${MODERN_URL_NOMAD}
export LAB_KEYSTORE_PASSWORD=${LAB_KEYSTORE_PASSWORD}
ENV

cp "${LEGACY_ROOT_CERT}" "${ROOT_DIR}/legacy-app/root-ca.crt"

echo "Vault configured. Legacy app env written to legacy-app/lab.env"
