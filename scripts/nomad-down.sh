#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_DIR="${ROOT_DIR}/.lab"
NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"
export NOMAD_ADDR
NOMAD_PID_FILE="${LAB_DIR}/nomad/nomad.pid"

if ! command -v curl >/dev/null 2>&1; then
  echo "Missing required command: curl" >&2
  exit 1
fi

if ! command -v nomad >/dev/null 2>&1; then
  if [[ -f "${NOMAD_PID_FILE}" ]]; then
    pid="$(cat "${NOMAD_PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" >/dev/null 2>&1 || true
    fi
    rm -f "${NOMAD_PID_FILE}"
  fi
  exit 0
fi

nomad_ready() {
  curl -fsS "${NOMAD_ADDR}/v1/status/leader" >/dev/null 2>&1
}

if nomad_ready; then
  nomad job stop -purge -yes legacy-app >/dev/null 2>&1 || true
  nomad job stop -purge -yes vault >/dev/null 2>&1 || true
fi

if [[ -f "${NOMAD_PID_FILE}" ]]; then
  pid="$(cat "${NOMAD_PID_FILE}" 2>/dev/null || true)"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" >/dev/null 2>&1 || true
  fi
  rm -f "${NOMAD_PID_FILE}"
fi
