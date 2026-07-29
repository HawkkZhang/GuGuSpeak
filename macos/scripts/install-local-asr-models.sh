#!/usr/bin/env bash
set -euo pipefail

ASR_MODEL_NAME="sherpa-onnx-streaming-paraformer-bilingual-zh-en"
PUNCTUATION_MODEL_NAME="sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8"
SEMANTIC_MODEL_NAME="distilbert-base-multilingual-cased-onnx-int8"

ASR_REPOSITORY="csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en"
ASR_REVISION="8e40c43232a1c5c66c82111efc5820d3accca11b"
ASR_ENCODER_REMOTE_NAME="encoder.int8.onnx"
ASR_DECODER_REMOTE_NAME="decoder.int8.onnx"
ASR_ENCODER_SHA256="81a70226a8934e6ed92aa1d4fc486b428b5398e2f2619ed4897b7294cab90e9a"
ASR_DECODER_SHA256="f3cca9f77bb9d93c8fcbfb63ae617b6b1ee96818df3aa3b151c40658fe38594f"
ASR_TOKENS_SHA256="59aba8873a2ed1e122c25fee421e25f283b63290efbde85c1f01a853d83cb6e6"

# This file is byte-identical to the int8 model in k2-fsa's official
# punctuation-models release. The pinned digest is checked before installation.
PUNCTUATION_REPOSITORY="ranger810/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8"
PUNCTUATION_REVISION="5cccf43af83e4fc50d1d55b8410312e87709be70"
PUNCTUATION_SHA256="65a3fb9f5ad7bfb96bf69e0dc4481df97f6ee60513c1d94ce981ba6effd524b1"

SEMANTIC_REPOSITORY="onnx-community/distilbert-base-multilingual-cased-ONNX"
SEMANTIC_REVISION="2e7303d946cfc9194a939e02efb46824eb440379"
SEMANTIC_MODEL_SHA256="4fa42d6f6e7d00dd734cdff3fd55b446dec3439de3f8c2e1d162e056969be343"
SEMANTIC_VOCAB_SHA256="fe0fda7c425b48c516fc8f160d594c8022a0808447475c1a7c6d6479763f310c"
PINYIN_REVISION="923b108dc5d45dee061324c011b478fb649f8b73"
PINYIN_SHA256="621f8ca9eff8519f47e2b17b564fd318161e13bca07eea8c8e04993cd5d3b52e"
PINYIN_LICENSE_SHA256="9c048697be2502a16e8bcb282d5d465a07295b2def0ffb05a269c5d39dbe1586"
CMUDICT_REVISION="74790861f652b15e4ac49015a90074ad62a27690"
CMUDICT_SHA256="81917843c7f44ce2b094ac63873c2c7a4cf802040792c455ba3ca406891c3d22"
CMUDICT_LICENSE_SHA256="bd4ce8e44170a5f9f481310ca85c51de3c4f851a65e679b40e603b143bd3542a"

DEFAULT_ROOT="${HOME}/Library/Application Support/GuGuTalk/models"
TARGET_ROOT="${1:-${GUGUTALK_LOCAL_ASR_MODEL_ROOT:-${DEFAULT_ROOT}}}"
CACHE_ROOT="${HOME}/Library/Caches/GuGuTalk/local-asr-models"
PRIMARY_HF_BASE_URL="${GUGUTALK_HF_BASE_URL:-https://huggingface.co}"
FALLBACK_HF_BASE_URL="https://hf-mirror.com"

ASR_TARGET_DIR="${TARGET_ROOT}/${ASR_MODEL_NAME}"
PUNCTUATION_TARGET_DIR="${TARGET_ROOT}/${PUNCTUATION_MODEL_NAME}"
SEMANTIC_TARGET_DIR="${TARGET_ROOT}/${SEMANTIC_MODEL_NAME}"
ASR_CACHE_DIR="${CACHE_ROOT}/${ASR_MODEL_NAME}"
PUNCTUATION_CACHE_DIR="${CACHE_ROOT}/${PUNCTUATION_MODEL_NAME}"
SEMANTIC_CACHE_DIR="${CACHE_ROOT}/${SEMANTIC_MODEL_NAME}"

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

verify_file() {
  local path="$1"
  local expected="$2"
  local label="$3"
  local actual
  actual="$(sha256_of "${path}")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "${label} checksum mismatch: expected ${expected}, got ${actual}" >&2
    return 1
  fi
}

download_verified() {
  local repository="$1"
  local revision="$2"
  local remote_name="$3"
  local output_path="$4"
  local expected_sha256="$5"
  local label="$6"
  local partial_path="${output_path}.partial"

  if [[ -f "${output_path}" ]] && verify_file "${output_path}" "${expected_sha256}" "${label}"; then
    return 0
  fi

  local primary_url="${PRIMARY_HF_BASE_URL}/${repository}/resolve/${revision}/${remote_name}"
  local fallback_url="${FALLBACK_HF_BASE_URL}/${repository}/resolve/${revision}/${remote_name}"

  echo "==> Downloading ${label}"
  if ! curl -L --fail --retry 3 --connect-timeout 20 --max-time 1200 \
      -o "${partial_path}" "${primary_url}"; then
    if [[ "${PRIMARY_HF_BASE_URL}" == "${FALLBACK_HF_BASE_URL}" ]]; then
      return 1
    fi
    echo "==> Primary model source unavailable; trying verified mirror"
    curl -L --fail --retry 3 --connect-timeout 20 --max-time 1200 \
      -o "${partial_path}" "${fallback_url}"
  fi

  verify_file "${partial_path}" "${expected_sha256}" "${label}"
  mv -f "${partial_path}" "${output_path}"
}

download_verified_url() {
  local primary_url="$1"
  local fallback_url="$2"
  local output_path="$3"
  local expected_sha256="$4"
  local label="$5"
  local partial_path="${output_path}.partial"

  if [[ -f "${output_path}" ]] && verify_file "${output_path}" "${expected_sha256}" "${label}"; then
    return 0
  fi

  echo "==> Downloading ${label}"
  if ! curl -L --fail --retry 3 --connect-timeout 20 --max-time 1200 \
      -o "${partial_path}" "${primary_url}"; then
    curl -L --fail --retry 3 --connect-timeout 20 --max-time 1200 \
      -o "${partial_path}" "${fallback_url}"
  fi
  verify_file "${partial_path}" "${expected_sha256}" "${label}"
  mv -f "${partial_path}" "${output_path}"
}

install_license() {
  local cache_path="${CACHE_ROOT}/Apache-2.0.txt"
  if [[ ! -s "${cache_path}" ]]; then
    local partial_path="${cache_path}.partial"
    echo "==> Downloading Apache-2.0 license"
    if ! curl -L --fail --retry 3 --connect-timeout 20 --max-time 120 \
        -o "${partial_path}" "https://www.apache.org/licenses/LICENSE-2.0.txt"; then
      curl -L --fail --retry 3 --connect-timeout 20 --max-time 120 \
        -o "${partial_path}" "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.2/LICENSE"
    fi
    mv -f "${partial_path}" "${cache_path}"
  fi

  cp "${cache_path}" "${ASR_TARGET_DIR}/LICENSE"
  cp "${cache_path}" "${PUNCTUATION_TARGET_DIR}/LICENSE"
  cp "${cache_path}" "${SEMANTIC_TARGET_DIR}/LICENSE"
}

verify_installation() {
  verify_file "${ASR_TARGET_DIR}/encoder.int8.onnx" "${ASR_ENCODER_SHA256}" "Paraformer encoder"
  verify_file "${ASR_TARGET_DIR}/decoder.int8.onnx" "${ASR_DECODER_SHA256}" "Paraformer decoder"
  verify_file "${ASR_TARGET_DIR}/tokens.txt" "${ASR_TOKENS_SHA256}" "Paraformer tokens"
  verify_file "${PUNCTUATION_TARGET_DIR}/model.int8.onnx" "${PUNCTUATION_SHA256}" "CT-Transformer punctuation"
  verify_file "${SEMANTIC_TARGET_DIR}/model.int8.onnx" "${SEMANTIC_MODEL_SHA256}" "Multilingual semantic model"
  verify_file "${SEMANTIC_TARGET_DIR}/vocab.txt" "${SEMANTIC_VOCAB_SHA256}" "Multilingual semantic vocabulary"
  verify_file "${SEMANTIC_TARGET_DIR}/pinyin.txt" "${PINYIN_SHA256}" "Pinyin pronunciation data"
  verify_file "${SEMANTIC_TARGET_DIR}/PINYIN_LICENSE" "${PINYIN_LICENSE_SHA256}" "Pinyin data license"
  verify_file "${SEMANTIC_TARGET_DIR}/cmudict.dict" "${CMUDICT_SHA256}" "CMU English pronunciation data"
  verify_file "${SEMANTIC_TARGET_DIR}/CMUDICT_LICENSE" "${CMUDICT_LICENSE_SHA256}" "CMUdict license"
}

if [[ -f "${ASR_TARGET_DIR}/encoder.int8.onnx" \
   && -f "${ASR_TARGET_DIR}/decoder.int8.onnx" \
   && -f "${ASR_TARGET_DIR}/tokens.txt" \
   && -f "${PUNCTUATION_TARGET_DIR}/model.int8.onnx" \
   && -f "${SEMANTIC_TARGET_DIR}/model.int8.onnx" \
   && -f "${SEMANTIC_TARGET_DIR}/vocab.txt" \
   && -f "${SEMANTIC_TARGET_DIR}/pinyin.txt" \
   && -f "${SEMANTIC_TARGET_DIR}/PINYIN_LICENSE" \
   && -f "${SEMANTIC_TARGET_DIR}/cmudict.dict" \
   && -f "${SEMANTIC_TARGET_DIR}/CMUDICT_LICENSE" \
   && -f "${ASR_TARGET_DIR}/LICENSE" \
   && -f "${PUNCTUATION_TARGET_DIR}/LICENSE" \
   && -f "${SEMANTIC_TARGET_DIR}/LICENSE" ]]; then
  verify_installation
  echo "==> Local streaming ASR models already installed: ${TARGET_ROOT}"
  exit 0
fi

mkdir -p "${ASR_CACHE_DIR}" "${PUNCTUATION_CACHE_DIR}" "${SEMANTIC_CACHE_DIR}" \
  "${ASR_TARGET_DIR}" "${PUNCTUATION_TARGET_DIR}" "${SEMANTIC_TARGET_DIR}"

download_verified \
  "${ASR_REPOSITORY}" "${ASR_REVISION}" "${ASR_ENCODER_REMOTE_NAME}" \
  "${ASR_CACHE_DIR}/encoder.int8.onnx" "${ASR_ENCODER_SHA256}" "Paraformer encoder"
download_verified \
  "${ASR_REPOSITORY}" "${ASR_REVISION}" "${ASR_DECODER_REMOTE_NAME}" \
  "${ASR_CACHE_DIR}/decoder.int8.onnx" "${ASR_DECODER_SHA256}" "Paraformer decoder"
download_verified \
  "${ASR_REPOSITORY}" "${ASR_REVISION}" "tokens.txt" \
  "${ASR_CACHE_DIR}/tokens.txt" "${ASR_TOKENS_SHA256}" "Paraformer tokens"
download_verified \
  "${PUNCTUATION_REPOSITORY}" "${PUNCTUATION_REVISION}" "model.int8.onnx" \
  "${PUNCTUATION_CACHE_DIR}/model.int8.onnx" "${PUNCTUATION_SHA256}" "CT-Transformer punctuation"
download_verified \
  "${SEMANTIC_REPOSITORY}" "${SEMANTIC_REVISION}" "onnx/model_int8.onnx" \
  "${SEMANTIC_CACHE_DIR}/model.int8.onnx" "${SEMANTIC_MODEL_SHA256}" "Multilingual semantic model"
download_verified \
  "${SEMANTIC_REPOSITORY}" "${SEMANTIC_REVISION}" "vocab.txt" \
  "${SEMANTIC_CACHE_DIR}/vocab.txt" "${SEMANTIC_VOCAB_SHA256}" "Multilingual semantic vocabulary"
download_verified_url \
  "https://cdn.jsdelivr.net/gh/mozillazg/pinyin-data@${PINYIN_REVISION}/pinyin.txt" \
  "https://raw.githubusercontent.com/mozillazg/pinyin-data/${PINYIN_REVISION}/pinyin.txt" \
  "${SEMANTIC_CACHE_DIR}/pinyin.txt" "${PINYIN_SHA256}" "Pinyin pronunciation data"
download_verified_url \
  "https://cdn.jsdelivr.net/gh/mozillazg/pinyin-data@${PINYIN_REVISION}/LICENSE" \
  "https://raw.githubusercontent.com/mozillazg/pinyin-data/${PINYIN_REVISION}/LICENSE" \
  "${SEMANTIC_CACHE_DIR}/PINYIN_LICENSE" "${PINYIN_LICENSE_SHA256}" "Pinyin data license"
download_verified_url \
  "https://cdn.jsdelivr.net/gh/cmusphinx/cmudict@${CMUDICT_REVISION}/cmudict.dict" \
  "https://raw.githubusercontent.com/cmusphinx/cmudict/${CMUDICT_REVISION}/cmudict.dict" \
  "${SEMANTIC_CACHE_DIR}/cmudict.dict" "${CMUDICT_SHA256}" "CMU English pronunciation data"
download_verified_url \
  "https://cdn.jsdelivr.net/gh/cmusphinx/cmudict@${CMUDICT_REVISION}/LICENSE" \
  "https://raw.githubusercontent.com/cmusphinx/cmudict/${CMUDICT_REVISION}/LICENSE" \
  "${SEMANTIC_CACHE_DIR}/CMUDICT_LICENSE" "${CMUDICT_LICENSE_SHA256}" "CMUdict license"

cp "${ASR_CACHE_DIR}/encoder.int8.onnx" "${ASR_TARGET_DIR}/encoder.int8.onnx"
cp "${ASR_CACHE_DIR}/decoder.int8.onnx" "${ASR_TARGET_DIR}/decoder.int8.onnx"
cp "${ASR_CACHE_DIR}/tokens.txt" "${ASR_TARGET_DIR}/tokens.txt"
cp "${PUNCTUATION_CACHE_DIR}/model.int8.onnx" "${PUNCTUATION_TARGET_DIR}/model.int8.onnx"
cp "${SEMANTIC_CACHE_DIR}/model.int8.onnx" "${SEMANTIC_TARGET_DIR}/model.int8.onnx"
cp "${SEMANTIC_CACHE_DIR}/vocab.txt" "${SEMANTIC_TARGET_DIR}/vocab.txt"
cp "${SEMANTIC_CACHE_DIR}/pinyin.txt" "${SEMANTIC_TARGET_DIR}/pinyin.txt"
cp "${SEMANTIC_CACHE_DIR}/PINYIN_LICENSE" "${SEMANTIC_TARGET_DIR}/PINYIN_LICENSE"
cp "${SEMANTIC_CACHE_DIR}/cmudict.dict" "${SEMANTIC_TARGET_DIR}/cmudict.dict"
cp "${SEMANTIC_CACHE_DIR}/CMUDICT_LICENSE" "${SEMANTIC_TARGET_DIR}/CMUDICT_LICENSE"
install_license
verify_installation

echo "==> Local streaming ASR models ready: ${TARGET_ROOT}"
