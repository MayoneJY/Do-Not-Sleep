#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="local.do-not-sleep.helper"
HELPER_DST="/Library/PrivilegedHelperTools/${LABEL}"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"
CONFIG_DIR="/Library/Application Support/Do Not Sleep"
CONFIG_DST="${CONFIG_DIR}/helper.json"

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

if [[ "$SCRIPT_DIR" == */Contents/Resources/Scripts ]]; then
  CONTENTS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
  HELPER_SRC="$CONTENTS_DIR/MacOS/DoNotSleep"
  echo "앱 번들의 Do Not Sleep 실행 파일을 helper로 설치합니다."
else
  ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  HELPER_SRC="$ROOT_DIR/.build/release/do-not-sleep"
  echo "Do Not Sleep release 실행 파일을 빌드합니다."
  swift build -c release --package-path "$ROOT_DIR"
fi

if [[ ! -x "$HELPER_SRC" ]]; then
  echo "오류: 빌드된 helper 실행 파일을 찾을 수 없습니다: $HELPER_SRC" >&2
  exit 1
fi

INSTALL_UID="${DO_NOT_SLEEP_INSTALL_UID:-${SUDO_UID:-$(id -u)}}"
if [[ ! "$INSTALL_UID" =~ ^[0-9]+$ ]]; then
  echo "오류: DO_NOT_SLEEP_INSTALL_UID 값이 올바르지 않습니다: $INSTALL_UID" >&2
  exit 1
fi
INSTALL_USER="$(id -un "$INSTALL_UID")"
INSTALL_GID="$(id -g "$INSTALL_USER")"
SOCKET_PATH="/var/run/do-not-sleep-helper-${INSTALL_UID}.sock"

echo "Do Not Sleep privileged helper를 설치합니다."
echo "- 설치 사용자: ${INSTALL_USER} (uid ${INSTALL_UID}, gid ${INSTALL_GID})"
echo "- 소켓 경로: ${SOCKET_PATH}"
if [[ "$IS_ROOT" -eq 1 ]]; then
  echo "관리자 권한으로 실행 중이므로 추가 sudo 인증 없이 설치합니다."
else
  echo "관리자 인증은 LaunchDaemon 설치에 한 번 필요합니다."
  sudo -v
fi

plist_tmp="$(mktemp)"
config_tmp="$(mktemp)"
cleanup() {
  rm -f "$plist_tmp" "$config_tmp"
}
trap cleanup EXIT

cat > "$config_tmp" <<JSON
{
  "allowed_uid": ${INSTALL_UID},
  "allowed_gid": ${INSTALL_GID},
  "socket_path": "${SOCKET_PATH}"
}
JSON

cat > "$plist_tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
    <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${HELPER_DST}</string>
    <string>helper</string>
    <string>--config</string>
    <string>${CONFIG_DST}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/Library/Logs/DoNotSleepHelper.log</string>
  <key>StandardErrorPath</key>
  <string>/Library/Logs/DoNotSleepHelper.log</string>
</dict>
</plist>
PLIST

plutil -lint "$plist_tmp" >/dev/null
"$HELPER_SRC" helper --help >/dev/null

run_privileged launchctl bootout system "$PLIST_DST" 2>/dev/null || true
run_privileged rm -f "$SOCKET_PATH"
run_privileged mkdir -p "/Library/PrivilegedHelperTools" "$CONFIG_DIR"
run_privileged install -m 0755 -o root -g wheel "$HELPER_SRC" "$HELPER_DST"
run_privileged install -m 0644 -o root -g wheel "$config_tmp" "$CONFIG_DST"
run_privileged install -m 0644 -o root -g wheel "$plist_tmp" "$PLIST_DST"
run_privileged launchctl bootstrap system "$PLIST_DST"
run_privileged launchctl enable "system/${LABEL}" 2>/dev/null || true
run_privileged launchctl kickstart -k "system/${LABEL}"

echo "설치가 완료되었습니다."
echo "상태 확인: swift run do-not-sleep status"
