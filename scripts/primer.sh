#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_DIR="${ROOT_DIR}/.lab"
SECRETS_ENV="${LAB_DIR}/lab-secrets.env"
ROTATE="${1:-}"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

require openssl

mkdir -p "${LAB_DIR}"

if [[ "${ROTATE}" == "--rotate" ]]; then
  rm -f "${SECRETS_ENV}"
fi

if [[ -f "${SECRETS_ENV}" ]]; then
  echo "Using existing secret seed file: ${SECRETS_ENV}"
else
  vault_root_token="$(openssl rand -hex 32)"
  keystore_password="$(openssl rand -hex 24)"

  cat > "${SECRETS_ENV}" <<ENV
export LAB_VAULT_DEV_ROOT_TOKEN=${vault_root_token}
export LAB_KEYSTORE_PASSWORD=${keystore_password}
ENV

  chmod 600 "${SECRETS_ENV}"
  echo "Created secret seed file: ${SECRETS_ENV}"
fi

"${ROOT_DIR}/scripts/bootstrap-ca.sh"

echo "Primer complete. Load secrets with: source .lab/lab-secrets.env"
