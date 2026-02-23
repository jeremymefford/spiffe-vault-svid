#!/usr/bin/env bash
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:18200}"
: "${VAULT_TOKEN:?VAULT_TOKEN must be set}"

SPIRE_NS="${SPIRE_NS:-spire}"
SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN:-modern.lab}"
SPIFFE_ROLE_NAME="${SPIFFE_ROLE_NAME:-modern-app}"
SPIFFE_WORKLOAD_ID_PATTERN="${SPIFFE_WORKLOAD_ID_PATTERN:-ns/modern/sa/go}"
SPIFFE_JWT_AUDIENCE="${SPIFFE_JWT_AUDIENCE:-vault}"

if [[ "${SPIFFE_WORKLOAD_ID_PATTERN}" == spiffe://* ]]; then
  SPIFFE_WORKLOAD_ID_PATTERN="${SPIFFE_WORKLOAD_ID_PATTERN#spiffe://}"
fi
if [[ "${SPIFFE_WORKLOAD_ID_PATTERN}" == "${SPIFFE_TRUST_DOMAIN}/"* ]]; then
  SPIFFE_WORKLOAD_ID_PATTERN="${SPIFFE_WORKLOAD_ID_PATTERN#"${SPIFFE_TRUST_DOMAIN}/"}"
fi

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

require kubectl
require curl
require jq

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

bundle_json="$(kubectl exec -n "${SPIRE_NS}" statefulset/spire-server -- /opt/spire/bin/spire-server bundle show -format spiffe)"
jwt_bundle="$(printf '%s' "${bundle_json}" | jq -c '{keys:[.keys[] | select(.use == "jwt-svid")]}' )"
if [[ "${jwt_bundle}" == "{\"keys\":[]}" ]]; then
  echo "No JWT authorities found in SPIRE bundle" >&2
  exit 1
fi

echo "Enabling SPIFFE auth method"
if ! vault_request POST /v1/sys/auth/spiffe '{"type":"spiffe","config":{"passthrough_request_headers":["Authorization"]}}' >/dev/null; then
  vault_request DELETE "/v1/sys/auth/spiffe/" >/dev/null || true
  vault_request POST /v1/sys/auth/spiffe '{"type":"spiffe","config":{"passthrough_request_headers":["Authorization"]}}' >/dev/null
fi
vault_request POST /v1/sys/auth/spiffe/tune '{"passthrough_request_headers":["Authorization"]}' >/dev/null || true

config_payload="$(jq -n \
  --arg trust_domain "${SPIFFE_TRUST_DOMAIN}" \
  --arg profile "static" \
  --arg bundle "${jwt_bundle}" \
  --argjson audience "[\"${SPIFFE_JWT_AUDIENCE}\"]" \
  '{trust_domain:$trust_domain,profile:$profile,bundle:$bundle,audience:$audience}')"

vault_request POST /v1/auth/spiffe/config "${config_payload}" >/dev/null

role_payload="$(jq -n \
  --arg pattern "${SPIFFE_WORKLOAD_ID_PATTERN}" \
  --arg policy "${SPIFFE_ROLE_NAME}" \
  '{workload_id_patterns:[$pattern],token_policies:[$policy],token_ttl:"15m",token_max_ttl:"1h"}')"

vault_request POST "/v1/auth/spiffe/role/${SPIFFE_ROLE_NAME}" "${role_payload}" >/dev/null

echo "Vault SPIFFE auth configured for trust domain ${SPIFFE_TRUST_DOMAIN}"
