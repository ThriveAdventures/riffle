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
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

# The ad-hoc signature changes with every build, which strands the old
# Accessibility grant on a stale entry: the System Settings toggle looks on
# but the new binary is not trusted. Clear it so the app re-prompts cleanly.
tccutil reset Accessibility com.thriveadventures.riffle >/dev/null 2>&1 || true

echo "Installed $APP"
echo "Note: re-grant Accessibility when the app prompts (required after"
echo "every rebuild because the ad-hoc signature changes)."
