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

echo "== Code signing identity"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Riffle Local Signing"; then
  echo "Riffle Local Signing identity already present."
else
  echo "Creating a local code-signing certificate so macOS keeps your"
  echo "Accessibility grant across rebuilds. Approve the dialog if one appears."
  CERTDIR="$(mktemp -d)"
  trap 'rm -rf "$CERTDIR"' EXIT
  openssl req -x509 -newkey rsa:2048 -keyout "$CERTDIR/key.pem" -out "$CERTDIR/cert.pem" \
    -days 3650 -nodes -subj "/CN=Riffle Local Signing" \
    -addext "keyUsage=digitalSignature" -addext "extendedKeyUsage=codeSigning" \
    -addext "basicConstraints=CA:FALSE" >/dev/null 2>&1
  # OpenSSL 3 defaults to a p12 cipher the macOS keychain rejects; LibreSSL
  # (stock macOS) has no -legacy flag and needs none.
  if openssl version | grep -q "^OpenSSL 3"; then
    openssl pkcs12 -export -legacy -out "$CERTDIR/riffle.p12" -inkey "$CERTDIR/key.pem" \
      -in "$CERTDIR/cert.pem" -passout pass:rifflelocal >/dev/null 2>&1
  else
    openssl pkcs12 -export -out "$CERTDIR/riffle.p12" -inkey "$CERTDIR/key.pem" \
      -in "$CERTDIR/cert.pem" -passout pass:rifflelocal >/dev/null 2>&1
  fi
  security import "$CERTDIR/riffle.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P rifflelocal -T /usr/bin/codesign >/dev/null 2>&1 || true
  security add-trusted-cert -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" "$CERTDIR/cert.pem" || true
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "Riffle Local Signing"; then
    echo "Signing identity created. Permissions will survive rebuilds."
  else
    echo "Could not create the identity; continuing with ad-hoc signing."
    echo "Accessibility will need re-granting after each rebuild."
  fi
fi

echo "== Build and install"
scripts/build_app.sh

echo "== Launch"
open /Applications/Riffle.app 2>/dev/null || open "$HOME/Applications/Riffle.app"

echo
echo "Done. Grant Accessibility and Microphone when prompted, then hold fn and speak."
