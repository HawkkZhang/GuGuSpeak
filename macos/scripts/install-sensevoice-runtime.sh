#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${GUGUTALK_SHERPA_ONNX_VERSION:-v1.13.2}"
FRAMEWORK_ARCHIVE="sherpa-onnx-${VERSION}-macos-xcframework-static.tar.bz2"
FRAMEWORK_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${VERSION}/${FRAMEWORK_ARCHIVE}"
LIB_ARCHIVE="sherpa-onnx-${VERSION}-osx-universal2-shared-no-tts-lib.tar.bz2"
LIB_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${VERSION}/${LIB_ARCHIVE}"
INSTALL_DIR="${ROOT_DIR}/ThirdParty/sherpa-onnx"
FRAMEWORK_DIR="${INSTALL_DIR}/sherpa-onnx.xcframework"
LIB_DIR="${INSTALL_DIR}/lib"
CACHE_DIR="${ROOT_DIR}/.modelcache"

if [[ -d "${FRAMEWORK_DIR}" && -f "${LIB_DIR}/libsherpa-onnx-c-api.dylib" && -f "${LIB_DIR}/libonnxruntime.1.24.4.dylib" ]]; then
  exit 0
fi

mkdir -p "${INSTALL_DIR}" "${LIB_DIR}" "${CACHE_DIR}"

FRAMEWORK_ARCHIVE_PATH="${CACHE_DIR}/${FRAMEWORK_ARCHIVE}"
if [[ ! -f "${FRAMEWORK_ARCHIVE_PATH}" ]]; then
  echo "==> Downloading sherpa-onnx macOS xcframework ${VERSION}"
  curl -L --fail -o "${FRAMEWORK_ARCHIVE_PATH}.partial" "${FRAMEWORK_URL}"
  mv "${FRAMEWORK_ARCHIVE_PATH}.partial" "${FRAMEWORK_ARCHIVE_PATH}"
fi

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
