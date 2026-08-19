#!/usr/bin/env bash
# Squeezes the most out of a guest with no GPU.
#
# Virtualization.framework gives Linux guests a 2D virtio-gpu only — no virgl,
# no venus — so Mesa falls back to llvmpipe and every composited pixel is CPU
# work. Wayland compositing is itself OpenGL, so "we don't need 3D" does not
# help: the smoothness problem IS the missing 3D. What is left is doing less
# work per frame.
set -euo pipefail

CONF_DIR="$HOME/.config/environment.d"
mkdir -p "$CONF_DIR"

# Plasma's panel, menus and KRunner are QtQuick, which defaults to the OpenGL
# scene graph — llvmpipe emulating GL just to draw flat 2D interface. Qt's own
# software rasterizer skips the emulation entirely and is faster here.
cat > "$CONF_DIR/90-linuxonmac-graphics.conf" <<'ENV'
QT_QUICK_BACKEND=software
QSG_RENDER_LOOP=basic
LIBGL_ALWAYS_SOFTWARE=1
ENV

# Desktop scale back to 1: the host now hands the guest a half-resolution
# scanout and upscales it by exactly 2, so the guest must not scale again or the
# usable desktop collapses to 732x478.
#
# On Wayland the per-output scale is owned by kscreen, not kdeglobals — writing
# KScreen/ScaleFactor alone leaves the output at its old scale.
if command -v kscreen-doctor >/dev/null 2>&1; then
    kscreen-doctor output.Virtual-1.scale.1 >/dev/null 2>&1 || true
fi
kwriteconfig6 --file kdeglobals --group KScreen --key ScaleFactor 1 2>/dev/null || true

# Effects that cost per-pixel work have no business on a software rasterizer.
for key in blurEnabled contrastEnabled slidingpopupsEnabled kwin4_effect_fadeEnabled \
           kwin4_effect_translucencyEnabled magiclampEnabled wobblywindowsEnabled; do
    kwriteconfig6 --file kwinrc --group Plugins --key "$key" false 2>/dev/null || true
done
kwriteconfig6 --file kwinrc --group Compositing --key AnimationSpeed 0 2>/dev/null || true
kwriteconfig6 --file kdeglobals --group KDE --key AnimationDurationFactor 0

echo "graphics: QtQuick=software, scale=1, per-pixel effects off"
