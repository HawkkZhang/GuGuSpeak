#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:?Usage: sign-local-app.sh <GuGuTalk.app>}"
FRAMEWORKS_DIR="${APP_PATH}/Contents/Frameworks"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "App bundle not found: ${APP_PATH}" >&2
  exit 1
fi

for library in \
  "${FRAMEWORKS_DIR}/libsherpa-onnx-c-api.dylib" \
  "${FRAMEWORKS_DIR}/libonnxruntime.1.24.4.dylib"; do
  if [[ ! -f "${library}" ]]; then
    echo "Bundled runtime not found: ${library}" >&2
    exit 1
  fi
  codesign --force --sign - --timestamp=none "${library}"
done

# A stable explicit requirement lets macOS TCC keep local permissions across
# rebuilds. Hardened Runtime is intentionally omitted: separately ad-hoc-signed
# binaries have no shared Team ID and would fail Library Validation at launch.
codesign \
  --force \
  --sign - \
  --timestamp=none \
  --identifier com.end.DesktopVoiceInput \
  --requirements "${ROOT_DIR}/Config/GuGuTalkLocal.requirements" \
  --entitlements "${ROOT_DIR}/Config/DesktopVoiceInput.entitlements" \
  "${APP_PATH}"

codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
