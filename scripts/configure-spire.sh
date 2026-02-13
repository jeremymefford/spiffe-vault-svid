#!/usr/bin/env bash
set -euo pipefail

SPIRE_NS="${SPIRE_NS:-spire}"
MODERN_SPIFFE_ID="${MODERN_SPIFFE_ID:-spiffe://modern.lab/ns/modern/sa/go}"
WORKLOAD_SELECTOR="${WORKLOAD_SELECTOR:-unix:uid:1000}"
LEGACY_TRUST_DOMAIN="${LEGACY_TRUST_DOMAIN:-legacy.lab}"
LEGACY_BUNDLE_PATH="${LEGACY_BUNDLE_PATH:-/run/spire/legacy-bundle/legacy-root-ca.crt}"
LEGACY_TRUST_DOMAIN_ID="${LEGACY_TRUST_DOMAIN}"

if [[ "${LEGACY_TRUST_DOMAIN_ID}" != spiffe://* ]]; then
  LEGACY_TRUST_DOMAIN_ID="spiffe://${LEGACY_TRUST_DOMAIN_ID}"
fi

server_pod() {
  kubectl get pod -n "${SPIRE_NS}" -l app=spire-server -o jsonpath='{.items[0].metadata.name}'
}

SPIRE_SERVER_POD="$(server_pod)"
if [[ -z "${SPIRE_SERVER_POD}" ]]; then
  echo "Unable to find SPIRE server pod in namespace ${SPIRE_NS}" >&2
  exit 1
fi

echo "Waiting for an attested SPIRE agent..."
AGENT_ID=""
for _ in $(seq 1 60); do
  AGENT_ID="$(kubectl exec -n "${SPIRE_NS}" "${SPIRE_SERVER_POD}" -- /opt/spire/bin/spire-server agent list 2>/dev/null | grep -m1 -o 'spiffe://[^[:space:]]*' || true)"
  if [[ -n "${AGENT_ID}" ]]; then
    break
  fi
  sleep 2
done

if [[ -z "${AGENT_ID}" ]]; then
  echo "No attested SPIRE agent found" >&2
  exit 1
fi

echo "Using agent parent ID: ${AGENT_ID}"

existing_entry_ids="$(kubectl exec -n "${SPIRE_NS}" "${SPIRE_SERVER_POD}" -- /opt/spire/bin/spire-server entry show -spiffeID "${MODERN_SPIFFE_ID}" 2>/dev/null | awk -F': *' '/^Entry ID/ {print $2}')"
if [[ -n "${existing_entry_ids}" ]]; then
  echo "Removing existing entries for ${MODERN_SPIFFE_ID}"
  while IFS= read -r entry_id; do
    [[ -z "${entry_id}" ]] && continue
    kubectl exec -n "${SPIRE_NS}" "${SPIRE_SERVER_POD}" -- /opt/spire/bin/spire-server entry delete -entryID "${entry_id}" >/dev/null
  done <<< "${existing_entry_ids}"
fi

echo "Registering federated bundle for ${LEGACY_TRUST_DOMAIN}"
kubectl exec -n "${SPIRE_NS}" "${SPIRE_SERVER_POD}" -- /opt/spire/bin/spire-server bundle set \
  -id "${LEGACY_TRUST_DOMAIN_ID}" \
  -path "${LEGACY_BUNDLE_PATH}" \
  -format pem >/dev/null

echo "Creating registration entry for modern app"
kubectl exec -n "${SPIRE_NS}" "${SPIRE_SERVER_POD}" -- /opt/spire/bin/spire-server entry create \
  -spiffeID "${MODERN_SPIFFE_ID}" \
  -parentID "${AGENT_ID}" \
  -selector "${WORKLOAD_SELECTOR}" \
  -federatesWith "${LEGACY_TRUST_DOMAIN_ID}" >/dev/null

echo "SPIRE registration ready for ${MODERN_SPIFFE_ID}"
