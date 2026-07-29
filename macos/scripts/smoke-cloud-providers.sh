#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d /tmp/gugutalk-cloud-provider-smoke.XXXXXX)"
SEMANTIC_MODEL_NAME="distilbert-base-multilingual-cased-onnx-int8"
DEFAULT_SEMANTIC_MODEL_DIR="${HOME}/Library/Application Support/GuGuTalk/models/${SEMANTIC_MODEL_NAME}"
LIB_DIR="${ROOT_DIR}/ThirdParty/sherpa-onnx/lib"

cleanup() {
  rm -rf "${BUILD_DIR}"
}
trap cleanup EXIT

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <16 kHz mono WAV>" >&2
  exit 2
fi

if [[ ! -f "$1" ]]; then
  echo "Smoke audio does not exist: $1" >&2
  exit 2
fi

"${ROOT_DIR}/scripts/install-sensevoice-runtime.sh"

SEMANTIC_MODEL_DIR="${GUGUTALK_SEMANTIC_MODEL_DIR:-${DEFAULT_SEMANTIC_MODEL_DIR}}"
if [[ ! -f "${SEMANTIC_MODEL_DIR}/model.int8.onnx" \
   || ! -f "${SEMANTIC_MODEL_DIR}/vocab.txt" \
   || ! -f "${SEMANTIC_MODEL_DIR}/pinyin.txt" \
   || ! -f "${SEMANTIC_MODEL_DIR}/cmudict.dict" ]]; then
  "${ROOT_DIR}/scripts/install-local-asr-models.sh"
  SEMANTIC_MODEL_DIR="${DEFAULT_SEMANTIC_MODEL_DIR}"
fi

clang -c \
  "${ROOT_DIR}/Sources/SemanticOnnxBridge/SemanticOnnxBridge.c" \
  -I "${ROOT_DIR}/ThirdParty/onnxruntime/include" \
  -I "${ROOT_DIR}/Sources/SemanticOnnxBridge/include" \
  -o "${BUILD_DIR}/SemanticOnnxBridge.o"

swiftc \
  -parse-as-library \
  -o "${BUILD_DIR}/CloudProviderSmoke" \
  "${ROOT_DIR}/scripts/CloudProviderSmoke.swift" \
  "${ROOT_DIR}/Sources/DesktopVoiceInput/Models/RecognitionModels.swift" \
  "${ROOT_DIR}/Sources/DesktopVoiceInput/Models/HotwordStore.swift" \
  "${ROOT_DIR}/Sources/DesktopVoiceInput/Services/TranscriptPostProcessor.swift" \
  "${ROOT_DIR}/Sources/DesktopVoiceInput/Services/Providers/SpeechProvider.swift" \
  "${ROOT_DIR}/Sources/DesktopVoiceInput/Services/Providers/RealtimeWebSocketTransport.swift" \
  "${ROOT_DIR}/Sources/DesktopVoiceInput/Services/Providers/DoubaoSpeechProvider.swift" \
  "${ROOT_DIR}/Sources/DesktopVoiceInput/Services/Providers/QwenSpeechProvider.swift" \
  "${ROOT_DIR}/Sources/DesktopVoiceInput/Services/PersonalLexiconCorrector.swift" \
  -import-objc-header "${ROOT_DIR}/Sources/DesktopVoiceInput/Services/Providers/SherpaOnnx-Bridging-Header.h" \
  -Xcc -I"${ROOT_DIR}/ThirdParty/sherpa-onnx/sherpa-onnx.xcframework/macos-arm64_x86_64/Headers" \
  -Xcc -I"${ROOT_DIR}/ThirdParty/onnxruntime/include" \
  -Xcc -I"${ROOT_DIR}/Sources/SemanticOnnxBridge/include" \
  "${BUILD_DIR}/SemanticOnnxBridge.o" \
  -L "${LIB_DIR}" \
  -lonnxruntime.1.24.4 \
  -lz \
  -framework AppKit \
  -framework AVFoundation \
  -Xlinker -rpath \
  -Xlinker "${LIB_DIR}"

GUGUTALK_SEMANTIC_MODEL_DIR="${SEMANTIC_MODEL_DIR}" \
  "${BUILD_DIR}/CloudProviderSmoke" "$1"
