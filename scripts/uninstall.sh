#!/usr/bin/env bash
set -euo pipefail

NGINX_CONF_DIR="/etc/nginx/conf.d"
NGINX_CONF_NAME="openclaw-dashboard.conf"
STATE_DIR="/etc/nginx/openclaw"
WINDOWCTL_INSTALL_PATH="/usr/local/sbin/openclaw-windowctl"
NGINX_BIN="${NGINX_BIN:-nginx}"

usage() {
  cat <<USAGE
Usage:
  $0 [--keep-state]
USAGE
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] Run as root." >&2
    exit 1
  fi
}

main() {
  require_root

  local keep_state="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-state)
        keep_state="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "[ERROR] Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  if [[ -f "${NGINX_CONF_DIR}/${NGINX_CONF_NAME}" ]]; then
    rm -f "${NGINX_CONF_DIR}/${NGINX_CONF_NAME}"
  fi

  if [[ -f "${WINDOWCTL_INSTALL_PATH}" ]]; then
    rm -f "${WINDOWCTL_INSTALL_PATH}"
  fi

  if [[ "${keep_state}" != "true" && -d "${STATE_DIR}" ]]; then
    rm -rf "${STATE_DIR}"
  fi

  "${NGINX_BIN}" -t
  "${NGINX_BIN}" -s reload

  echo "[OK] Uninstall completed."
  if [[ "${keep_state}" == "true" ]]; then
    echo "[INFO] State kept at: ${STATE_DIR}"
  fi
}

main "$@"
