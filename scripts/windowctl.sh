#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${STATE_DIR:-/etc/nginx/openclaw}"
WINDOW_CONF="${WINDOW_CONF:-${STATE_DIR}/window.conf}"
WINDOW_OPEN_CONF="${WINDOW_OPEN_CONF:-${STATE_DIR}/window.conf.open}"
WINDOW_CLOSED_CONF="${WINDOW_CLOSED_CONF:-${STATE_DIR}/window.conf.closed}"
META_FILE="${META_FILE:-${STATE_DIR}/auto-close.meta}"
LOCK_FILE="${LOCK_FILE:-${STATE_DIR}/windowctl.lock}"
NGINX_BIN="${NGINX_BIN:-nginx}"
SYSTEMD_UNIT_PREFIX="${SYSTEMD_UNIT_PREFIX:-openclaw-window-close}"
NOHUP_LOG="${NOHUP_LOG:-${STATE_DIR}/nohup-close.log}"

if [[ -x "/usr/local/sbin/openclaw-windowctl" ]]; then
  SCRIPT_PATH="/usr/local/sbin/openclaw-windowctl"
else
  SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/windowctl.sh"
fi

usage() {
  cat <<USAGE
Usage:
  $0 open [--minutes <1-60>]
  $0 close
  $0 status
USAGE
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] Run as root." >&2
    exit 1
  fi
}

require_files() {
  for f in "${WINDOW_OPEN_CONF}" "${WINDOW_CLOSED_CONF}"; do
    if [[ ! -f "${f}" ]]; then
      echo "[ERROR] Missing file: ${f}" >&2
      exit 1
    fi
  done

  if [[ ! -f "${WINDOW_CONF}" ]]; then
    install -m 640 "${WINDOW_CLOSED_CONF}" "${WINDOW_CONF}"
  fi
}

acquire_lock() {
  mkdir -p "${STATE_DIR}"
  exec 9>"${LOCK_FILE}"
  if ! flock -w 20 9; then
    echo "[ERROR] Another windowctl process is running." >&2
    exit 1
  fi
}

audit_log() {
  local action="$1"
  local details="$2"
  local actor="${SUDO_USER:-$(id -un)}"

  if command -v logger >/dev/null 2>&1; then
    logger -t openclaw-windowctl "action=${action} actor=${actor} details=${details} at=$(date -Is)"
  fi
}

nginx_test_and_reload() {
  "${NGINX_BIN}" -t
  "${NGINX_BIN}" -s reload
}

current_state() {
  if [[ -f "${WINDOW_CONF}" ]] && cmp -s "${WINDOW_CONF}" "${WINDOW_OPEN_CONF}"; then
    echo "OPEN"
  else
    echo "CLOSED"
  fi
}

load_meta() {
  META_SCHEDULER=""
  META_UNIT=""
  META_PID=""
  META_DUE_EPOCH=""

  if [[ ! -f "${META_FILE}" ]]; then
    return
  fi

  while IFS='=' read -r key value; do
    case "${key}" in
      scheduler) META_SCHEDULER="${value}" ;;
      unit) META_UNIT="${value}" ;;
      pid) META_PID="${value}" ;;
      due_epoch) META_DUE_EPOCH="${value}" ;;
    esac
  done < "${META_FILE}"
}

save_meta() {
  local scheduler="$1"
  local unit="$2"
  local pid="$3"
  local due_epoch="$4"

  cat > "${META_FILE}" <<META
scheduler=${scheduler}
unit=${unit}
pid=${pid}
due_epoch=${due_epoch}
META
}

clear_meta() {
  rm -f "${META_FILE}"
}

cancel_pending_close() {
  load_meta

  if [[ -z "${META_SCHEDULER}" ]]; then
    return
  fi

  if [[ "${META_SCHEDULER}" == "systemd" && -n "${META_UNIT}" ]]; then
    if command -v systemctl >/dev/null 2>&1; then
      systemctl stop "${META_UNIT}.timer" "${META_UNIT}.service" >/dev/null 2>&1 || true
      systemctl reset-failed "${META_UNIT}.service" >/dev/null 2>&1 || true
    fi
  fi

  if [[ "${META_SCHEDULER}" == "nohup" && -n "${META_PID}" ]]; then
    kill "${META_PID}" >/dev/null 2>&1 || true
  fi

  clear_meta
}

schedule_close_systemd() {
  local minutes="$1"
  local seconds=$((minutes * 60))
  local due_epoch=$(( $(date +%s) + seconds ))
  local unit="${SYSTEMD_UNIT_PREFIX}-$(date +%s)-$$"

  systemd-run --quiet \
    --unit "${unit}" \
    --on-active "${minutes}m" \
    /usr/bin/env \
      STATE_DIR="${STATE_DIR}" \
      WINDOW_CONF="${WINDOW_CONF}" \
      WINDOW_OPEN_CONF="${WINDOW_OPEN_CONF}" \
      WINDOW_CLOSED_CONF="${WINDOW_CLOSED_CONF}" \
      META_FILE="${META_FILE}" \
      LOCK_FILE="${LOCK_FILE}" \
      NGINX_BIN="${NGINX_BIN}" \
      SYSTEMD_UNIT_PREFIX="${SYSTEMD_UNIT_PREFIX}" \
      NOHUP_LOG="${NOHUP_LOG}" \
      "${SCRIPT_PATH}" close

  save_meta "systemd" "${unit}" "" "${due_epoch}"
}

schedule_close_nohup() {
  local minutes="$1"
  local seconds=$((minutes * 60))
  local due_epoch=$(( $(date +%s) + seconds ))

  nohup /bin/bash -c "sleep ${seconds}; /usr/bin/env STATE_DIR='${STATE_DIR}' WINDOW_CONF='${WINDOW_CONF}' WINDOW_OPEN_CONF='${WINDOW_OPEN_CONF}' WINDOW_CLOSED_CONF='${WINDOW_CLOSED_CONF}' META_FILE='${META_FILE}' LOCK_FILE='${LOCK_FILE}' NGINX_BIN='${NGINX_BIN}' SYSTEMD_UNIT_PREFIX='${SYSTEMD_UNIT_PREFIX}' NOHUP_LOG='${NOHUP_LOG}' '${SCRIPT_PATH}' close >>'${NOHUP_LOG}' 2>&1" >/dev/null 2>&1 &
  local pid=$!

  save_meta "nohup" "" "${pid}" "${due_epoch}"
}

schedule_close() {
  local minutes="$1"

  cancel_pending_close

  if command -v systemd-run >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
    if schedule_close_systemd "${minutes}"; then
      return
    fi
  fi

  schedule_close_nohup "${minutes}"
}

apply_window_conf() {
  local src="$1"
  local backup

  backup="$(mktemp "${STATE_DIR}/window.conf.backup.XXXXXX")"
  cp "${WINDOW_CONF}" "${backup}" 2>/dev/null || cp "${WINDOW_CLOSED_CONF}" "${backup}"

  cp "${src}" "${WINDOW_CONF}"

  if ! "${NGINX_BIN}" -t; then
    cp "${backup}" "${WINDOW_CONF}"
    rm -f "${backup}"
    "${NGINX_BIN}" -t
    "${NGINX_BIN}" -s reload
    echo "[ERROR] Nginx validation failed after update; rolled back." >&2
    exit 1
  fi

  "${NGINX_BIN}" -s reload
  rm -f "${backup}"
}

validate_minutes() {
  local minutes="$1"
  if [[ ! "${minutes}" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] --minutes must be an integer between 1 and 60." >&2
    exit 1
  fi
  if (( minutes < 1 || minutes > 60 )); then
    echo "[ERROR] --minutes must be in range 1..60." >&2
    exit 1
  fi
}

cmd_open() {
  local minutes="$1"
  local before_state
  local after_state

  validate_minutes "${minutes}"
  require_files

  before_state="$(current_state)"

  nginx_test_and_reload
  apply_window_conf "${WINDOW_OPEN_CONF}"
  schedule_close "${minutes}"
  nginx_test_and_reload

  after_state="$(current_state)"
  audit_log "open" "minutes=${minutes} before=${before_state} after=${after_state}"

  echo "STATE=${after_state}"
  echo "AUTO_CLOSE=IN ${minutes}m"
}

cmd_close() {
  local before_state
  local after_state

  require_files
  before_state="$(current_state)"

  nginx_test_and_reload
  apply_window_conf "${WINDOW_CLOSED_CONF}"
  cancel_pending_close
  nginx_test_and_reload

  after_state="$(current_state)"
  audit_log "close" "before=${before_state} after=${after_state}"

  echo "STATE=${after_state}"
  echo "AUTO_CLOSE=NONE"
}

cmd_status() {
  local state
  state="$(current_state)"
  echo "STATE=${state}"

  load_meta
  if [[ -z "${META_SCHEDULER}" ]]; then
    echo "AUTO_CLOSE=NONE"
    return
  fi

  if [[ "${META_SCHEDULER}" == "systemd" ]]; then
    local active="unknown"
    local next_run="unknown"
    if command -v systemctl >/dev/null 2>&1 && [[ -n "${META_UNIT}" ]]; then
      active="$(systemctl show "${META_UNIT}.timer" -p ActiveState --value 2>/dev/null || echo "unknown")"
      next_run="$(systemctl show "${META_UNIT}.timer" -p NextElapseUSecRealtime --value 2>/dev/null || echo "unknown")"
    fi
    echo "AUTO_CLOSE=SYSTEMD unit=${META_UNIT}.timer active=${active} next=${next_run} due_epoch=${META_DUE_EPOCH:-unknown}"
    return
  fi

  if [[ "${META_SCHEDULER}" == "nohup" ]]; then
    local alive="no"
    if [[ -n "${META_PID}" ]] && kill -0 "${META_PID}" >/dev/null 2>&1; then
      alive="yes"
    fi
    echo "AUTO_CLOSE=NOHUP pid=${META_PID:-unknown} alive=${alive} due_epoch=${META_DUE_EPOCH:-unknown}"
    return
  fi

  echo "AUTO_CLOSE=UNKNOWN"
}

main() {
  require_root
  acquire_lock

  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  local cmd="$1"
  shift

  case "${cmd}" in
    open)
      local minutes=60
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --minutes)
            minutes="${2:-}"
            shift 2
            ;;
          *)
            echo "[ERROR] Unknown argument: $1" >&2
            usage
            exit 1
            ;;
        esac
      done
      cmd_open "${minutes}"
      ;;
    close)
      if [[ $# -ne 0 ]]; then
        echo "[ERROR] close does not take arguments." >&2
        usage
        exit 1
      fi
      cmd_close
      ;;
    status)
      if [[ $# -ne 0 ]]; then
        echo "[ERROR] status does not take arguments." >&2
        usage
        exit 1
      fi
      require_files
      cmd_status
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "[ERROR] Unknown command: ${cmd}" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
