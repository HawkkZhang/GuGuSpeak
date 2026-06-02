#!/usr/bin/env bash
set -euo pipefail

MODEL_NAME="${GUGUTALK_SENSEVOICE_MODEL_NAME:-sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17}"
ARCHIVE="${MODEL_NAME}.tar.bz2"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${ARCHIVE}"
DEFAULT_ROOT="${HOME}/Library/Application Support/GuGuTalk/models"
TARGET_ROOT="${1:-${GUGUTALK_LOCAL_ASR_MODEL_ROOT:-${DEFAULT_ROOT}}}"
CACHE_DIR="${HOME}/Library/Caches/GuGuTalk"
TARGET_DIR="${TARGET_ROOT}/${MODEL_NAME}"

if [[ -f "${TARGET_DIR}/tokens.txt" && -f "${TARGET_DIR}/model.int8.onnx" ]]; then
  echo "==> SenseVoice model already installed: ${TARGET_DIR}"
  exit 0
fi

mkdir -p "${TARGET_ROOT}" "${CACHE_DIR}"

ARCHIVE_PATH="${CACHE_DIR}/${ARCHIVE}"
if [[ ! -f "${ARCHIVE_PATH}" ]]; then
  echo "==> Downloading SenseVoice model: ${MODEL_NAME}"
  curl -L --fail -o "${ARCHIVE_PATH}.partial" "${URL}"
  mv "${ARCHIVE_PATH}.partial" "${ARCHIVE_PATH}"
fi

echo "==> Extracting model to ${TARGET_ROOT}"
tar -xjf "${ARCHIVE_PATH}" -C "${TARGET_ROOT}"

if [[ ! -f "${TARGET_DIR}/tokens.txt" || ! -f "${TARGET_DIR}/model.int8.onnx" ]]; then
  echo "SenseVoice model extraction failed: expected files missing under ${TARGET_DIR}" >&2
  exit 1
fi

echo "==> SenseVoice model ready: ${TARGET_DIR}"
