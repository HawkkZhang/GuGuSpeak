#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d /tmp/gugutalk-personal-lexicon-smoke.XXXXXX)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

SEMANTIC_MODEL_NAME="distilbert-base-multilingual-cased-onnx-int8"
DEFAULT_SEMANTIC_MODEL_DIR="${HOME}/Library/Application Support/GuGuTalk/models/${SEMANTIC_MODEL_NAME}"
INSTALLED_APP_MODEL_DIR="/Applications/GuGuTalk.app/Contents/Resources/models/${SEMANTIC_MODEL_NAME}"

semantic_model_is_ready() {
  local directory="$1"
  [[ -f "${directory}/model.int8.onnx" \
    && -f "${directory}/vocab.txt" \
    && -f "${directory}/pinyin.txt" \
    && -f "${directory}/cmudict.dict" ]]
}

"${ROOT_DIR}/scripts/install-sensevoice-runtime.sh"

SEMANTIC_MODEL_DIR="${GUGUTALK_SEMANTIC_MODEL_DIR:-${DEFAULT_SEMANTIC_MODEL_DIR}}"
if ! semantic_model_is_ready "${SEMANTIC_MODEL_DIR}"; then
  if semantic_model_is_ready "${INSTALLED_APP_MODEL_DIR}"; then
    SEMANTIC_MODEL_DIR="${INSTALLED_APP_MODEL_DIR}"
  else
    "${ROOT_DIR}/scripts/install-local-asr-models.sh"
    SEMANTIC_MODEL_DIR="${DEFAULT_SEMANTIC_MODEL_DIR}"
  fi
fi
export GUGUTALK_SEMANTIC_MODEL_DIR="${SEMANTIC_MODEL_DIR}"

clang -c \
  "${ROOT_DIR}/Sources/SemanticOnnxBridge/SemanticOnnxBridge.c" \
  -I "${ROOT_DIR}/ThirdParty/onnxruntime/include" \
  -I "${ROOT_DIR}/Sources/SemanticOnnxBridge/include" \
  -o "${BUILD_DIR}/SemanticOnnxBridge.o"

swiftc \
  -parse-as-library \
  -o "${BUILD_DIR}/PersonalLexiconSmoke" \
  "${ROOT_DIR}/scripts/PersonalLexiconSmoke.swift" \
  "${ROOT_DIR}/Sources/DesktopVoiceInput/Models/HotwordStore.swift" \
  "${ROOT_DIR}/Sources/DesktopVoiceInput/Services/PersonalLexiconCorrector.swift" \
  -import-objc-header "${ROOT_DIR}/Sources/DesktopVoiceInput/Services/Providers/SherpaOnnx-Bridging-Header.h" \
  -Xcc -I"${ROOT_DIR}/ThirdParty/sherpa-onnx/sherpa-onnx.xcframework/macos-arm64_x86_64/Headers" \
  -Xcc -I"${ROOT_DIR}/ThirdParty/onnxruntime/include" \
  -Xcc -I"${ROOT_DIR}/Sources/SemanticOnnxBridge/include" \
  "${BUILD_DIR}/SemanticOnnxBridge.o" \
  -L "${ROOT_DIR}/ThirdParty/sherpa-onnx/lib" \
  -lonnxruntime.1.24.4

DYLD_LIBRARY_PATH="${ROOT_DIR}/ThirdParty/sherpa-onnx/lib" \
  "${BUILD_DIR}/PersonalLexiconSmoke"
