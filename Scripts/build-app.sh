#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Do Not Sleep"
APP_DIR="$ROOT_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
RESOURCE_SCRIPTS_DIR="$RESOURCES_DIR/Scripts"
MENU_BAR_ASSETS_DIR="$RESOURCES_DIR/MenuBar"
EXECUTABLE_NAME="DoNotSleep"
APP_ICON="$ROOT_DIR/Assets/AppIcon/DoNotSleep.icns"

cd "$ROOT_DIR"
swift build -c release
RELEASE_BUILD_DIR="$(cd "$ROOT_DIR/.build/release" && pwd -P)"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCE_SCRIPTS_DIR" "$MENU_BAR_ASSETS_DIR"
cp "$RELEASE_BUILD_DIR/do-not-sleep" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

SWIFTPM_RESOURCE_BUNDLES=()
while IFS= read -r resource_bundle; do
  SWIFTPM_RESOURCE_BUNDLES+=("$resource_bundle")
done < <(
  find "$RELEASE_BUILD_DIR" -maxdepth 1 -type d \( -name '*.resources' -o -name '*.bundle' \) \
    \( -name '*do-not-sleep*' -o -name '*do_not_sleep*' \) | sort
)
if [ "${#SWIFTPM_RESOURCE_BUNDLES[@]}" -eq 0 ]; then
  echo "오류: SwiftPM 리소스 번들을 찾을 수 없습니다." >&2
  exit 1
fi
for resource_bundle in "${SWIFTPM_RESOURCE_BUNDLES[@]}"; do
  while IFS= read -r lproj_dir; do
    lproj_name="$(basename "$lproj_dir")"
    rm -rf "$RESOURCES_DIR/$lproj_name"
    cp -R "$lproj_dir" "$RESOURCES_DIR/"
  done < <(find "$resource_bundle" -maxdepth 1 -type d -name '*.lproj' | sort)
done

cp "$ROOT_DIR/Scripts/install-helper.sh" "$RESOURCE_SCRIPTS_DIR/install-helper.sh"
cp "$ROOT_DIR/Scripts/uninstall-helper.sh" "$RESOURCE_SCRIPTS_DIR/uninstall-helper.sh"
chmod +x "$RESOURCE_SCRIPTS_DIR/install-helper.sh" "$RESOURCE_SCRIPTS_DIR/uninstall-helper.sh"

if [ ! -e "$APP_ICON" ]; then
  echo "오류: 앱 아이콘을 찾을 수 없습니다: $APP_ICON" >&2
  exit 1
fi
cp "$APP_ICON" "$RESOURCES_DIR/DoNotSleep.icns"

MENU_BAR_ASSETS=(
  "$ROOT_DIR/Assets/MenuBar/DoNotSleepGlyph.png"
  "$ROOT_DIR/Assets/MenuBar/DoNotSleepGlyph@2x.png"
)
for asset in "${MENU_BAR_ASSETS[@]}"; do
  if [ ! -e "$asset" ]; then
    echo "오류: 메뉴 막대 글리프 에셋을 찾을 수 없습니다: $asset" >&2
    exit 1
  fi
done
cp "${MENU_BAR_ASSETS[@]}" "$MENU_BAR_ASSETS_DIR/"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>ko</string>
  <key>CFBundleDisplayName</key>
  <string>Do Not Sleep</string>
  <key>CFBundleExecutable</key>
  <string>DoNotSleep</string>
  <key>CFBundleIdentifier</key>
  <string>com.mayonedev.do-not-sleep</string>
  <key>CFBundleIconFile</key>
  <string>DoNotSleep</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Do Not Sleep</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "앱 번들을 만들었습니다: $APP_DIR"
echo "실행: open \"$APP_DIR\""
