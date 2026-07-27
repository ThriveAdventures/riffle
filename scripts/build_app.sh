#!/bin/bash
# Builds Riffle and installs it as /Applications/Riffle.app (falls back to
# ~/Applications if /Applications is not writable). Ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."

# The Apple cleanup engine uses FoundationModels macros, which need the full
# Xcode toolchain (the Command Line Tools lack the macro plugin).
if [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release

DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi
APP="$DEST/Riffle.app"

# Quit a running copy before replacing it, and reap any whisper-server its
# death may have orphaned.
pkill -x Riffle 2>/dev/null || true
sleep 0.5
pkill -f 'whisper-server.*--port 12391' 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp bundle/Info.plist "$APP/Contents/Info.plist"
cp .build/release/Riffle "$APP/Contents/MacOS/Riffle"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Prefer a stable local signing identity so TCC grants (Accessibility)
# survive rebuilds. See README: create one with openssl + security import,
# named "Riffle Local Signing". Ad-hoc fallback changes identity every
# build, which strands the old grant on a stale System Settings row, so in
# that case we clear the entry to force a clean re-prompt.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Riffle Local Signing"; then
  codesign --force --sign "Riffle Local Signing" "$APP"
  echo "Installed $APP (signed: Riffle Local Signing, permissions persist)"
else
  codesign --force --sign - "$APP"
  tccutil reset Accessibility com.thriveadventures.riffle >/dev/null 2>&1 || true
  echo "Installed $APP (ad-hoc signed: re-grant Accessibility when prompted)"
fi
