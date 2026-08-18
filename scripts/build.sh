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

if [ ! -f Resources/AppIcon.icns ]; then
    echo "==> rendering icon"
    swift scripts/make-icon.swift
    iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/linuxonmac"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Signing has to come last. Adding a resource after signing invalidates the
# signature, and an invalid signature means the entitlement is ignored and the
# VM refuses to start.
echo "==> codesign (ad-hoc, with entitlements)"
codesign --force --sign - \
    --entitlements Resources/linuxonmac.entitlements \
    "$APP"

codesign -d --entitlements - "$APP" 2>/dev/null | grep -q virtualization \
    && echo "==> entitlement present" \
    || { echo "!! virtualization entitlement missing" >&2; exit 1; }

echo
echo "Built $APP"
echo "Install it with:  ./scripts/install.sh"
