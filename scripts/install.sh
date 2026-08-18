#!/usr/bin/env bash
# Installs the app to /Applications and forces macOS to pick up its icon.
#
# A fresh bundle very often shows the generic icon in the Dock and Finder even
# when the .icns is correct. The cause is icon caching in LaunchServices, not
# the bundle — so re-register it, bump the bundle's mtime, and restart the Dock.
set -euo pipefail

cd "$(dirname "$0")/.."

[ -d build/linuxonmac.app ] || ./scripts/build.sh

DEST="/Applications/linuxonmac.app"

echo "==> installing to $DEST"
rm -rf "$DEST"
cp -R build/linuxonmac.app "$DEST"

echo "==> refreshing icon caches"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$DEST" 2>/dev/null || true
touch "$DEST"
killall Dock 2>/dev/null || true

echo
echo "Installed. Launch it from Spotlight or /Applications, or run:"
echo "  open -a linuxonmac"
