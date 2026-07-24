#!/bin/bash
# Builds Riffle and installs it as /Applications/Riffle.app (falls back to
# ~/Applications if /Applications is not writable). Ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi
APP="$DEST/Riffle.app"

# Quit a running copy before replacing it.
pkill -x Riffle 2>/dev/null || true
sleep 0.5

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp bundle/Info.plist "$APP/Contents/Info.plist"
cp .build/release/Riffle "$APP/Contents/MacOS/Riffle"
codesign --force --sign - "$APP"

echo "Installed $APP"
echo "Note: after a rebuild, macOS may require re-granting Accessibility"
echo "(the ad-hoc signature changes with every build)."
