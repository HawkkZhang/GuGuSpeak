#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASR_MODEL_NAME="sherpa-onnx-streaming-paraformer-bilingual-zh-en"
PUNCTUATION_MODEL_NAME="sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8"
DEFAULT_MODELS_ROOT="${HOME}/Library/Application Support/GuGuTalk/models"
MODELS_ROOT="${1:-${GUGUTALK_LOCAL_ASR_MODEL_DIR:-${DEFAULT_MODELS_ROOT}}}"
ASR_MODEL_DIR="${MODELS_ROOT}/${ASR_MODEL_NAME}"
PUNCTUATION_MODEL_DIR="${MODELS_ROOT}/${PUNCTUATION_MODEL_NAME}"
HEADER_DIR="${ROOT_DIR}/ThirdParty/sherpa-onnx/sherpa-onnx.xcframework/macos-arm64_x86_64/Headers"
LIB_DIR="${ROOT_DIR}/ThirdParty/sherpa-onnx/lib"
TEMP_DIR="$(mktemp -d /tmp/gugutalk-local-asr-smoke.XXXXXX)"
SMOKE_AUDIO_DIR="${HOME}/Library/Caches/GuGuTalk/local-asr-smoke-audio"
ASR_REPOSITORY="csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en"
ASR_REVISION="8e40c43232a1c5c66c82111efc5820d3accca11b"
PRIMARY_HF_BASE_URL="${GUGUTALK_HF_BASE_URL:-https://huggingface.co}"
FALLBACK_HF_BASE_URL="https://hf-mirror.com"

cleanup() {
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

download_smoke_audio() {
  local filename="$1"
  local expected_sha256="$2"
  local output_path="${SMOKE_AUDIO_DIR}/${filename}"
  local partial_path="${output_path}.partial"

  if [[ -f "${output_path}" ]]; then
    local actual
    actual="$(shasum -a 256 "${output_path}" | awk '{print $1}')"
    if [[ "${actual}" == "${expected_sha256}" ]]; then
      return 0
    fi
  fi

  local relative_path="${ASR_REPOSITORY}/resolve/${ASR_REVISION}/test_wavs/${filename}"
  if ! curl -L --fail --retry 3 --connect-timeout 20 --max-time 180 \
      -o "${partial_path}" "${PRIMARY_HF_BASE_URL}/${relative_path}"; then
    curl -L --fail --retry 3 --connect-timeout 20 --max-time 180 \
      -o "${partial_path}" "${FALLBACK_HF_BASE_URL}/${relative_path}"
  fi

  local actual
  actual="$(shasum -a 256 "${partial_path}" | awk '{print $1}')"
  if [[ "${actual}" != "${expected_sha256}" ]]; then
    echo "Smoke audio checksum mismatch for ${filename}: expected ${expected_sha256}, got ${actual}" >&2
    exit 1
  fi
  mv -f "${partial_path}" "${output_path}"
}

"${ROOT_DIR}/scripts/install-sensevoice-runtime.sh"

if [[ ! -f "${ASR_MODEL_DIR}/encoder.int8.onnx" \
   || ! -f "${ASR_MODEL_DIR}/decoder.int8.onnx" \
   || ! -f "${ASR_MODEL_DIR}/tokens.txt" \
   || ! -f "${PUNCTUATION_MODEL_DIR}/model.int8.onnx" ]]; then
  "${ROOT_DIR}/scripts/install-local-asr-models.sh" "${MODELS_ROOT}"
fi

mkdir -p "${SMOKE_AUDIO_DIR}"
download_smoke_audio "0.wav" "7d93384ca14702cc584a7a33fe2fed92e89e708549161cb12ea38c916882103b"
download_smoke_audio "1.wav" "8bfb42c963e623ebab31b81ff4404867d07d3102507c87ac14577c4c61663b8c"

swiftc \
  -parse-as-library \
  -import-objc-header "${ROOT_DIR}/Sources/DesktopVoiceInput/Services/Providers/SherpaOnnx-Bridging-Header.h" \
  -Xcc -I"${HEADER_DIR}" \
  -L "${LIB_DIR}" \
  -lsherpa-onnx-c-api \
  -lonnxruntime.1.24.4 \
  -lc++ \
  -framework AppKit \
  -framework AVFoundation \
  -Xlinker -rpath \
  -Xlinker "${LIB_DIR}" \
  "${ROOT_DIR}/Sources/DesktopVoiceInput/Models/RecognitionModels.swift" \
  "${ROOT_DIR}/Sources/DesktopVoiceInput/Services/Providers/SpeechProvider.swift" \
  "${ROOT_DIR}/Sources/DesktopVoiceInput/Services/Providers/LocalAsrModelManager.swift" \
  "${ROOT_DIR}/Sources/DesktopVoiceInput/Services/Providers/LocalSpeechProvider.swift" \
  "${ROOT_DIR}/Sources/DesktopVoiceInput/Services/Providers/SherpaOnnx.swift" \
  "${ROOT_DIR}/scripts/LocalAsrSmoke.swift" \
  -o "${TEMP_DIR}/LocalAsrSmoke"

GUGUTALK_LOCAL_ASR_MODEL_DIR="${MODELS_ROOT}" \
GUGUTALK_LOCAL_PUNCTUATION_MODEL_DIR="${MODELS_ROOT}" \
  "${TEMP_DIR}/LocalAsrSmoke" "${MODELS_ROOT}" "${SMOKE_AUDIO_DIR}"
