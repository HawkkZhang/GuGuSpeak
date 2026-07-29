#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:?Usage: build-swiftpm-app.sh <output/GuGuTalk.app>}"
APP_BASENAME="$(basename "$APP_PATH")"
INFO_PLIST_SOURCE="$ROOT_DIR/Config/DesktopVoiceInput-Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Sources/DesktopVoiceInput/Assets.xcassets/AppIcon.appiconset"
MENU_ICON_SOURCE="$ROOT_DIR/Sources/DesktopVoiceInput/Assets.xcassets/MenuBarIcon.imageset"
RUNTIME_DIR="$ROOT_DIR/ThirdParty/sherpa-onnx/lib"
INSTALLED_MODEL_SEED="/Applications/GuGuTalk.app/Contents/Resources/models"
ICON_WORK_DIR="$(mktemp -d /tmp/gugutalk-icon.XXXXXX)"

cleanup() {
    rm -rf "$ICON_WORK_DIR"
}
trap cleanup EXIT

if [[ "$APP_BASENAME" != "GuGuTalk.app" || "$APP_PATH" == "/Applications/GuGuTalk.app" ]]; then
    echo "Refusing unsafe SwiftPM app output path: $APP_PATH" >&2
    exit 1
fi

"$ROOT_DIR/scripts/install-sensevoice-runtime.sh"

cd "$ROOT_DIR"
swift build -c release
SWIFTPM_BIN_DIR="$(swift build -c release --show-bin-path)"
SWIFTPM_EXECUTABLE="$SWIFTPM_BIN_DIR/DesktopVoiceInput"

if [[ ! -x "$SWIFTPM_EXECUTABLE" ]]; then
    echo "SwiftPM release executable not found: $SWIFTPM_EXECUTABLE" >&2
    exit 1
fi

rm -rf "$APP_PATH"
mkdir -p \
    "$APP_PATH/Contents/MacOS" \
    "$APP_PATH/Contents/Frameworks" \
    "$APP_PATH/Contents/Resources/models"

/usr/bin/ditto "$SWIFTPM_EXECUTABLE" "$APP_PATH/Contents/MacOS/GuGuTalk"
/bin/chmod +x "$APP_PATH/Contents/MacOS/GuGuTalk"
/usr/bin/ditto "$RUNTIME_DIR/libsherpa-onnx-c-api.dylib" "$APP_PATH/Contents/Frameworks/libsherpa-onnx-c-api.dylib"
/usr/bin/ditto "$RUNTIME_DIR/libonnxruntime.1.24.4.dylib" "$APP_PATH/Contents/Frameworks/libonnxruntime.1.24.4.dylib"

/usr/bin/ditto "$INFO_PLIST_SOURCE" "$APP_PATH/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleDevelopmentRegion -string "en" "$APP_PATH/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleExecutable -string "GuGuTalk" "$APP_PATH/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIconFile -string "GuGuTalk.icns" "$APP_PATH/Contents/Info.plist"
/usr/bin/plutil -remove CFBundleIconName "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
/usr/bin/plutil -replace CFBundleIdentifier -string "com.end.DesktopVoiceInput" "$APP_PATH/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "0.1.0" "$APP_PATH/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "1" "$APP_PATH/Contents/Info.plist"
/usr/bin/plutil -replace LSMinimumSystemVersion -string "15.5" "$APP_PATH/Contents/Info.plist"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"

/usr/bin/ditto "$MENU_ICON_SOURCE/menubar_icon.png" "$APP_PATH/Contents/Resources/MenuBarIcon.png"
/usr/bin/ditto "$MENU_ICON_SOURCE/menubar_icon@2x.png" "$APP_PATH/Contents/Resources/MenuBarIcon@2x.png"

ICONSET_PATH="$ICON_WORK_DIR/GuGuTalk.iconset"
mkdir -p "$ICONSET_PATH"
/usr/bin/ditto "$APP_ICON_SOURCE/icon_16.png" "$ICONSET_PATH/icon_16x16.png"
/usr/bin/ditto "$APP_ICON_SOURCE/icon_32.png" "$ICONSET_PATH/icon_16x16@2x.png"
/usr/bin/ditto "$APP_ICON_SOURCE/icon_32.png" "$ICONSET_PATH/icon_32x32.png"
/usr/bin/ditto "$APP_ICON_SOURCE/icon_64.png" "$ICONSET_PATH/icon_32x32@2x.png"
/usr/bin/ditto "$APP_ICON_SOURCE/icon_128.png" "$ICONSET_PATH/icon_128x128.png"
/usr/bin/ditto "$APP_ICON_SOURCE/icon_256.png" "$ICONSET_PATH/icon_128x128@2x.png"
/usr/bin/ditto "$APP_ICON_SOURCE/icon_256.png" "$ICONSET_PATH/icon_256x256.png"
/usr/bin/ditto "$APP_ICON_SOURCE/icon_512.png" "$ICONSET_PATH/icon_256x256@2x.png"
/usr/bin/ditto "$APP_ICON_SOURCE/icon_512.png" "$ICONSET_PATH/icon_512x512.png"
/usr/bin/ditto "$APP_ICON_SOURCE/app_icon_1024.png" "$ICONSET_PATH/icon_512x512@2x.png"
/usr/bin/iconutil -c icns "$ICONSET_PATH" -o "$APP_PATH/Contents/Resources/GuGuTalk.icns"

if [[ -d "$INSTALLED_MODEL_SEED" ]]; then
    /usr/bin/ditto "$INSTALLED_MODEL_SEED" "$APP_PATH/Contents/Resources/models"
fi
"$ROOT_DIR/scripts/install-local-asr-models.sh" "$APP_PATH/Contents/Resources/models"

/usr/bin/printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"
"$ROOT_DIR/scripts/sign-local-app.sh" "$APP_PATH"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "SwiftPM app: $APP_PATH"
