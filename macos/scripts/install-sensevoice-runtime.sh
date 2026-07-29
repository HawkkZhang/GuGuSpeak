#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_VERSION="v1.13.2"
VERSION="${GUGUTALK_SHERPA_ONNX_VERSION:-${DEFAULT_VERSION}}"
FRAMEWORK_ARCHIVE="sherpa-onnx-${VERSION}-macos-xcframework-static.tar.bz2"
FRAMEWORK_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${VERSION}/${FRAMEWORK_ARCHIVE}"
FRAMEWORK_SHA256="${GUGUTALK_SHERPA_FRAMEWORK_SHA256:-}"
LIB_ARCHIVE="sherpa-onnx-${VERSION}-osx-universal2-shared-no-tts-lib.tar.bz2"
LIB_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${VERSION}/${LIB_ARCHIVE}"
LIB_SHA256="${GUGUTALK_SHERPA_LIB_SHA256:-}"
if [[ "${VERSION}" == "${DEFAULT_VERSION}" ]]; then
  FRAMEWORK_SHA256="${FRAMEWORK_SHA256:-8756afb64ef7a1d612040c323e6f2cf707f90e703395413c79c572e37eddd65e}"
  LIB_SHA256="${LIB_SHA256:-117150cf014ed913b1f5aee75eccfafa7957919b6efe8b9a3974bbcb5f7d6020}"
fi
INSTALL_DIR="${ROOT_DIR}/ThirdParty/sherpa-onnx"
FRAMEWORK_DIR="${INSTALL_DIR}/sherpa-onnx.xcframework"
LIB_DIR="${INSTALL_DIR}/lib"
CACHE_DIR="${ROOT_DIR}/.modelcache"
ONNX_RUNTIME_HEADER_DIR="${ROOT_DIR}/ThirdParty/onnxruntime/include"
ONNX_RUNTIME_HEADER="${ONNX_RUNTIME_HEADER_DIR}/onnxruntime_c_api.h"
ONNX_RUNTIME_HEADER_URL="https://cdn.jsdelivr.net/gh/microsoft/onnxruntime@v1.24.4/include/onnxruntime/core/session/onnxruntime_c_api.h"
ONNX_RUNTIME_HEADER_SHA256="9ed0d7054a4e74249467365b25b415d36f51a44a6349e2a994a1812e4723d1e2"
ONNX_RUNTIME_EP_HEADER="${ONNX_RUNTIME_HEADER_DIR}/onnxruntime_ep_c_api.h"
ONNX_RUNTIME_EP_HEADER_URL="https://cdn.jsdelivr.net/gh/microsoft/onnxruntime@v1.24.4/include/onnxruntime/core/session/onnxruntime_ep_c_api.h"
ONNX_RUNTIME_EP_HEADER_SHA256="e94ac3490697bdb107844fa9d403952ee7136134132a057eae5c1207b57ce352"

verify_sha256() {
  local path="$1"
  local expected="$2"
  if [[ -z "${expected}" ]]; then
    return 0
  fi

  local actual
  actual="$(shasum -a 256 "${path}" | awk '{print $1}')"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "Checksum mismatch for ${path}: expected ${expected}, got ${actual}" >&2
    return 1
  fi
}

mkdir -p "${INSTALL_DIR}" "${LIB_DIR}" "${CACHE_DIR}" "${ONNX_RUNTIME_HEADER_DIR}"

if [[ -d "${FRAMEWORK_DIR}" && -f "${LIB_DIR}/libsherpa-onnx-c-api.dylib" && -f "${LIB_DIR}/libonnxruntime.1.24.4.dylib" \
   && -f "${ONNX_RUNTIME_HEADER}" && -f "${ONNX_RUNTIME_EP_HEADER}" ]] \
   && verify_sha256 "${ONNX_RUNTIME_HEADER}" "${ONNX_RUNTIME_HEADER_SHA256}" \
   && verify_sha256 "${ONNX_RUNTIME_EP_HEADER}" "${ONNX_RUNTIME_EP_HEADER_SHA256}"; then
  exit 0
fi

if [[ ! -f "${ONNX_RUNTIME_EP_HEADER}" ]] \
   || ! verify_sha256 "${ONNX_RUNTIME_EP_HEADER}" "${ONNX_RUNTIME_EP_HEADER_SHA256}"; then
  echo "==> Downloading ONNX Runtime execution-provider C API header"
  curl -L --fail --retry 3 --connect-timeout 20 --max-time 180 \
    -o "${ONNX_RUNTIME_EP_HEADER}.partial" "${ONNX_RUNTIME_EP_HEADER_URL}"
  verify_sha256 "${ONNX_RUNTIME_EP_HEADER}.partial" "${ONNX_RUNTIME_EP_HEADER_SHA256}"
  mv -f "${ONNX_RUNTIME_EP_HEADER}.partial" "${ONNX_RUNTIME_EP_HEADER}"
fi

if [[ ! -f "${ONNX_RUNTIME_HEADER}" ]] \
   || ! verify_sha256 "${ONNX_RUNTIME_HEADER}" "${ONNX_RUNTIME_HEADER_SHA256}"; then
  echo "==> Downloading ONNX Runtime C API header"
  curl -L --fail --retry 3 --connect-timeout 20 --max-time 180 \
    -o "${ONNX_RUNTIME_HEADER}.partial" "${ONNX_RUNTIME_HEADER_URL}"
  verify_sha256 "${ONNX_RUNTIME_HEADER}.partial" "${ONNX_RUNTIME_HEADER_SHA256}"
  mv -f "${ONNX_RUNTIME_HEADER}.partial" "${ONNX_RUNTIME_HEADER}"
fi

FRAMEWORK_ARCHIVE_PATH="${CACHE_DIR}/${FRAMEWORK_ARCHIVE}"
if [[ ! -f "${FRAMEWORK_ARCHIVE_PATH}" ]]; then
  echo "==> Downloading sherpa-onnx macOS xcframework ${VERSION}"
  curl -L --fail -o "${FRAMEWORK_ARCHIVE_PATH}.partial" "${FRAMEWORK_URL}"
  mv "${FRAMEWORK_ARCHIVE_PATH}.partial" "${FRAMEWORK_ARCHIVE_PATH}"
fi
verify_sha256 "${FRAMEWORK_ARCHIVE_PATH}" "${FRAMEWORK_SHA256}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

if [[ ! -d "${FRAMEWORK_DIR}" ]]; then
  tar -xjf "${FRAMEWORK_ARCHIVE_PATH}" -C "${TMP_DIR}"
  FOUND_FRAMEWORK="$(find "${TMP_DIR}" -name sherpa-onnx.xcframework -type d | head -n 1)"
  if [[ -z "${FOUND_FRAMEWORK}" ]]; then
    echo "sherpa-onnx.xcframework not found in ${FRAMEWORK_ARCHIVE_PATH}" >&2
    exit 1
  fi

  rm -rf "${FRAMEWORK_DIR}"
  cp -R "${FOUND_FRAMEWORK}" "${FRAMEWORK_DIR}"
fi

LIB_ARCHIVE_PATH="${CACHE_DIR}/${LIB_ARCHIVE}"
if [[ ! -f "${LIB_ARCHIVE_PATH}" ]]; then
  echo "==> Downloading sherpa-onnx macOS shared libraries ${VERSION}"
  curl -L --fail -o "${LIB_ARCHIVE_PATH}.partial" "${LIB_URL}"
  mv "${LIB_ARCHIVE_PATH}.partial" "${LIB_ARCHIVE_PATH}"
fi
verify_sha256 "${LIB_ARCHIVE_PATH}" "${LIB_SHA256}"

if [[ ! -f "${LIB_DIR}/libsherpa-onnx-c-api.dylib" || ! -f "${LIB_DIR}/libonnxruntime.1.24.4.dylib" ]]; then
  rm -rf "${TMP_DIR:?}"/*
  tar -xjf "${LIB_ARCHIVE_PATH}" -C "${TMP_DIR}"
  FOUND_LIB_DIR="$(find "${TMP_DIR}" -type d -name lib | head -n 1)"
  if [[ -z "${FOUND_LIB_DIR}" ]]; then
    echo "sherpa-onnx lib directory not found in ${LIB_ARCHIVE_PATH}" >&2
    exit 1
  fi

  cp "${FOUND_LIB_DIR}/libsherpa-onnx-c-api.dylib" "${LIB_DIR}/"
  cp "${FOUND_LIB_DIR}/libonnxruntime.1.24.4.dylib" "${LIB_DIR}/"
fi

echo "==> sherpa-onnx runtime ready: ${FRAMEWORK_DIR}"
