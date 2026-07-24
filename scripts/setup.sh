#!/bin/bash
# One-shot setup: installs dependencies, downloads models, builds the app,
# and launches it. Safe to re-run; each step skips work already done.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh"; exit 1; }

echo "== Dependencies"
brew list whisper-cpp >/dev/null 2>&1 || brew install whisper-cpp
brew list ollama >/dev/null 2>&1 || brew install ollama

echo "== Whisper model (1.6 GB)"
MODELS="$HOME/Library/Application Support/Riffle/models"
mkdir -p "$MODELS"
if [ ! -f "$MODELS/ggml-large-v3-turbo.bin" ]; then
  curl -L --retry 3 -o "$MODELS/ggml-large-v3-turbo.bin.part" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
  mv "$MODELS/ggml-large-v3-turbo.bin.part" "$MODELS/ggml-large-v3-turbo.bin"
fi

echo "== Ollama service and cleanup model (4.7 GB)"
brew services start ollama || true
sleep 2
ollama pull qwen2.5:7b

echo "== Build and install"
scripts/build_app.sh

echo "== Launch"
open /Applications/Riffle.app 2>/dev/null || open "$HOME/Applications/Riffle.app"

echo
echo "Done. Grant Accessibility and Microphone when prompted, then hold fn and speak."
