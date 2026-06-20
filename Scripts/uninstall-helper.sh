#!/usr/bin/env bash
set -euo pipefail

LABEL="local.do-not-sleep.helper"
HELPER_DST="/Library/PrivilegedHelperTools/${LABEL}"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"
CONFIG_DST="/Library/Application Support/Do Not Sleep/helper.json"

IS_ROOT=0
if [[ "$(id -u)" -eq 0 ]]; then
  IS_ROOT=1
fi

run_privileged() {
  if [[ "$IS_ROOT" -eq 1 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

echo "Do Not Sleep privileged helper를 제거합니다."
if [[ "$IS_ROOT" -eq 1 ]]; then
  echo "관리자 권한으로 실행 중이므로 추가 sudo 인증 없이 제거합니다."
else
  echo "관리자 인증은 LaunchDaemon 제거에 한 번 필요합니다."
  sudo -v
fi

run_privileged launchctl bootout system "$PLIST_DST" 2>/dev/null || true
run_privileged rm -f "$PLIST_DST" "$HELPER_DST" "$CONFIG_DST"
run_privileged find /var/run -maxdepth 1 -name "do-not-sleep-helper-*.sock" -delete 2>/dev/null || true

echo "제거가 완료되었습니다."
