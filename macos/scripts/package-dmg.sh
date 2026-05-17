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

xcodebuild \
    -project DesktopVoiceInput.xcodeproj \
    -scheme DesktopVoiceInput \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build

if [[ ! -d "$APP_SRC" ]]; then
    echo "Release app not found: $APP_SRC" >&2
    exit 1
fi

rm -f "$DMG_PATH" "$DMG_PATH.sha256"
/usr/bin/ditto "$APP_SRC" "$STAGING_DIR/GuGuTalk.app"
ln -s /Applications "$STAGING_DIR/Applications"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGING_DIR/GuGuTalk.app"
hdiutil create -volname "GuGuTalk" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
hdiutil verify "$DMG_PATH"
shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"

echo "DMG: $DMG_PATH"
echo "SHA256: $DMG_PATH.sha256"
