#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "install-sensevoice-model.sh is deprecated; installing the streaming local ASR models instead."
exec "${SCRIPT_DIR}/install-local-asr-models.sh" "$@"
