#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DOMAIN=""
SSL_CERT=""
SSL_KEY=""
BASIC_USER=""
BASIC_PASS="${BASIC_PASS:-}"

NGINX_CONF_DIR="/etc/nginx/conf.d"
NGINX_CONF_NAME="openclaw-dashboard.conf"
STATE_DIR="/etc/nginx/openclaw"
BASIC_AUTH_FILE="${STATE_DIR}/.htpasswd"
WINDOWCTL_INSTALL_PATH="/usr/local/sbin/openclaw-windowctl"
NGINX_BIN="${NGINX_BIN:-nginx}"

usage() {
  cat <<USAGE
Usage:
  $0 --domain <domain> --cert <cert_path> --key <key_path> --basic-user <user>

Optional env:
  BASIC_PASS=<password>   # if not set, script prompts securely
  NGINX_BIN=<nginx_bin>   # default: nginx
USAGE
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] Run as root." >&2
    exit 1
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "[ERROR] Missing command: ${cmd}" >&2
    exit 1
  fi
}

escape_sed() {
  printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        DOMAIN="${2:-}"
        shift 2
        ;;
      --cert)
        SSL_CERT="${2:-}"
        shift 2
        ;;
      --key)
        SSL_KEY="${2:-}"
        shift 2
        ;;
      --basic-user)
        BASIC_USER="${2:-}"
        shift 2
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

  if [[ -z "${DOMAIN}" || -z "${SSL_CERT}" || -z "${SSL_KEY}" || -z "${BASIC_USER}" ]]; then
    echo "[ERROR] Missing required arguments." >&2
    usage
    exit 1
  fi
}

render_nginx_conf() {
  local tpl="${REPO_ROOT}/templates/nginx-openclaw.conf.tpl"
  local out="${NGINX_CONF_DIR}/${NGINX_CONF_NAME}"

  if [[ ! -f "${tpl}" ]]; then
    echo "[ERROR] Template not found: ${tpl}" >&2
    exit 1
  fi

  sed \
    -e "s|__DOMAIN__|$(escape_sed "${DOMAIN}")|g" \
    -e "s|__SSL_CERT_PATH__|$(escape_sed "${SSL_CERT}")|g" \
    -e "s|__SSL_KEY_PATH__|$(escape_sed "${SSL_KEY}")|g" \
    -e "s|__BASIC_AUTH_FILE__|$(escape_sed "${BASIC_AUTH_FILE}")|g" \
    -e "s|__WINDOW_CONF_PATH__|$(escape_sed "${STATE_DIR}/window.conf")|g" \
    "${tpl}" > "${out}"
}

setup_basic_auth() {
  mkdir -p "${STATE_DIR}"

  if [[ -z "${BASIC_PASS}" ]]; then
    read -r -s -p "Enter BasicAuth password for ${BASIC_USER}: " BASIC_PASS
    echo
  fi

  if [[ -z "${BASIC_PASS}" ]]; then
    echo "[ERROR] Empty password is not allowed." >&2
    exit 1
  fi

  local hash
  hash="$(openssl passwd -apr1 "${BASIC_PASS}")"
  umask 027
  printf '%s:%s\n' "${BASIC_USER}" "${hash}" > "${BASIC_AUTH_FILE}"

  # Let nginx worker read htpasswd while keeping it non-world-readable when possible.
  if getent group nginx >/dev/null 2>&1; then
    chown root:nginx "${BASIC_AUTH_FILE}"
    chmod 640 "${BASIC_AUTH_FILE}"
  elif getent group www-data >/dev/null 2>&1; then
    chown root:www-data "${BASIC_AUTH_FILE}"
    chmod 640 "${BASIC_AUTH_FILE}"
  else
    chown root:root "${BASIC_AUTH_FILE}"
    chmod 644 "${BASIC_AUTH_FILE}"
  fi
}

install_window_files() {
  install -m 640 "${REPO_ROOT}/templates/window.conf.open" "${STATE_DIR}/window.conf.open"
  install -m 640 "${REPO_ROOT}/templates/window.conf.closed" "${STATE_DIR}/window.conf.closed"
  install -m 640 "${REPO_ROOT}/templates/window.conf.closed" "${STATE_DIR}/window.conf"
}

install_windowctl() {
  install -m 750 "${REPO_ROOT}/scripts/windowctl.sh" "${WINDOWCTL_INSTALL_PATH}"
}

test_and_reload() {
  "${NGINX_BIN}" -t
  "${NGINX_BIN}" -s reload
}

main() {
  require_root
  require_cmd sed
  require_cmd openssl
  require_cmd install

  parse_args "$@"

  mkdir -p "${NGINX_CONF_DIR}" "${STATE_DIR}"

  setup_basic_auth
  install_window_files
  render_nginx_conf
  install_windowctl
  test_and_reload

  echo "[OK] Bootstrap completed."
  echo "[INFO] Nginx conf: ${NGINX_CONF_DIR}/${NGINX_CONF_NAME}"
  echo "[INFO] Window state dir: ${STATE_DIR}"
  echo "[INFO] Controller: ${WINDOWCTL_INSTALL_PATH}"
  echo "[INFO] Current state: CLOSED"
}

main "$@"
