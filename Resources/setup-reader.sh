#!/usr/bin/env bash
# setup-reader.sh — one-time setup for the Read Aloud feature.
#
# Creates a private Python 3.12 environment with the Kokoro voice engine and the
# trafilatura article extractor, and downloads the Kokoro model files (~350 MB).
# Everything goes in ~/Library/Application Support/Hark/reader/, which is
# where AppPaths.swift looks. Needs `uv` (brew install uv). Safe to run again:
# existing model files are kept.
set -euo pipefail

READER="$HOME/Library/Application Support/Hark/reader"
MODELS="$READER/models"
RELEASE="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1"

command -v uv >/dev/null || { echo "uv is not installed. Install it with: brew install uv" >&2; exit 1; }

mkdir -p "$MODELS"
# kokoro-onnx 0.6.1 supports Python 3.10–3.13, so pin 3.12 rather than the system default.
uv venv --allow-existing --python 3.12 "$READER/venv"
uv pip install --python "$READER/venv/bin/python3" kokoro-onnx==0.6.1 trafilatura==2.3.1

for f in kokoro-v1.0.onnx voices-v1.0.bin; do
  if [[ -s "$MODELS/$f" ]]; then
    echo "Already have $f"
  else
    curl -fL --progress-bar -o "$MODELS/$f.part" "$RELEASE/$f"
    mv "$MODELS/$f.part" "$MODELS/$f"
  fi
done
echo "Read Aloud is set up in: $READER"
