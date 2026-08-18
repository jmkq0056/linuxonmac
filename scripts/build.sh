#!/usr/bin/env bash
# Builds linuxonmac.app and ad-hoc signs it with the virtualization entitlement.
# Virtualization.framework refuses to run without that entitlement, and the
# entitlement is only honoured on a signed binary — hence the codesign step.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/linuxonmac.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/linuxonmac"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/linuxonmac"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> codesign (ad-hoc, with entitlements)"
codesign --force --sign - \
    --entitlements Resources/linuxonmac.entitlements \
    "$APP"

codesign -d --entitlements - "$APP" 2>/dev/null | grep -q virtualization \
    && echo "==> entitlement present" \
    || { echo "!! virtualization entitlement missing" >&2; exit 1; }

echo
echo "Built $APP"
echo "Run it with:  ./scripts/run.sh   (or: open $APP)"
