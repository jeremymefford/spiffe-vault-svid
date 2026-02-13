#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKI_DIR="${ROOT_DIR}/infra/pki"
MODERN_ROOT_KEY="${PKI_DIR}/modern-root-ca.key"
MODERN_ROOT_CERT="${PKI_DIR}/modern-root-ca.crt"
MODERN_ROOT_BUNDLE="${PKI_DIR}/modern-root-ca-bundle.pem"
LEGACY_ROOT_KEY="${PKI_DIR}/legacy-root-ca.key"
LEGACY_ROOT_CERT="${PKI_DIR}/legacy-root-ca.crt"
LEGACY_ROOT_BUNDLE="${PKI_DIR}/legacy-root-ca-bundle.pem"

mkdir -p "${PKI_DIR}"

if [[ ! -f "${MODERN_ROOT_KEY}" || ! -f "${MODERN_ROOT_CERT}" ]]; then
  echo "Generating modern trust domain root CA in ${PKI_DIR}"
  openssl genrsa -out "${MODERN_ROOT_KEY}" 4096 >/dev/null 2>&1
  openssl req -x509 -new -nodes \
    -key "${MODERN_ROOT_KEY}" \
    -sha256 \
    -days 3650 \
    -subj "/CN=modern.lab SPIFFE Root" \
    -out "${MODERN_ROOT_CERT}" >/dev/null 2>&1
fi

if [[ ! -f "${LEGACY_ROOT_KEY}" || ! -f "${LEGACY_ROOT_CERT}" ]]; then
  echo "Generating legacy trust domain root CA in ${PKI_DIR}"
  openssl genrsa -out "${LEGACY_ROOT_KEY}" 4096 >/dev/null 2>&1
  openssl req -x509 -new -nodes \
    -key "${LEGACY_ROOT_KEY}" \
    -sha256 \
    -days 3650 \
    -subj "/CN=legacy.lab SPIFFE Root" \
    -out "${LEGACY_ROOT_CERT}" >/dev/null 2>&1
fi

cat "${MODERN_ROOT_KEY}" "${MODERN_ROOT_CERT}" > "${MODERN_ROOT_BUNDLE}"
cat "${LEGACY_ROOT_KEY}" "${LEGACY_ROOT_CERT}" > "${LEGACY_ROOT_BUNDLE}"

echo "Modern root CA ready: ${MODERN_ROOT_CERT}"
echo "Legacy root CA ready: ${LEGACY_ROOT_CERT}"
