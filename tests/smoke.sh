#!/usr/bin/env bash
set -euo pipefail

WINDOWCTL_BIN="${WINDOWCTL_BIN:-/usr/local/sbin/openclaw-windowctl}"
BASE_URL="${BASE_URL:-https://<DOMAIN_PLACEHOLDER>}"
BASIC_USER="${BASIC_USER:-<BASIC_USER_PLACEHOLDER>}"
BASIC_PASS="${BASIC_PASS:-<BASIC_PASS_PLACEHOLDER>}"
CURL_BIN="${CURL_BIN:-curl}"

fail() {
  echo "[FAIL] $1" >&2
  exit 1
}

http_code() {
  local url="$1"
  shift
  "${CURL_BIN}" -k -sS -o /dev/null -w '%{http_code}' "$@" "${url}"
}

echo "[STEP] close window"
sudo "${WINDOWCTL_BIN}" close >/dev/null

state="$(sudo "${WINDOWCTL_BIN}" status | sed -n 's/^STATE=//p')"
[[ "${state}" == "CLOSED" ]] || fail "Initial state is not CLOSED"

echo "[STEP] closed endpoint should be blocked"
code_closed="$(http_code "${BASE_URL}/openclaw/")"
[[ "${code_closed}" == "403" || "${code_closed}" == "401" ]] || fail "Expected 403/401 while closed, got ${code_closed}"

echo "[STEP] open for 1 minute"
sudo "${WINDOWCTL_BIN}" open --minutes 1 >/dev/null

state_open="$(sudo "${WINDOWCTL_BIN}" status | sed -n 's/^STATE=//p')"
[[ "${state_open}" == "OPEN" ]] || fail "State is not OPEN after open"

auto_close_line="$(sudo "${WINDOWCTL_BIN}" status | sed -n 's/^AUTO_CLOSE=//p')"
[[ "${auto_close_line}" != "NONE" ]] || fail "AUTO_CLOSE task missing"

echo "[STEP] open endpoint without basic auth should challenge"
code_no_auth="$(http_code "${BASE_URL}/openclaw/")"
[[ "${code_no_auth}" == "401" ]] || fail "Expected 401 without BasicAuth, got ${code_no_auth}"

echo "[STEP] with basic auth should reach upstream (not 401/403 from nginx gate)"
code_with_auth="$(http_code "${BASE_URL}/openclaw/" -u "${BASIC_USER}:${BASIC_PASS}")"
[[ "${code_with_auth}" != "401" && "${code_with_auth}" != "403" ]] || fail "Expected upstream reachable, got ${code_with_auth}"

echo "[STEP] minutes > 60 must fail"
if sudo "${WINDOWCTL_BIN}" open --minutes 61 >/dev/null 2>&1; then
  fail "open --minutes 61 should fail"
fi

echo "[STEP] wait for auto close (65s)"
sleep 65
state_final="$(sudo "${WINDOWCTL_BIN}" status | sed -n 's/^STATE=//p')"
[[ "${state_final}" == "CLOSED" ]] || fail "State did not auto-close"

echo "[PASS] smoke checks passed"
