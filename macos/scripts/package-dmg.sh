#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/DesktopVoiceInputReleaseDerivedData}"
OUTPUT_DIR="$ROOT_DIR/dist/dmg"
STAGING_DIR="$(mktemp -d /tmp/gugutalk-dmg.XXXXXX)"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

cd "$ROOT_DIR"

COMMIT="$(git rev-parse --short HEAD)"
DATE_TAG="$(date +%Y%m%d-%H%M)"
DMG_PATH="$OUTPUT_DIR/GuGuTalk-${DATE_TAG}-${COMMIT}.dmg"
APP_SRC="$DERIVED_DATA_PATH/Build/Products/Release/GuGuTalk.app"

mkdir -p "$OUTPUT_DIR"

if xcodebuild -version >/dev/null 2>&1; then
    xcodebuild \
        -project DesktopVoiceInput.xcodeproj \
        -scheme DesktopVoiceInput \
        -configuration Release \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        build
else
    echo "Full Xcode is unavailable; building the app bundle with SwiftPM."
    "$ROOT_DIR/scripts/build-swiftpm-app.sh" "$APP_SRC"
fi

if [[ ! -d "$APP_SRC" ]]; then
    echo "Release app not found: $APP_SRC" >&2
    exit 1
fi

if codesign -dv --verbose=4 "$APP_SRC" 2>&1 | grep -q "Signature=adhoc"; then
    "$ROOT_DIR/scripts/sign-local-app.sh" "$APP_SRC"
fi

rm -f "$DMG_PATH" "$DMG_PATH.sha256"
/usr/bin/ditto "$APP_SRC" "$STAGING_DIR/GuGuTalk.app"
ln -s /Applications "$STAGING_DIR/Applications"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGING_DIR/GuGuTalk.app"
hdiutil create -volname "GuGuTalk" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
hdiutil verify "$DMG_PATH"
shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"

if [[ "${GUGUTALK_SKIP_POST_PACKAGE_INSTALL:-0}" == "1" ]]; then
    echo "Fresh install skipped: GUGUTALK_SKIP_POST_PACKAGE_INSTALL=1"
else
    echo "Running fresh-install hook..."
    "$ROOT_DIR/scripts/fresh-install-local.sh" "$STAGING_DIR/GuGuTalk.app"
fi

echo "DMG: $DMG_PATH"
echo "SHA256: $DMG_PATH.sha256"
