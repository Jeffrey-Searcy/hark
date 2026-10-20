#!/usr/bin/env bash
# setup-reader.sh — one-time setup for the Read Aloud feature, from Terminal.
#
# The app's setup window does the same job on first launch; this script is for
# developers who prefer Terminal. It creates a private Python environment with the
# exact packages in reader-requirements.txt (checksums required), then downloads the
# Kokoro model files (~350 MB) and checks their SHA-256. Everything goes in
# ~/Library/Application Support/Hark/reader/, which is where AppPaths.swift looks.
# Needs `uv` (brew install uv). Safe to run again: existing files are kept.
set -euo pipefail
cd "$(dirname "$0")"

READER="$HOME/Library/Application Support/Hark/reader"
MODELS="$READER/models"
RELEASE="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1"
# Must match AppPaths.readerPythonVersion.
PYTHON="3.12.12"

command -v uv >/dev/null || { echo "uv is not installed. Install it with: brew install uv" >&2; exit 1; }

mkdir -p "$MODELS"
if [[ -x "$READER/venv/bin/python3" ]]; then
  echo "Already have the Python environment"
else
  uv venv --python "$PYTHON" "$READER/venv"
  uv pip install --python "$READER/venv/bin/python3" --require-hashes -r reader-requirements.txt
fi

# name and SHA-256 of each model file (same values as SetupWindow.swift)
while read -r f sum; do
  if [[ -s "$MODELS/$f" ]]; then
    echo "Already have $f"
    continue
  fi
  curl -fL --progress-bar -o "$MODELS/$f.part" "$RELEASE/$f"
  echo "$sum  $MODELS/$f.part" | shasum -a 256 -c - >/dev/null || { rm -f "$MODELS/$f.part"; echo "$f failed its checksum" >&2; exit 1; }
  mv "$MODELS/$f.part" "$MODELS/$f"
done <<'LIST'
kokoro-v1.0.onnx beb0d1848dee9a49da392cc3df26958d46cfa35d321edf434f52949153f0df3a
voices-v1.0.bin bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d
LIST
echo "Read Aloud is set up in: $READER"
