#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="spiffe-vault-lab"
LAB_DOCKER_CONFIG_DIR="${ROOT_DIR}/.lab/docker-config"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

require kind
require kubectl
require docker
require nomad
require openssl
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

echo "Generating and loading lab secrets"
"${ROOT_DIR}/scripts/primer.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/.lab/lab-secrets.env"

if [[ -z "${LAB_VAULT_DEV_ROOT_TOKEN:-}" || -z "${LAB_KEYSTORE_PASSWORD:-}" ]]; then
  echo "Missing secrets in .lab/lab-secrets.env. Re-run scripts/primer.sh." >&2
  exit 1
fi

if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "Creating kind cluster ${CLUSTER_NAME}"
  kind create cluster --config "${ROOT_DIR}/kind/kind-config.yaml"
else
  echo "Using existing kind cluster ${CLUSTER_NAME}"
fi

echo "Starting Nomad and deploying Vault"
LAB_VAULT_DEV_ROOT_TOKEN="${LAB_VAULT_DEV_ROOT_TOKEN}" \
  "${ROOT_DIR}/scripts/nomad-up.sh"

echo "Configuring Vault PKI + AppRole"
VAULT_ADDR="http://127.0.0.1:18200" \
LAB_VAULT_ADDR_NOMAD="http://host.docker.internal:18200" \
LAB_MODERN_URL_NOMAD="https://host.docker.internal:30443/hello" \
VAULT_TOKEN="${LAB_VAULT_DEV_ROOT_TOKEN}" \
LAB_KEYSTORE_PASSWORD="${LAB_KEYSTORE_PASSWORD}" \
  "${ROOT_DIR}/scripts/configure-vault.sh"

echo "Deploying SPIRE"
kubectl apply -f "${ROOT_DIR}/k8s/spire/rbac.yaml"
kubectl -n spire create secret generic spire-upstream-ca \
  --from-file=root-ca.crt="${ROOT_DIR}/infra/pki/modern-root-ca.crt" \
  --from-file=root-ca.key="${ROOT_DIR}/infra/pki/modern-root-ca.key" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n spire create secret generic spire-legacy-bundle \
  --from-file=legacy-root-ca.crt="${ROOT_DIR}/infra/pki/legacy-root-ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${ROOT_DIR}/k8s/spire/server.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/spire/agent.yaml"
kubectl rollout restart statefulset/spire-server -n spire
kubectl rollout restart daemonset/spire-agent -n spire
kubectl wait --for=condition=ready --timeout=180s pod -l app=spire-server -n spire
kubectl rollout status daemonset/spire-agent -n spire --timeout=180s

echo "Registering modern app workload in SPIRE"
"${ROOT_DIR}/scripts/configure-spire.sh"

echo "Building and loading modern app image"
docker build -t modern-app:latest "${ROOT_DIR}/modern-app"
kind load docker-image modern-app:latest --name "${CLUSTER_NAME}"

echo "Deploying modern app"
kubectl apply -f "${ROOT_DIR}/k8s/modern-app/deployment.yaml"
kubectl rollout restart deployment/modern-app -n modern
kubectl rollout status deployment/modern-app -n modern --timeout=180s

echo "Lab is ready"
echo "1) ./scripts/run-legacy.sh"
