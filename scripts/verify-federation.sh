#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:18200}"
SPIRE_NS="${SPIRE_NS:-spire}"
MODERN_SPIFFE_ID="${MODERN_SPIFFE_ID:-spiffe://modern.lab/ns/modern/sa/go}"
WORKLOAD_SELECTOR="${WORKLOAD_SELECTOR:-unix:uid:1000}"
LEGACY_TRUST_DOMAIN="${LEGACY_TRUST_DOMAIN:-legacy.lab}"
NEGATIVE_TEST="${1:-}"
LEGACY_TRUST_DOMAIN_ID="${LEGACY_TRUST_DOMAIN}"

if [[ "${LEGACY_TRUST_DOMAIN_ID}" != spiffe://* ]]; then
  LEGACY_TRUST_DOMAIN_ID="spiffe://${LEGACY_TRUST_DOMAIN_ID}"
fi

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

require kubectl
require curl
require openssl

print_modern_logs() {
  echo "Modern app logs (tail 200):"
  kubectl -n modern logs deploy/modern-app --tail=200 2>/dev/null || true
}

if [[ ! -f "${ROOT_DIR}/.lab/lab-secrets.env" ]]; then
  echo "Missing .lab/lab-secrets.env. Run scripts/lab-up.sh first." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${ROOT_DIR}/.lab/lab-secrets.env"

if [[ -z "${LAB_VAULT_DEV_ROOT_TOKEN:-}" ]]; then
  echo "Missing LAB_VAULT_DEV_ROOT_TOKEN in .lab/lab-secrets.env" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

echo "1) Vault is the legacy trust domain CA"
curl -fsS -H "X-Vault-Token: ${LAB_VAULT_DEV_ROOT_TOKEN}" \
  "${VAULT_ADDR}/v1/pki/ca/pem" > "${tmp_dir}/vault-legacy.pem"
vault_fp="$(openssl x509 -noout -fingerprint -sha256 -in "${tmp_dir}/vault-legacy.pem")"
file_fp="$(openssl x509 -noout -fingerprint -sha256 -in "${ROOT_DIR}/infra/pki/legacy-root-ca.crt")"
echo "Vault legacy CA: ${vault_fp}"
echo "Local legacy CA: ${file_fp}"
if [[ "${vault_fp}" != "${file_fp}" ]]; then
  echo "Legacy CA mismatch between Vault and local bundle" >&2
  exit 1
fi

echo "2) SPIRE has the legacy federated bundle"
bundle_output="$(kubectl exec -n "${SPIRE_NS}" statefulset/spire-server -- /opt/spire/bin/spire-server bundle list -id "${LEGACY_TRUST_DOMAIN_ID}" -format pem 2>/dev/null || true)"
printf '%s\n' "${bundle_output}" | awk 'BEGIN{p=0} /BEGIN CERTIFICATE/{p=1} p{print} /END CERTIFICATE/{exit}' > "${tmp_dir}/spire-legacy.pem"
if [[ ! -s "${tmp_dir}/spire-legacy.pem" ]]; then
  echo "Unable to extract legacy bundle PEM from SPIRE" >&2
  exit 1
fi
spire_fp="$(openssl x509 -noout -fingerprint -sha256 -in "${tmp_dir}/spire-legacy.pem")"
echo "SPIRE legacy bundle: ${spire_fp}"
if [[ "${spire_fp}" != "${vault_fp}" ]]; then
  echo "SPIRE legacy bundle does not match Vault CA" >&2
  exit 1
fi

if [[ "${NEGATIVE_TEST}" == "--negative" ]]; then
  echo "3) Negative test: remove federation bundle and expect failure"
  echo "Removing federation from modern app entry"
  existing_entry_ids="$(kubectl exec -n "${SPIRE_NS}" statefulset/spire-server -- /opt/spire/bin/spire-server entry show -spiffeID "${MODERN_SPIFFE_ID}" 2>/dev/null | awk -F': *' '/^Entry ID/ {print $2}')"
  if [[ -n "${existing_entry_ids}" ]]; then
    while IFS= read -r entry_id; do
      [[ -z "${entry_id}" ]] && continue
      kubectl exec -n "${SPIRE_NS}" statefulset/spire-server -- /opt/spire/bin/spire-server entry delete -entryID "${entry_id}" >/dev/null
    done <<< "${existing_entry_ids}"
  fi

  AGENT_ID=""
  for _ in $(seq 1 60); do
    AGENT_ID="$(kubectl exec -n "${SPIRE_NS}" statefulset/spire-server -- /opt/spire/bin/spire-server agent list 2>/dev/null | grep -m1 -o 'spiffe://[^[:space:]]*' || true)"
    if [[ -n "${AGENT_ID}" ]]; then
      break
    fi
    sleep 2
  done
  if [[ -z "${AGENT_ID}" ]]; then
    echo "No attested SPIRE agent found for negative test" >&2
    exit 1
  fi

  kubectl exec -n "${SPIRE_NS}" statefulset/spire-server -- /opt/spire/bin/spire-server entry create \
    -spiffeID "${MODERN_SPIFFE_ID}" \
    -parentID "${AGENT_ID}" \
    -selector "${WORKLOAD_SELECTOR}" >/dev/null

  kubectl exec -n "${SPIRE_NS}" statefulset/spire-server -- /opt/spire/bin/spire-server bundle delete -id "${LEGACY_TRUST_DOMAIN_ID}" >/dev/null 2>&1 || true
  echo "Restarting SPIRE agent to flush cached bundles"
  kubectl -n "${SPIRE_NS}" rollout restart daemonset/spire-agent >/dev/null
  kubectl -n "${SPIRE_NS}" rollout status daemonset/spire-agent --timeout=120s >/dev/null
  echo "Restarting modern app to ensure fresh bundle state"
  kubectl -n modern rollout restart deployment/modern-app >/dev/null
  kubectl -n modern rollout status deployment/modern-app --timeout=120s >/dev/null
  set +e
  "${ROOT_DIR}/scripts/run-legacy.sh" | tee "${tmp_dir}/legacy.out"
  rc="$?"
  set -e
  print_modern_logs
  if [[ "${rc}" -eq 0 ]]; then
    echo "Unexpected success without federation" >&2
    "${ROOT_DIR}/scripts/configure-spire.sh" >/dev/null 2>&1 || true
    kubectl -n "${SPIRE_NS}" rollout restart daemonset/spire-agent >/dev/null 2>&1 || true
    kubectl -n "${SPIRE_NS}" rollout status daemonset/spire-agent --timeout=120s >/dev/null 2>&1 || true
    kubectl -n modern rollout restart deployment/modern-app >/dev/null 2>&1 || true
    kubectl -n modern rollout status deployment/modern-app --timeout=120s >/dev/null 2>&1 || true
    exit 1
  fi
  echo "Negative test produced failure as expected."
  echo "Restoring federation bundle"
  "${ROOT_DIR}/scripts/configure-spire.sh" >/dev/null
  kubectl -n "${SPIRE_NS}" rollout restart daemonset/spire-agent >/dev/null
  kubectl -n "${SPIRE_NS}" rollout status daemonset/spire-agent --timeout=120s >/dev/null
  kubectl -n modern rollout restart deployment/modern-app >/dev/null
  kubectl -n modern rollout status deployment/modern-app --timeout=120s >/dev/null
else
  echo "3) Data plane: run legacy job and expect acceptance"
  "${ROOT_DIR}/scripts/run-legacy.sh" | tee "${tmp_dir}/legacy.out"
  print_modern_logs
  kubectl -n modern logs deploy/modern-app --tail=200 | grep -q "Vault KV v2 message:"
  grep -q "Modern app status: 200" "${tmp_dir}/legacy.out"
  grep -q "accepted client spiffe://${LEGACY_TRUST_DOMAIN}/" "${tmp_dir}/legacy.out"
  grep -q "Legacy app KV v2 message:" "${tmp_dir}/legacy.out"
fi

echo "Federation verification complete."
