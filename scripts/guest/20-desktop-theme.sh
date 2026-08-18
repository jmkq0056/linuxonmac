#!/usr/bin/env bash
#
# 20-desktop-theme.sh — Desktop look & feel for the Debian 13 / KDE Plasma 6 guest.
#
# Idempotent. Safe to re-run. Applies:
#   * Papirus (papirus-icon-theme)  icon theme, dark variant
#   * Bibata Modern Classic         cursor theme
#   * "Aurora Dark" color scheme    (generated here, not downloaded)
#   * Inter (UI) + JetBrains Mono (code, ligatures) + Symbols Nerd Font Mono (glyph fallback)
#   * HiDPI-correct font rendering  (grayscale AA + slight hinting)
#   * Generated wallpaper           (no network images)
#   * macOS-shaped panel layout     (top menu bar + floating bottom dock)
#   * Matching GTK + Konsole theming
#
# Everything is written with kwriteconfig6 / plasma-apply-* / the Plasma scripting
# API so that config files shared with other agents are edited key-by-key and
# never truncated.
#
# NOTE: this script deliberately does NOT touch:
#   kwinrc [Plugins] blurEnabled / contrastEnabled   (kept false — VM perf)
#   kdeglobals [KDE] AnimationDurationFactor         (kept 0 — VM perf)
#   kwinrc [Desktops] / input / shortcut settings    (owned elsewhere)
#
set -uo pipefail

# ----------------------------------------------------------------------------
# 0. Session environment (needed when running over SSH)
# ----------------------------------------------------------------------------
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
export LC_ALL=C.UTF-8

APT="sudo apt-get -o DPkg::Lock::Timeout=900"
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*"; }

# Names used throughout
COLORSCHEME="AuroraDark"
ICON_THEME="Papirus-Dark"
CURSOR_THEME="Bibata-Modern-Classic"
CURSOR_SIZE=24
PLASMA_THEME="breeze-dark"
UI_FONT="Inter"
MONO_FONT="JetBrains Mono"
NERD_SYMBOLS="Symbols Nerd Font Mono"
WALL_NAME="Aurora"
WALL_W=2940
WALL_H=1912
NF_VERSION="v3.5.0"
NF_SHA256="49362450cd61b32c7d1dadbb98e82696d77cc215344636d25eabc8a82d6f8d7f"

# QFont serialisation used by Plasma 6:
# Family,pointSize,pixelSize,styleHint,weight,italic,underline,strikeOut,fixedPitch,...
qfont() { printf '%s,%s,-1,5,%s,0,0,0,0,0,0,0,0,0,0,1' "$1" "$2" "$3"; }

MODE="apply"
[ "${1:-}" = "--verify" ] && MODE="verify"

if [ "$MODE" = "apply" ]; then

# ----------------------------------------------------------------------------
# 1. Packages
# ----------------------------------------------------------------------------
step "Installing theme, cursor and font packages"
PKGS=(
  papirus-icon-theme        # complete icon theme (Papirus / -Dark / -Light)
  bibata-cursor-theme       # modern cursor set
  fonts-inter               # UI typeface
  fonts-jetbrains-mono      # monospace with programming ligatures
  fonts-firacode            # secondary ligature monospace
  fonts-powerline           # powerline glyph fallback
  fonts-font-awesome        # icon glyph fallback
  python3-pil               # wallpaper generation
  unzip curl
)
MISSING=()
for p in "${PKGS[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "^install ok installed$" || MISSING+=("$p")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  $APT update -qq >/dev/null 2>&1 || warn "apt update failed, continuing with cached lists"
  $APT install -y --no-install-recommends "${MISSING[@]}" || warn "some packages failed to install"
else
  ok "all packages already present"
fi

# ----------------------------------------------------------------------------
# 2. Symbols Nerd Font (glyph fallback for the terminal)
#
# Debian does not package Nerd Fonts. Rather than replacing JetBrains Mono with
# a patched build (which is what usually breaks ligatures), we install upstream's
# official "Symbols Only" font and let fontconfig use it as a fallback for the
# Nerd Font private-use ranges. JetBrains Mono keeps its full ligature set and
# the terminal still resolves every Nerd Font glyph.
# ----------------------------------------------------------------------------
step "Installing Symbols Nerd Font Mono (${NF_VERSION}, glyph fallback)"
NF_DIR=/usr/local/share/fonts/nerd-fonts
if [ -f "${NF_DIR}/SymbolsNerdFontMono-Regular.ttf" ] && [ -f /etc/fonts/conf.d/10-nerd-font-symbols.conf ]; then
  ok "already installed at ${NF_DIR}"
else
  TMP=$(mktemp -d)
  ZIP="${TMP}/NerdFontsSymbolsOnly.zip"
  URL="https://github.com/ryanoasis/nerd-fonts/releases/download/${NF_VERSION}/NerdFontsSymbolsOnly.zip"
  if curl -fsSL -m 180 -o "$ZIP" "$URL"; then
    GOT=$(sha256sum "$ZIP" | awk '{print $1}')
    if [ "$GOT" = "$NF_SHA256" ]; then
      unzip -o -q "$ZIP" -d "${TMP}/x"
      sudo install -d -m 0755 "$NF_DIR"
      sudo install -m 0644 "${TMP}/x/SymbolsNerdFontMono-Regular.ttf" "${TMP}/x/SymbolsNerdFont-Regular.ttf" "$NF_DIR/"
      sudo install -m 0644 "${TMP}/x/LICENSE" "${NF_DIR}/LICENSE"
      # upstream's own fontconfig rules: map the Nerd Font codepoint ranges to
      # the symbols font for every family
      sudo install -m 0644 "${TMP}/x/10-nerd-font-symbols.conf" /etc/fonts/conf.d/10-nerd-font-symbols.conf
      ok "installed ${NF_DIR} + /etc/fonts/conf.d/10-nerd-font-symbols.conf"
    else
      warn "sha256 mismatch (want ${NF_SHA256}, got ${GOT}) — NOT installing"
    fi
  else
    warn "download failed; terminal glyph coverage falls back to fonts-powerline/font-awesome"
  fi
  rm -rf "$TMP"
fi

# ----------------------------------------------------------------------------
# 3. Fontconfig: family defaults + HiDPI rendering
#
# Rendering rationale for this machine (2940x1912 framebuffer, Plasma scale 2):
#   antialias   = true      — always
#   hintstyle   = hintslight— vertical-only hinting; keeps Inter/JetBrains Mono
#                             shapes intact instead of snapping stems to a grid
#                             that a 2x logical pixel doesn't need
#   rgba        = none      — GRAYSCALE antialiasing, not subpixel. The guest
#                             renders into a virtual framebuffer that
#                             Virtualization.framework then composites onto the
#                             Mac's panel; the physical subpixel order is not
#                             preserved through that path, so RGB subpixel AA
#                             would produce colour fringing. At 2x the extra
#                             resolution already does the work subpixel AA
#                             would have done.
#   lcdfilter   = lcddefault— harmless no-op while rgba=none, correct if changed
# ----------------------------------------------------------------------------
step "Writing fontconfig defaults (/etc/fonts/local.conf)"
sudo tee /etc/fonts/local.conf >/dev/null <<'FCEOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<!-- Managed by scripts/guest/20-desktop-theme.sh — regenerated on each run. -->
<fontconfig>

  <!-- ============ Generic family defaults ============ -->
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>Inter</family>
      <family>Noto Sans</family>
      <family>DejaVu Sans</family>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>

  <alias>
    <family>serif</family>
    <prefer>
      <family>Noto Serif</family>
      <family>DejaVu Serif</family>
    </prefer>
  </alias>

  <alias>
    <family>monospace</family>
    <prefer>
      <family>JetBrains Mono</family>
      <family>Symbols Nerd Font Mono</family>
      <family>Noto Sans Mono</family>
      <family>DejaVu Sans Mono</family>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>

  <alias>
    <family>system-ui</family>
    <prefer><family>Inter</family></prefer>
  </alias>

  <!-- Legacy/webfont names -> what we actually ship -->
  <match target="pattern"><test name="family"><string>Helvetica</string></test>
    <edit name="family" mode="assign" binding="same"><string>Inter</string></edit></match>
  <match target="pattern"><test name="family"><string>Helvetica Neue</string></test>
    <edit name="family" mode="assign" binding="same"><string>Inter</string></edit></match>
  <match target="pattern"><test name="family"><string>-apple-system</string></test>
    <edit name="family" mode="assign" binding="same"><string>Inter</string></edit></match>
  <match target="pattern"><test name="family"><string>SF Mono</string></test>
    <edit name="family" mode="assign" binding="same"><string>JetBrains Mono</string></edit></match>
  <match target="pattern"><test name="family"><string>Menlo</string></test>
    <edit name="family" mode="assign" binding="same"><string>JetBrains Mono</string></edit></match>
  <match target="pattern"><test name="family"><string>Monaco</string></test>
    <edit name="family" mode="assign" binding="same"><string>JetBrains Mono</string></edit></match>

  <!-- ============ HiDPI rendering ============ -->
  <match target="font">
    <edit name="antialias"  mode="assign"><bool>true</bool></edit>
    <edit name="hinting"    mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle"  mode="assign"><const>hintslight</const></edit>
    <edit name="rgba"       mode="assign"><const>none</const></edit>
    <edit name="lcdfilter"  mode="assign"><const>lcddefault</const></edit>
    <edit name="autohint"   mode="assign"><bool>false</bool></edit>
    <edit name="embeddedbitmap" mode="assign"><bool>false</bool></edit>
  </match>

  <!-- Emoji should never be substituted by a mono/text face -->
  <match target="pattern">
    <test name="family"><string>emoji</string></test>
    <edit name="family" mode="assign" binding="same"><string>Noto Color Emoji</string></edit>
  </match>

</fontconfig>
FCEOF
ok "/etc/fonts/local.conf written"

step "Rebuilding font caches (fc-cache -f)"
sudo fc-cache -f >/dev/null 2>&1 && ok "system font cache rebuilt"
fc-cache -f >/dev/null 2>&1 && ok "user font cache rebuilt"

# ----------------------------------------------------------------------------
# 4. "Aurora Dark" colour scheme
#
# Deliberate palette: cool graphite neutrals (not Breeze's blue-grey) with
# Apple's dark-mode system colours as the semantic accents — those are already
# contrast-tuned for dark backgrounds, which matters because this desktop is
# viewed on a Retina panel through a VM compositor.
# ----------------------------------------------------------------------------
step "Installing and applying the ${COLORSCHEME} colour scheme"
mkdir -p "${HOME}/.local/share/color-schemes"
cat > "${HOME}/.local/share/color-schemes/${COLORSCHEME}.colors" <<'COLEOF'
[General]
ColorScheme=AuroraDark
Name=Aurora Dark
shadeSortColumn=true
accentActiveTitlebar=false

[KDE]
contrast=4

[ColorEffects:Disabled]
ChangeSelectionColor=
Color=56,56,56
ColorAmount=0
ColorEffect=0
ContrastAmount=0.65
ContrastEffect=1
Enable=
IntensityAmount=0.1
IntensityEffect=2

[ColorEffects:Inactive]
ChangeSelectionColor=true
Color=112,111,110
ColorAmount=0.025
ColorEffect=2
ContrastAmount=0.1
ContrastEffect=2
Enable=false
IntensityAmount=0
IntensityEffect=0

[Colors:View]
BackgroundNormal=26,28,32
BackgroundAlternate=32,35,40
DecorationFocus=10,132,255
DecorationHover=10,132,255
ForegroundNormal=228,231,236
ForegroundInactive=145,152,163
ForegroundActive=10,132,255
ForegroundLink=100,210,255
ForegroundVisited=191,90,242
ForegroundNegative=255,105,97
ForegroundNeutral=255,159,10
ForegroundPositive=50,215,75

[Colors:Window]
BackgroundNormal=36,39,45
BackgroundAlternate=43,47,54
DecorationFocus=10,132,255
DecorationHover=10,132,255
ForegroundNormal=228,231,236
ForegroundInactive=145,152,163
ForegroundActive=10,132,255
ForegroundLink=100,210,255
ForegroundVisited=191,90,242
ForegroundNegative=255,105,97
ForegroundNeutral=255,159,10
ForegroundPositive=50,215,75

[Colors:Button]
BackgroundNormal=48,52,60
BackgroundAlternate=58,63,72
DecorationFocus=10,132,255
DecorationHover=10,132,255
ForegroundNormal=228,231,236
ForegroundInactive=145,152,163
ForegroundActive=10,132,255
ForegroundLink=100,210,255
ForegroundVisited=191,90,242
ForegroundNegative=255,105,97
ForegroundNeutral=255,159,10
ForegroundPositive=50,215,75

[Colors:Selection]
BackgroundNormal=10,132,255
BackgroundAlternate=8,110,214
DecorationFocus=10,132,255
DecorationHover=10,132,255
ForegroundNormal=255,255,255
ForegroundInactive=205,225,255
ForegroundActive=255,255,255
ForegroundLink=180,220,255
ForegroundVisited=220,180,250
ForegroundNegative=255,180,175
ForegroundNeutral=255,214,150
ForegroundPositive=170,240,180

[Colors:Tooltip]
BackgroundNormal=44,48,55
BackgroundAlternate=36,39,45
DecorationFocus=10,132,255
DecorationHover=10,132,255
ForegroundNormal=228,231,236
ForegroundInactive=145,152,163
ForegroundActive=10,132,255
ForegroundLink=100,210,255
ForegroundVisited=191,90,242
ForegroundNegative=255,105,97
ForegroundNeutral=255,159,10
ForegroundPositive=50,215,75

[Colors:Complementary]
BackgroundNormal=26,28,32
BackgroundAlternate=20,22,25
DecorationFocus=10,132,255
DecorationHover=10,132,255
ForegroundNormal=228,231,236
ForegroundInactive=145,152,163
ForegroundActive=10,132,255
ForegroundLink=100,210,255
ForegroundVisited=191,90,242
ForegroundNegative=255,105,97
ForegroundNeutral=255,159,10
ForegroundPositive=50,215,75

[Colors:Header]
BackgroundNormal=30,33,38
BackgroundAlternate=36,39,45
DecorationFocus=10,132,255
DecorationHover=10,132,255
ForegroundNormal=228,231,236
ForegroundInactive=145,152,163
ForegroundActive=10,132,255
ForegroundLink=100,210,255
ForegroundVisited=191,90,242
ForegroundNegative=255,105,97
ForegroundNeutral=255,159,10
ForegroundPositive=50,215,75

[Colors:Header][Inactive]
BackgroundNormal=26,28,32
BackgroundAlternate=30,33,38
DecorationFocus=10,132,255
DecorationHover=10,132,255
ForegroundNormal=170,177,187
ForegroundInactive=125,132,143
ForegroundActive=10,132,255
ForegroundLink=100,210,255
ForegroundVisited=191,90,242
ForegroundNegative=255,105,97
ForegroundNeutral=255,159,10
ForegroundPositive=50,215,75

[WM]
activeBackground=46,50,58
activeBlend=46,50,58
activeForeground=235,238,243
inactiveBackground=33,36,42
inactiveBlend=33,36,42
inactiveForeground=138,145,156
COLEOF

plasma-apply-colorscheme "${COLORSCHEME}" 2>&1 | sed 's/^/    /' || warn "plasma-apply-colorscheme failed"

# Explicit accent colour (Plasma 6). Pinned rather than derived from the
# wallpaper so the UI stays predictable.
kwriteconfig6 --file kdeglobals --group General --key accentColorFromWallpaper false
kwriteconfig6 --file kdeglobals --group General --key AccentColor "10,132,255"
kwriteconfig6 --file kdeglobals --group General --key LastUsedCustomAccentColor "10,132,255"
ok "accent pinned to #0A84FF"

# ----------------------------------------------------------------------------
# 5. Icons, cursor, widget style, Plasma style, window decorations
# ----------------------------------------------------------------------------
step "Icons / cursor / styles"
# Debian's papirus-icon-theme ships Papirus-Dark as a *small overlay* (only
# 16/18/22/24px actions, devices and places -- ~7.5k files) whose index.theme
# reads "Inherits=breeze-dark,hicolor". It therefore never reaches the full
# Papirus set (~86k files), and every app icon, mimetype icon and 32/48/64px
# icon silently falls back to Breeze. That is exactly the "half-installed set
# that falls back to generic icons" failure mode, and it is invisible unless
# you walk the inheritance chain.
#
# Fix: put Papirus into Papirus-Dark's inheritance chain. The dark-optimised
# small icons still win (they are found first), and everything else now comes
# from Papirus instead of Breeze.
PD_INDEX=/usr/share/icons/Papirus-Dark/index.theme
if [ -f "$PD_INDEX" ]; then
  CUR_INH=$(sed -n 's/^Inherits=//p' "$PD_INDEX" | head -1)
  case ",${CUR_INH}," in
    *,Papirus,*)
      ok "Papirus-Dark already inherits Papirus (${CUR_INH})" ;;
    *)
      [ -f "${PD_INDEX}.orig" ] || sudo cp -a "$PD_INDEX" "${PD_INDEX}.orig"
      sudo sed -i "s|^Inherits=.*|Inherits=Papirus,${CUR_INH}|" "$PD_INDEX"
      ok "Papirus-Dark Inherits: ${CUR_INH} -> $(sed -n 's/^Inherits=//p' "$PD_INDEX" | head -1)"
      warn "this edits a dpkg-owned file; a papirus-icon-theme upgrade reverts it — re-run this script"
      ;;
  esac
  # Refresh the icon caches so the new chain is picked up.
  for t in Papirus Papirus-Dark; do
    [ -d "/usr/share/icons/$t" ] && sudo gtk-update-icon-cache -qf "/usr/share/icons/$t" 2>/dev/null
  done
else
  warn "${PD_INDEX} not found"
fi

kwriteconfig6 --file kdeglobals --group Icons --key Theme "${ICON_THEME}"
ok "icon theme = ${ICON_THEME}"

kwriteconfig6 --file kcminputrc --group Mouse --key cursorTheme "${CURSOR_THEME}"
kwriteconfig6 --file kcminputrc --group Mouse --key cursorSize "${CURSOR_SIZE}"
# Make the cursor apply to Xwayland / GTK / non-KDE clients too
sudo install -d -m 0755 /usr/share/icons/default
sudo tee /usr/share/icons/default/index.theme >/dev/null <<CURSEOF
[Icon Theme]
Inherits=${CURSOR_THEME}
CURSEOF
ok "cursor theme = ${CURSOR_THEME} @ ${CURSOR_SIZE}px"

kwriteconfig6 --file kdeglobals --group KDE --key widgetStyle "Breeze"
kwriteconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage "org.kde.breezedark.desktop"
plasma-apply-desktoptheme "${PLASMA_THEME}" 2>&1 | sed 's/^/    /' || warn "plasma-apply-desktoptheme failed"
ok "widget style = Breeze, Plasma style = ${PLASMA_THEME}"

# Window decorations: Breeze, no border, macOS button order (close/min/max left).
kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key library "org.kde.breeze"
kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key theme "Breeze"
kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key BorderSize "None"
kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key BorderSizeAuto "false"
kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key ButtonsOnLeft "XIA"
kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key ButtonsOnRight ""
kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key ShowToolTips "false"
ok "decorations = Breeze, borderless, buttons on the left (close/min/max)"

# ----------------------------------------------------------------------------
# 6. Fonts in Plasma
# ----------------------------------------------------------------------------
step "Setting Plasma fonts"
kwriteconfig6 --file kdeglobals --group General --key font                 "$(qfont "${UI_FONT}"   10 400)"
kwriteconfig6 --file kdeglobals --group General --key menuFont             "$(qfont "${UI_FONT}"   10 400)"
kwriteconfig6 --file kdeglobals --group General --key toolBarFont          "$(qfont "${UI_FONT}"   10 400)"
kwriteconfig6 --file kdeglobals --group General --key smallestReadableFont "$(qfont "${UI_FONT}"    9 400)"
kwriteconfig6 --file kdeglobals --group General --key fixed                "$(qfont "${MONO_FONT}" 10 400)"
kwriteconfig6 --file kdeglobals --group WM      --key activeFont           "$(qfont "${UI_FONT}"   10 600)"
ok "UI = ${UI_FONT} 10, monospace = ${MONO_FONT} 10, titles = ${UI_FONT} 10 SemiBold"

step "Setting font rendering (HiDPI: grayscale AA + slight hinting)"
kwriteconfig6 --file kdeglobals --group General --key XftAntialias "true"
kwriteconfig6 --file kdeglobals --group General --key XftHintStyle "hintslight"
kwriteconfig6 --file kdeglobals --group General --key XftSubPixel  "none"
kwriteconfig6 --file kdeglobals --group General --key forceFontDPI "0"
ok "XftAntialias=true XftHintStyle=hintslight XftSubPixel=none forceFontDPI=0"

# ----------------------------------------------------------------------------
# 7. Wallpaper — generated locally, nothing downloaded
# ----------------------------------------------------------------------------
step "Generating the ${WALL_NAME} wallpaper (${WALL_W}x${WALL_H})"
WALL_DIR="${HOME}/.local/share/wallpapers/${WALL_NAME}"
WALL_IMG="${WALL_DIR}/contents/images/${WALL_W}x${WALL_H}.jpg"
mkdir -p "${WALL_DIR}/contents/images"
cat > "${WALL_DIR}/metadata.json" <<METAEOF
{
    "KPlugin": {
        "Authors": [{"Name": "linuxonmac 20-desktop-theme.sh"}],
        "Id": "${WALL_NAME}",
        "License": "CC0-1.0",
        "Name": "${WALL_NAME}"
    }
}
METAEOF

WALL_W="${WALL_W}" WALL_H="${WALL_H}" WALL_IMG="${WALL_IMG}" python3 - <<'PYEOF'
import math, os
from PIL import Image, ImageChops

OUT_W = int(os.environ["WALL_W"]); OUT_H = int(os.environ["WALL_H"])
OUT    = os.environ["WALL_IMG"]

# The image is pure smooth gradient, so it is computed on a small grid and
# resampled up: identical result, ~100x faster than 5.6M python-level pixels.
SW, SH = 368, 240
AR = SW / SH

def smooth(t):
    t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
    return t * t * (3.0 - 2.0 * t)

def lerp(a, b, t):
    return a + (b - a) * t

TOP = (18, 20, 26)   # #12141A
BOT = (9, 10, 13)    # #090A0D

# (cx, cy, radius, colour, strength) in normalised coords
GLOWS = (
    (0.20, 0.80, 0.68, (16,  78, 168), 0.90),   # deep blue, lower left
    (0.82, 0.16, 0.58, (58,  38, 128), 0.55),   # indigo,    upper right
    (0.52, 0.55, 0.30, (10, 132, 255), 0.14),   # accent core, very subtle
)

img = Image.new("RGB", (SW, SH))
px  = img.load()
for y in range(SH):
    v = y / (SH - 1)
    sv = smooth(v)
    br, bg, bb = (lerp(TOP[i], BOT[i], sv) for i in range(3))
    dy_c = v - 0.5
    for x in range(SW):
        u = x / (SW - 1)
        r, g, b = br, bg, bb
        for cx, cy, rad, col, st in GLOWS:
            dx = (u - cx) * AR
            dy = v - cy
            f = smooth(1.0 - math.sqrt(dx * dx + dy * dy) / rad)
            f = f * f * st
            r += col[0] * f; g += col[1] * f; b += col[2] * f
        dx_c = (u - 0.5) * AR
        vig = 1.0 - 0.32 * smooth(math.sqrt(dx_c * dx_c + dy_c * dy_c) / 0.95)
        px[x, y] = (
            min(255, max(0, int(r * vig))),
            min(255, max(0, int(g * vig))),
            min(255, max(0, int(b * vig))),
        )

big = img.resize((OUT_W, OUT_H), Image.LANCZOS)

# +/-3 level grain: kills the banding a 16-step dark gradient would otherwise
# show on a Retina panel, and gives the flat areas a little texture.
noise  = Image.frombytes("L", (OUT_W, OUT_H), os.urandom(OUT_W * OUT_H))
grain  = noise.point(lambda v: v >> 5)                 # 0..7
grain3 = Image.merge("RGB", (grain, grain, grain))
big    = ImageChops.add(big, grain3, scale=1, offset=-3)

# 4:4:4 chroma — 4:2:0 smears the blue glow edges.
big.save(OUT, "JPEG", quality=95, subsampling=0, optimize=True, progressive=True)
print("    wrote %s (%d bytes)" % (OUT, os.path.getsize(OUT)))
PYEOF

if [ -f "$WALL_IMG" ]; then
  plasma-apply-wallpaperimage "$WALL_DIR" 2>&1 | sed 's/^/    /' \
    || plasma-apply-wallpaperimage "$WALL_IMG" 2>&1 | sed 's/^/    /' \
    || warn "could not apply wallpaper"
  # Lock screen uses the same image
  kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper \
      --group org.kde.image --group General --key Image "$WALL_IMG"
  ok "wallpaper applied to desktop + lock screen"
else
  warn "wallpaper generation failed"
fi

# ----------------------------------------------------------------------------
# 8. Panel layout — macOS shaped, built through the Plasma scripting API so it
#    applies live (no logout) and never truncates the shared appletsrc by hand.
#
#    Top:    always-visible menu bar — launcher, global menu, tray, clock
#    Bottom: floating dock, fits its content, gets out of the way of windows
# ----------------------------------------------------------------------------
step "Rebuilding panels (top menu bar + floating dock)"

# Pre-flight: only touch panels if plasmashell answers promptly. Driving the
# Plasma scripting API against an unresponsive shell is how you end up with a
# half-built layout and a wedged plasmashell.
if ! timeout 20 gdbus call --session --dest org.kde.plasmashell \
       --object-path /PlasmaShell --method org.kde.PlasmaShell.evaluateScript \
       --timeout 15 'print("ok")' >/dev/null 2>&1; then
  warn "plasmashell is not answering evaluateScript — SKIPPING the panel rebuild."
  warn "Re-run this script once the shell is healthy; everything else is applied."
else
  cp -a "${HOME}/.config/plasma-org.kde.plasma.desktop-appletsrc" \
        "${HOME}/.config/plasma-org.kde.plasma.desktop-appletsrc.bak.$(date +%s)" 2>/dev/null || true

  # Run the layout in one evaluateScript, but through gdbus with a long
  # explicit timeout. qdbus6 uses libdbus' 25 s default, which is shorter than
  # the time plasmashell needs to instantiate this many QML applets on a
  # software-rendered VM — the call then "fails" while the shell is still
  # building, and a second attempt races the first.
  #
  # NOTE: org.kde.plasma.appmenu (the macOS-style global menu) is deliberately
  # NOT added. Its applet performs a blocking DBus registration against kded's
  # appmenu module; when that module is slow or absent, plasmashell blocks in
  # request_wait_answer and the whole shell wedges. The top bar keeps the
  # macOS *shape* without that failure mode.
  PANEL_JS=$(mktemp)
  cat > "$PANEL_JS" <<'JSEOF'
var log = [];

// tear down whatever is there — this is what makes the script idempotent
var existing = panelIds;
for (var i = 0; i < existing.length; i++) {
    try { panelById(existing[i]).remove(); } catch (e) { log.push("remove: " + e); }
}

// ---- bottom dock (built first: it is the simplest, so if anything goes
// ---- wrong the user is still left with a usable launcher surface) --------
var dock = new Panel("org.kde.panel");
dock.location   = "bottom";
dock.height     = 56;
dock.floating   = true;
dock.lengthMode = "fit";        // shrink-wraps to its icons, like a Dock
dock.alignment  = "center";
dock.currentConfigGroup = ["General"];
dock.writeConfig("panelOpacity", 1);   // opaque — blur stays off for VM perf

// Give the bottom of a 801pt-tall logical desktop back to maximised windows.
var hid = ["dodgewindows", "windowscover", "none"];
for (var h = 0; h < hid.length; h++) {
    try { dock.hiding = hid[h]; if (dock.hiding === hid[h]) break; } catch (e) {}
}

var tasks = dock.addWidget("org.kde.plasma.icontasks");
tasks.currentConfigGroup = ["General"];
tasks.writeConfig("launchers", [
    "applications:org.kde.dolphin.desktop",
    "applications:firefox-esr.desktop",
    "applications:org.kde.konsole.desktop",
    "applications:org.kde.kate.desktop",
    "applications:org.kde.spectacle.desktop",
    "applications:org.kde.discover.desktop",
    "applications:systemsettings.desktop"
].join(","));
tasks.writeConfig("showOnlyCurrentDesktop",  false);
tasks.writeConfig("showOnlyCurrentScreen",   false);
tasks.writeConfig("showOnlyCurrentActivity", false);
tasks.writeConfig("groupingStrategy", 1);
tasks.writeConfig("maxStripes", 1);
tasks.writeConfig("iconSpacing", 2);
tasks.writeConfig("indicateAudioStreams", true);
tasks.writeConfig("wheelEnabled", false);

// ---- top menu bar --------------------------------------------------------
var bar = new Panel("org.kde.panel");
bar.location   = "top";
bar.height     = 32;
bar.floating   = false;         // edge-to-edge, like a menu bar
bar.lengthMode = "fill";
bar.alignment  = "center";
bar.hiding     = "none";        // always visible
bar.currentConfigGroup = ["General"];
bar.writeConfig("panelOpacity", 1);

var kick = bar.addWidget("org.kde.plasma.kickoff");
kick.currentConfigGroup = ["General"];
kick.writeConfig("icon", "start-here-kde");
kick.writeConfig("compactDisplayStyle", "icon");

var spacer = bar.addWidget("org.kde.plasma.panelspacer");
spacer.currentConfigGroup = ["General"];
spacer.writeConfig("expanding", true);

bar.addWidget("org.kde.plasma.systemtray");

var clock = bar.addWidget("org.kde.plasma.digitalclock");
clock.currentConfigGroup = ["Appearance"];
clock.writeConfig("showDate", true);
clock.writeConfig("dateDisplayFormat", 1);     // date beside the time
clock.writeConfig("dateFormat", "custom");
clock.writeConfig("customDateFormat", "ddd d MMM");
clock.writeConfig("use24hFormat", 2);          // follow locale
clock.writeConfig("fontWeight", 500);
clock.writeConfig("showSeconds", 0);

bar.addWidget("org.kde.plasma.showdesktop");   // top-right corner

// ---- report --------------------------------------------------------------
for (var i = 0; i < panelIds.length; i++) {
    var p = panelById(panelIds[i]);
    log.push("panel id=" + p.id + " loc=" + p.location + " h=" + p.height +
             " len=" + p.lengthMode + " float=" + p.floating +
             " hiding=" + p.hiding + " widgets=[" + p.widgetIds + "]");
}
print(log.join("\n"));
JSEOF

  PANEL_OUT=$(timeout 180 gdbus call --session --dest org.kde.plasmashell \
      --object-path /PlasmaShell --method org.kde.PlasmaShell.evaluateScript \
      --timeout 150 "$(cat "$PANEL_JS")" 2>&1)
  printf '%s\n' "$PANEL_OUT" | sed 's/^/    /'
  rm -f "$PANEL_JS"
  # Deliberately NO plasmashell restart here. Restarting the shell tears down
  # every Wayland surface it owns at once, and on this VM that has been enough
  # to take the compositor down with it.
fi

# ----------------------------------------------------------------------------
# 9. GTK applications should match
# ----------------------------------------------------------------------------
step "Theming GTK 3 / GTK 4 applications"
GTK_THEME="Breeze-Dark"
[ -d /usr/share/themes/Breeze-Dark ] || GTK_THEME="Breeze"
for v in 3.0 4.0; do
  mkdir -p "${HOME}/.config/gtk-${v}"
  cat > "${HOME}/.config/gtk-${v}/settings.ini" <<GTKEOF
[Settings]
gtk-theme-name=${GTK_THEME}
gtk-icon-theme-name=${ICON_THEME}
gtk-font-name=${UI_FONT} 10
gtk-cursor-theme-name=${CURSOR_THEME}
gtk-cursor-theme-size=${CURSOR_SIZE}
gtk-application-prefer-dark-theme=1
gtk-enable-animations=0
gtk-xft-antialias=1
gtk-xft-hinting=1
gtk-xft-hintstyle=hintslight
gtk-xft-rgba=none
gtk-decoration-layout=close,minimize,maximize:
GTKEOF
done
ok "gtk-3.0/gtk-4.0 settings.ini -> ${GTK_THEME} + ${ICON_THEME}"

if gsettings list-schemas 2>/dev/null | grep -qx "org.gnome.desktop.interface"; then
  gsettings set org.gnome.desktop.interface color-scheme          'prefer-dark'
  gsettings set org.gnome.desktop.interface gtk-theme             "${GTK_THEME}"
  gsettings set org.gnome.desktop.interface icon-theme            "${ICON_THEME}"
  gsettings set org.gnome.desktop.interface cursor-theme          "${CURSOR_THEME}"
  gsettings set org.gnome.desktop.interface cursor-size           "${CURSOR_SIZE}"
  gsettings set org.gnome.desktop.interface font-name             "${UI_FONT} 10"
  gsettings set org.gnome.desktop.interface monospace-font-name   "${MONO_FONT} 10"
  gsettings set org.gnome.desktop.interface font-antialiasing     'grayscale'
  gsettings set org.gnome.desktop.interface font-hinting          'slight'
  gsettings set org.gnome.desktop.wm.preferences button-layout    'close,minimize,maximize:' 2>/dev/null || true
  ok "gsettings (org.gnome.desktop.interface) updated"
else
  warn "org.gnome.desktop.interface schema absent — settings.ini only"
fi

# ----------------------------------------------------------------------------
# 10. Konsole — monospace + Nerd Font glyphs + matching colours
# ----------------------------------------------------------------------------
step "Configuring Konsole (${MONO_FONT} + Nerd Font glyph fallback)"
mkdir -p "${HOME}/.local/share/konsole"
cat > "${HOME}/.local/share/konsole/AuroraDark.colorscheme" <<'KCSEOF'
[Background]
Color=26,28,32
[BackgroundFaint]
Color=26,28,32
[BackgroundIntense]
Color=26,28,32
[Color0]
Color=45,49,57
[Color0Faint]
Color=36,39,45
[Color0Intense]
Color=90,97,110
[Color1]
Color=255,105,97
[Color1Faint]
Color=190,74,68
[Color1Intense]
Color=255,141,133
[Color2]
Color=50,215,75
[Color2Faint]
Color=38,160,56
[Color2Intense]
Color=108,232,124
[Color3]
Color=255,190,60
[Color3Faint]
Color=196,145,44
[Color3Intense]
Color=255,214,110
[Color4]
Color=10,132,255
[Color4Faint]
Color=12,100,190
[Color4Intense]
Color=90,170,255
[Color5]
Color=191,90,242
[Color5Faint]
Color=145,68,184
[Color5Intense]
Color=214,140,250
[Color6]
Color=100,210,255
[Color6Faint]
Color=72,158,192
[Color6Intense]
Color=150,228,255
[Color7]
Color=207,213,222
[Color7Faint]
Color=158,164,173
[Color7Intense]
Color=245,247,250
[Foreground]
Color=228,231,236
[ForegroundFaint]
Color=170,177,187
[ForegroundIntense]
Color=255,255,255
[General]
Blur=false
ColorRandomization=false
Description=Aurora Dark
Opacity=1
Wallpaper=
KCSEOF

cat > "${HOME}/.local/share/konsole/Aurora.profile" <<KPEOF
[Appearance]
ColorScheme=AuroraDark
Font=$(qfont "${MONO_FONT}" 11 400)
UseFontLineChararacters=true

[Cursor Options]
CursorShape=0

[General]
Name=Aurora
Parent=FALLBACK/
TerminalCenter=false
TerminalMargin=10

[Interaction Options]
AutoCopySelectedText=false
TrimLeadingSpacesInSelectedText=true
TrimTrailingSpacesInSelectedText=true
UnderlineFilesEnabled=true

[Scrolling]
HistoryMode=2
ScrollBarPosition=2

[Terminal Features]
BlinkingCursorEnabled=false
KPEOF
kwriteconfig6 --file konsolerc --group "Desktop Entry" --key DefaultProfile "Aurora.profile"
kwriteconfig6 --file konsolerc --group KonsoleWindow  --key RememberWindowSize false
ok "Konsole profile 'Aurora' + colour scheme installed and set as default"

# ----------------------------------------------------------------------------
# 11. Push the changes to the running session
# ----------------------------------------------------------------------------
step "Reloading the running session"
dbus-send --session --dest=org.kde.KWin --type=method_call /KWin org.kde.KWin.reconfigure 2>/dev/null \
  && ok "kwin reconfigured"
# KGlobalSettings::notifyChange -> 0 Palette, 1 Font, 2 Style, 3 Settings, 4 Icon, 5 Cursor
for t in 0 1 2 3 4 5; do
  dbus-send --session --type=signal /KGlobalSettings org.kde.KGlobalSettings.notifyChange \
      int32:$t int32:0 2>/dev/null
done
ok "KGlobalSettings change signals sent (palette/font/style/settings/icons/cursor)"

fi   # end of apply mode

# ----------------------------------------------------------------------------
# 12. Verification — everything below only reads state back
# ----------------------------------------------------------------------------
printf '\n\033[1;35m==================== VERIFICATION ====================\033[0m\n'

printf '\n\033[1m-- Plasma settings read back (kreadconfig6) --\033[0m\n'
printf '%-42s %s\n' "kdeglobals/Icons/Theme"            "$(kreadconfig6 --file kdeglobals --group Icons --key Theme)"
printf '%-42s %s\n' "kdeglobals/General/ColorScheme"    "$(kreadconfig6 --file kdeglobals --group General --key ColorScheme)"
printf '%-42s %s\n' "kdeglobals/General/AccentColor"    "$(kreadconfig6 --file kdeglobals --group General --key AccentColor)"
printf '%-42s %s\n' "kdeglobals/General/accentFromWall" "$(kreadconfig6 --file kdeglobals --group General --key accentColorFromWallpaper)"
printf '%-42s %s\n' "kdeglobals/KDE/widgetStyle"        "$(kreadconfig6 --file kdeglobals --group KDE --key widgetStyle)"
printf '%-42s %s\n' "kdeglobals/KDE/LookAndFeelPackage" "$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage)"
printf '%-42s %s\n' "kdeglobals/General/font"           "$(kreadconfig6 --file kdeglobals --group General --key font)"
printf '%-42s %s\n' "kdeglobals/General/fixed"          "$(kreadconfig6 --file kdeglobals --group General --key fixed)"
printf '%-42s %s\n' "kdeglobals/General/menuFont"       "$(kreadconfig6 --file kdeglobals --group General --key menuFont)"
printf '%-42s %s\n' "kdeglobals/General/toolBarFont"    "$(kreadconfig6 --file kdeglobals --group General --key toolBarFont)"
printf '%-42s %s\n' "kdeglobals/General/smallestReadable" "$(kreadconfig6 --file kdeglobals --group General --key smallestReadableFont)"
printf '%-42s %s\n' "kdeglobals/WM/activeFont"          "$(kreadconfig6 --file kdeglobals --group WM --key activeFont)"
printf '%-42s %s\n' "kdeglobals/General/XftAntialias"   "$(kreadconfig6 --file kdeglobals --group General --key XftAntialias)"
printf '%-42s %s\n' "kdeglobals/General/XftHintStyle"   "$(kreadconfig6 --file kdeglobals --group General --key XftHintStyle)"
printf '%-42s %s\n' "kdeglobals/General/XftSubPixel"    "$(kreadconfig6 --file kdeglobals --group General --key XftSubPixel)"
printf '%-42s %s\n' "kdeglobals/General/forceFontDPI"   "$(kreadconfig6 --file kdeglobals --group General --key forceFontDPI)"
printf '%-42s %s\n' "kcminputrc/Mouse/cursorTheme"      "$(kreadconfig6 --file kcminputrc --group Mouse --key cursorTheme)"
printf '%-42s %s\n' "kcminputrc/Mouse/cursorSize"       "$(kreadconfig6 --file kcminputrc --group Mouse --key cursorSize)"
printf '%-42s %s\n' "plasmarc/Theme/name"               "$(kreadconfig6 --file plasmarc --group Theme --key name)"
printf '%-42s %s\n' "kwinrc/decoration/theme"           "$(kreadconfig6 --file kwinrc --group org.kde.kdecoration2 --key theme)"
printf '%-42s %s\n' "kwinrc/decoration/ButtonsOnLeft"   "$(kreadconfig6 --file kwinrc --group org.kde.kdecoration2 --key ButtonsOnLeft)"
printf '%-42s %s\n' "kwinrc/decoration/ButtonsOnRight"  "'$(kreadconfig6 --file kwinrc --group org.kde.kdecoration2 --key ButtonsOnRight)'"
printf '%-42s %s\n' "kwinrc/decoration/BorderSize"      "$(kreadconfig6 --file kwinrc --group org.kde.kdecoration2 --key BorderSize)"
printf '%-42s %s\n' "konsolerc/DefaultProfile"          "$(kreadconfig6 --file konsolerc --group 'Desktop Entry' --key DefaultProfile)"

printf '\n\033[1m-- Performance guards (must stay as-is) --\033[0m\n'
printf '%-42s %s\n' "kwinrc/Plugins/blurEnabled"        "$(kreadconfig6 --file kwinrc --group Plugins --key blurEnabled)"
printf '%-42s %s\n' "kwinrc/Plugins/contrastEnabled"    "$(kreadconfig6 --file kwinrc --group Plugins --key contrastEnabled)"
printf '%-42s %s\n' "kdeglobals/KDE/AnimationDuration"  "$(kreadconfig6 --file kdeglobals --group KDE --key AnimationDurationFactor)"

printf '\n\033[1m-- Icon theme on disk --\033[0m\n'
for t in Papirus Papirus-Dark; do
  if [ -d "/usr/share/icons/$t" ]; then
    n=$(find "/usr/share/icons/$t" \( -type f -o -type l \) 2>/dev/null | wc -l)
    printf '  %-16s %8s files   index.theme: %s\n' "$t" "$n" "$( [ -f /usr/share/icons/$t/index.theme ] && echo yes || echo NO )"
  else
    printf '  %-16s MISSING\n' "$t"
  fi
done
printf '  Papirus-Dark Inherits = %s\n' "$(sed -n 's/^Inherits=//p' /usr/share/icons/Papirus-Dark/index.theme 2>/dev/null | head -1)"
case ",$(sed -n 's/^Inherits=//p' /usr/share/icons/Papirus-Dark/index.theme 2>/dev/null | head -1)," in
  *,Papirus,*) printf '  \033[1;32mOK\033[0m full Papirus set is in the chain\n' ;;
  *)           printf '  \033[1;31mFAIL\033[0m Papirus is NOT in the chain — icons fall back to Breeze\n' ;;
esac
printf '  per-category counts (Papirus, 48px):\n'
for c in apps places mimetypes devices actions status categories emblems panel; do
  n=$(find /usr/share/icons/Papirus/48x48/$c /usr/share/icons/Papirus/48x48@2x/$c -mindepth 1 2>/dev/null | wc -l)
  printf '    %-12s %6s\n' "$c" "$n"
done

printf '\n\033[1m-- Icon coverage probe (resolved through the real icon loader) --\033[0m\n'
python3 - <<'PYV' 2>/dev/null || echo "  (python probe unavailable — see file test below)"
import configparser, os
THEME = "Papirus-Dark"
ROOTS = ["/usr/share/icons", os.path.expanduser("~/.local/share/icons")]

def load(theme, seen=None):
    seen = seen if seen is not None else []
    if theme in seen: return seen
    seen.append(theme)
    for r in ROOTS:
        idx = os.path.join(r, theme, "index.theme")
        if os.path.exists(idx):
            cp = configparser.RawConfigParser(strict=False)
            cp.read(idx)
            inh = cp.get("Icon Theme", "Inherits", fallback="")
            for p in [x.strip() for x in inh.split(",") if x.strip()]:
                load(p, seen)
            break
    return seen

chain = load(THEME)
print("  inheritance chain: " + " -> ".join(chain))

def find(name):
    for th in chain:
        for r in ROOTS:
            base = os.path.join(r, th)
            if not os.path.isdir(base): continue
            for dirpath, dirnames, filenames in os.walk(base):
                for ext in (".svg", ".png", ".xpm"):
                    if name + ext in filenames:
                        return th, os.path.join(dirpath, name + ext)
    return None, None

NAMES = ["folder","folder-download","folder-documents","user-home","user-trash",
         "text-x-generic","text-x-python","application-pdf","video-x-generic",
         "audio-x-generic","image-x-generic","text-html","application-zip",
         "drive-harddisk","drive-removable-media","media-optical","network-wired",
         "edit-copy","edit-paste","document-save","go-previous","list-add",
         "dialog-warning","dialog-error","dialog-information","view-refresh",
         "battery-full","network-wireless-connected-100","audio-volume-high",
         "system-shutdown","preferences-system","applications-graphics",
         "firefox","org.kde.dolphin","org.kde.konsole","org.kde.kate",
         "systemsettings","org.kde.discover","org.kde.spectacle","utilities-terminal",
         "start-here-kde-symbolic","preferences-desktop-theme","emblem-symbolic-link"]
miss = []
for n in NAMES:
    th, path = find(n)
    if th is None: miss.append(n)
print("  probed %d common icon names: %d resolved, %d missing" % (len(NAMES), len(NAMES)-len(miss), len(miss)))
if miss: print("  MISSING: " + ", ".join(miss))
PYV

printf '\n\033[1m-- Cursor theme on disk --\033[0m\n'
CT="$(kreadconfig6 --file kcminputrc --group Mouse --key cursorTheme)"
if [ -d "/usr/share/icons/${CT}/cursors" ]; then
  printf '  /usr/share/icons/%s/cursors : %s cursors\n' "$CT" "$(ls /usr/share/icons/${CT}/cursors | wc -l)"
  printf '  key shapes present: '
  for c in left_ptr xterm text watch wait hand2 pointer fleur size_all \
           sb_h_double_arrow sb_v_double_arrow crosshair question_arrow \
           not-allowed dnd-move top_left_corner; do
    [ -e "/usr/share/icons/${CT}/cursors/$c" ] && printf '%s ' "$c" || printf '!%s ' "$c"
  done; echo
else
  printf '  MISSING /usr/share/icons/%s/cursors\n' "$CT"
fi
printf '  /usr/share/icons/default/index.theme -> %s\n' "$(sed -n 's/^Inherits=//p' /usr/share/icons/default/index.theme 2>/dev/null)"

printf '\n\033[1m-- Fonts registered (fc-list / fc-match) --\033[0m\n'
for f in "Inter" "JetBrains Mono" "Fira Code" "Symbols Nerd Font Mono" "Noto Color Emoji"; do
  printf '  %-26s %s faces\n' "$f" "$(fc-list "$f" 2>/dev/null | wc -l)"
done
printf '  fc-match sans-serif   -> %s\n' "$(fc-match sans-serif)"
printf '  fc-match monospace    -> %s\n' "$(fc-match monospace)"
printf '  fc-match system-ui    -> %s\n' "$(fc-match system-ui)"
printf '  fc-match Inter:bold   -> %s\n' "$(fc-match 'Inter:bold')"
printf '  Nerd glyph U+E0B0     -> %s\n' "$(fc-match -s 'monospace:charset=e0b0' 2>/dev/null | head -1)"
printf '  Nerd glyph U+F09B     -> %s\n' "$(fc-match -s 'monospace:charset=f09b' 2>/dev/null | head -1)"
printf '  ligature check (JetBrains Mono GSUB "liga"): %s\n' \
  "$(python3 -c "
import struct,sys,glob
p=glob.glob('/usr/share/fonts/**/JetBrainsMono-Regular.ttf',recursive=True)+glob.glob('/usr/share/fonts/**/JetBrainsMono*Regular*.ttf',recursive=True)
if not p: print('font file not found'); sys.exit()
d=open(p[0],'rb').read()
print('present' if b'liga' in d and b'GSUB' in d else 'ABSENT')
" 2>/dev/null)"
printf '  rendering: '
fc-match -v Inter 2>/dev/null | grep -E '^\s+(antialias|hintstyle|rgba|hinting):' | tr -d '\t' | tr '\n' ' '
echo

printf '\n\033[1m-- Colour scheme --\033[0m\n'
printf '  file: %s\n' "$(ls -l ${HOME}/.local/share/color-schemes/AuroraDark.colors 2>/dev/null | awk '{print $5" bytes  "$NF}')"
printf '  kdeglobals Window bg   = %s\n' "$(kreadconfig6 --file kdeglobals --group 'Colors:Window' --key BackgroundNormal)"
printf '  kdeglobals Window fg   = %s\n' "$(kreadconfig6 --file kdeglobals --group 'Colors:Window' --key ForegroundNormal)"
printf '  kdeglobals View bg     = %s\n' "$(kreadconfig6 --file kdeglobals --group 'Colors:View' --key BackgroundNormal)"
printf '  kdeglobals Selection   = %s\n' "$(kreadconfig6 --file kdeglobals --group 'Colors:Selection' --key BackgroundNormal)"
printf '  kdeglobals WM active   = %s\n' "$(kreadconfig6 --file kdeglobals --group WM --key activeBackground)"

printf '\n\033[1m-- Wallpaper --\033[0m\n'
WI="$(ls ${HOME}/.local/share/wallpapers/Aurora/contents/images/* 2>/dev/null | head -1)"
printf '  image: %s\n' "${WI:-MISSING}"
[ -n "$WI" ] && printf '  size : %s bytes\n' "$(stat -c %s "$WI")"
[ -n "$WI" ] && python3 -c "from PIL import Image;im=Image.open('$WI');print('  dims :',im.size,im.mode)" 2>/dev/null
printf '  desktop containment Image = %s\n' \
  "$(kreadconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --group Wallpaper --group org.kde.image --group General --key Image)"

printf '\n\033[1m-- Panels (live, via Plasma scripting API) --\033[0m\n'
timeout 60 gdbus call --session --dest org.kde.plasmashell --object-path /PlasmaShell \
  --method org.kde.PlasmaShell.evaluateScript --timeout 45 '
var o=[];
for (var i=0;i<panelIds.length;i++){var p=panelById(panelIds[i]);
o.push("  panel "+p.id+"  loc="+p.location+"  height="+p.height+"  lengthMode="+p.lengthMode+"  align="+p.alignment+"  floating="+p.floating+"  hiding="+p.hiding);
for (var j=0;j<p.widgetIds.length;j++){var w=p.widgetById(p.widgetIds[j]); o.push("      - "+w.type);}}
print(o.join("\n"));' 2>&1 | sed 's/^/ /' || echo "  (plasmashell not answering — panels not verifiable)" 

printf '\n\033[1m-- GTK --\033[0m\n'
grep -hE 'gtk-(theme|icon-theme|font|cursor-theme)-name|prefer-dark|rgba|hintstyle' "${HOME}/.config/gtk-3.0/settings.ini" 2>/dev/null | sed 's/^/  /'

printf '\n\033[1;35m======================================================\033[0m\n'
