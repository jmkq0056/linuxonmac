#!/usr/bin/env bash
#
# 71-visual-polish.sh — cross-toolkit visual coherence for the Debian 13 /
# KDE Plasma 6 (Wayland) guest.
#
# 20-desktop-theme.sh already owns the Plasma side of the look: Papirus-Dark
# icons, Breeze widgets, the AuroraDark colour scheme, the Aurora wallpaper,
# Inter / JetBrains Mono and the Bibata cursor. This script deliberately does
# NOT re-apply any of that. It closes the gaps that a Qt-only theming pass
# leaves behind:
#
#   1. GTK ↔ Qt parity that lives in GSettings, not in gtk-3.0/settings.ini.
#      On Wayland a GTK app resolves a setting as: xdg-desktop-portal Settings
#      -> org.gnome.desktop.* GSettings -> settings.ini. settings.ini is the
#      *lowest* priority source, so keys 20- wrote there are silently overruled
#      by stale GNOME defaults (Cantarell document font, text-only toolbars,
#      auto-hiding overlay scrollbars). Those are fixed here at the layer that
#      actually wins.
#   2. GTK file/print/app-chooser dialogs routed through xdg-desktop-portal to
#      the KDE (Breeze) implementations, so a GTK app's "Open File" is the same
#      dialog Dolphin and Kate show instead of a light-mode GTK one.
#   3. Firefox — the only substantial GTK app on this guest — pinned to a dark
#      chrome, dark content, portal dialogs, the system font pair and the same
#      "no cosmetic animation" policy the rest of the desktop runs under.
#   4. libadwaita colour tokens, so a GTK4 app installed later lands on the
#      AuroraDark palette instead of stock purple Adwaita.
#   5. Papirus-Dark's inheritance chain re-asserted (a papirus-icon-theme
#      upgrade reverts it) plus an icon-coverage audit.
#   6. A real user avatar, which the Kickoff header, the lock screen and the
#      SDDM greeter all currently render as a generic silhouette.
#   7. Lock screen / SDDM greeter framing and rendering pinned to match the
#      desktop (scale 1, software Qt Quick, no blur pass).
#   8. Notification, tooltip and dialog placement made deliberate for a single
#      1470x956 screen with a top panel and a bottom dock.
#
# Constraints honoured throughout:
#   * No GPU (llvmpipe). Nothing here enables blur, contrast, translucency or
#     any other per-pixel effect; where there is a choice, flat and opaque wins.
#   * Display is 1470x956 at scale 1. Nothing here assumes HiDPI, and the SDDM
#     HiDPI autoscaler is explicitly pinned off so the greeter matches.
#   * Shared config files (kdeglobals, kwinrc, plasmarc, kscreenlockerrc,
#     gtk-*/settings.ini) are only ever edited one key at a time with
#     kwriteconfig6. No shared file is rewritten wholesale.
#   * Every file this script owns outright lives under a 71-/linuxonmac- name
#     so it cannot collide with another agent's file.
#
# Idempotent. Safe to re-run. `--verify` reads everything back and changes
# nothing.
#
set -uo pipefail

# ----------------------------------------------------------------------------
# 0. Session environment (needed when this runs over SSH rather than from the
#    converge unit, which already has a session bus).
# ----------------------------------------------------------------------------
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
export LC_ALL=C.UTF-8

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m   %s\n' "$*"; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }

MODE="apply"
[ "${1:-}" = "--verify" ] && MODE="verify"

# Values taken from 20-desktop-theme.sh's AuroraDark scheme. They are read back
# from kdeglobals where possible so this script tracks the scheme rather than
# duplicating it; the literals are only the fallback if kdeglobals is missing.
kg() { kreadconfig6 --file kdeglobals --group "$1" --key "$2" 2>/dev/null; }
rgb2hex() { # "10,132,255" -> #0a84ff
    local IFS=,; set -- $1
    [ $# -eq 3 ] || { printf '%s' "$2"; return; }
    printf '#%02x%02x%02x' "$1" "$2" "$3"
}
hex_or() { local v; v="$(rgb2hex "$1")"; case "$v" in \#*) printf '%s' "$v";; *) printf '%s' "$2";; esac; }

ACCENT="$(hex_or "$(kg Colors:Selection BackgroundNormal)" '#0a84ff')"
WIN_BG="$(hex_or "$(kg Colors:Window BackgroundNormal)"    '#282c32')"
WIN_FG="$(hex_or "$(kg Colors:Window ForegroundNormal)"    '#e4e7ec')"
VIEW_BG="$(hex_or "$(kg Colors:View BackgroundNormal)"     '#1e2126')"
VIEW_FG="$(hex_or "$(kg Colors:View ForegroundNormal)"     '#dee2e8')"
HEAD_BG="$(hex_or "$(kg Colors:Header BackgroundNormal)"   '#1e2126')"
CARD_BG="$(hex_or "$(kg Colors:Window BackgroundAlternate)" '#2f333a')"
TIP_BG="$(hex_or  "$(kg Colors:Tooltip BackgroundNormal)"  '#2c3037')"
SIDE_BG="$(hex_or "$(kg Colors:Header BackgroundAlternate)" '#24272d')"
POSITIVE="$(hex_or "$(kg Colors:Window ForegroundPositive)" '#32d74b')"
NEGATIVE="$(hex_or "$(kg Colors:Window ForegroundNegative)" '#ff6961')"
NEUTRAL="$(hex_or  "$(kg Colors:Window ForegroundNeutral)"  '#ff9f0a')"
LINK="$(hex_or     "$(kg Colors:Window ForegroundLink)"     '#64d2ff')"

UI_FONT="Inter"
MONO_FONT="JetBrains Mono"
ICON_THEME="Papirus-Dark"
CURSOR_THEME="$(kreadconfig6 --file kcminputrc --group Mouse --key cursorTheme 2>/dev/null)"
[ -n "$CURSOR_THEME" ] || CURSOR_THEME="Bibata-Modern-Classic"
CURSOR_SIZE=24

AVATAR_SRC=/usr/local/share/linuxonmac/avatar-${USER}.png

# ============================================================================
# VERIFY
# ============================================================================
if [ "$MODE" = "verify" ]; then
    fails=0
    chk() { # chk <label> <actual> <expected>
        if [ "$2" = "$3" ]; then printf '  \033[1;32mOK  \033[0m %-46s %s\n' "$1" "$2"
        else printf '  \033[1;31mFAIL\033[0m %-46s %s (want %s)\n' "$1" "${2:-<unset>}" "$3"; fails=$((fails+1)); fi
    }
    note() { printf '       %-46s %s\n' "$1" "${2:-<unset>}"; }

    printf '\n\033[1m== 71-visual-polish verify ==\033[0m\n'

    printf '\n\033[1m-- icon theme chain --\033[0m\n'
    INH="$(sed -n 's/^Inherits=//p' /usr/share/icons/Papirus-Dark/index.theme 2>/dev/null | head -1)"
    case ",$INH," in
        *,Papirus,*) printf '  \033[1;32mOK  \033[0m %-46s %s\n' "Papirus-Dark Inherits" "$INH" ;;
        *)           printf '  \033[1;31mFAIL\033[0m %-46s %s\n' "Papirus-Dark Inherits" "${INH:-<none>}"; fails=$((fails+1)) ;;
    esac
    python3 - <<'PY'
import os, glob, configparser
ROOTS=[os.path.expanduser("~/.local/share/icons"),"/usr/share/icons","/usr/local/share/icons"]
def chain(t, seen=None):
    seen = seen if seen is not None else []
    if t in seen: return seen
    seen.append(t)
    for r in ROOTS:
        p=os.path.join(r,t,"index.theme")
        if os.path.exists(p):
            cp=configparser.RawConfigParser(strict=False); cp.read(p, encoding="utf-8")
            for x in [s.strip() for s in cp.get("Icon Theme","Inherits",fallback="").split(",") if s.strip()]:
                chain(x, seen)
            break
    return seen
c=chain("Papirus-Dark")
if "hicolor" not in c: c.append("hicolor")
names=set()
for t in c:
    for r in ROOTS:
        d=os.path.join(r,t)
        for dp,_,fn in (os.walk(d) if os.path.isdir(d) else []):
            for f in fn:
                if f.endswith((".png",".svg",".svgz",".xpm")): names.add(os.path.splitext(f)[0])
pixd="/usr/share/pixmaps"
pix={os.path.splitext(f)[0] for f in os.listdir(pixd)} if os.path.isdir(pixd) else set()
missing=[]
for d in ["/usr/share/applications", os.path.expanduser("~/.local/share/applications")]:
    for f in glob.glob(d+"/*.desktop"):
        cp=configparser.RawConfigParser(strict=False, interpolation=None)
        try: cp.read(f, encoding="utf-8")
        except Exception: continue
        if cp.get("Desktop Entry","NoDisplay",fallback="false").lower()=="true": continue
        ic=cp.get("Desktop Entry","Icon",fallback="")
        if not ic or ic.startswith("/") or ic in names or ic in pix: continue
        missing.append((ic, os.path.basename(f)))
print("       %-46s %s" % ("resolution chain", " -> ".join(c)))
if missing:
    print("  \033[1;31mFAIL\033[0m %-46s %d" % ("visible .desktop icons unresolved", len(missing)))
    for ic,f in sorted(missing)[:20]: print("         %-30s %s" % (ic,f))
else:
    print("  \033[1;32mOK  \033[0m %-46s 0" % "visible .desktop icons unresolved")
PY

    printf '\n\033[1m-- GTK: GSettings (highest-priority source on Wayland) --\033[0m\n'
    gs() { gsettings get org.gnome.desktop.interface "$1" 2>/dev/null | sed "s/^'//;s/'$//"; }
    gw() { gsettings get org.gnome.desktop.wm.preferences "$1" 2>/dev/null | sed "s/^'//;s/'$//"; }
    chk "interface color-scheme"       "$(gs color-scheme)"        "prefer-dark"
    chk "interface gtk-theme"          "$(gs gtk-theme)"           "Breeze-Dark"
    chk "interface icon-theme"         "$(gs icon-theme)"          "$ICON_THEME"
    chk "interface cursor-theme"       "$(gs cursor-theme)"        "$CURSOR_THEME"
    chk "interface font-name"          "$(gs font-name)"           "$UI_FONT 10"
    chk "interface document-font-name"  "$(gs document-font-name)"  "$UI_FONT 10"
    chk "interface monospace-font-name" "$(gs monospace-font-name)" "$MONO_FONT 10"
    chk "interface toolbar-style"      "$(gs toolbar-style)"       "both-horiz"
    chk "interface overlay-scrolling"  "$(gs overlay-scrolling)"   "false"
    chk "interface cursor-blink-time"  "$(gs cursor-blink-time)"   "1000"
    chk "interface enable-animations"  "$(gs enable-animations)"   "false"
    chk "wm titlebar-font"             "$(gw titlebar-font)"       "$UI_FONT Semi-Bold 10"

    printf '\n\033[1m-- GTK: settings.ini --\033[0m\n'
    for v in 3.0 4.0; do
        f="$HOME/.config/gtk-$v/settings.ini"
        for k in gtk-theme-name gtk-icon-theme-name gtk-font-name gtk-application-prefer-dark-theme \
                 gtk-dialogs-use-header gtk-overlay-scrolling gtk-cursor-blink-time; do
            note "gtk-$v $k" "$(kreadconfig6 --file "$f" --group Settings --key "$k" 2>/dev/null)"
        done
    done
    chk "gtk-2.0 theme" "$(sed -n 's/^gtk-theme-name="\(.*\)"/\1/p' "$HOME/.gtkrc-2.0" 2>/dev/null)" "Breeze-Dark"

    printf '\n\033[1m-- GTK: colour bridge --\033[0m\n'
    for v in 3.0 4.0; do
        n=$(grep -c '^@define-color' "$HOME/.config/gtk-$v/colors.css" 2>/dev/null || echo 0)
        note "gtk-$v colors.css definitions" "$n"
        if grep -q "linuxonmac-adwaita.css" "$HOME/.config/gtk-$v/gtk.css" 2>/dev/null; then
            printf '  \033[1;32mOK  \033[0m %-46s imported\n' "gtk-$v libadwaita token override"
        elif [ "$v" = "4.0" ]; then
            printf '  \033[1;31mFAIL\033[0m %-46s not imported\n' "gtk-$v libadwaita token override"; fails=$((fails+1))
        fi
    done
    note "gtk selection colour in colors.css" "$(sed -n 's/^@define-color theme_selected_bg_color_breeze //p' "$HOME/.config/gtk-3.0/colors.css" 2>/dev/null)"
    note "kdeglobals selection colour"        "$ACCENT;"

    printf '\n\033[1m-- GTK: live settings as a GTK app sees them --\033[0m\n'
    if command -v gtk-query-settings >/dev/null 2>&1; then
        GTKQ='(theme-name|icon-theme-name|font-name|application-prefer-dark-theme|cursor-theme-name|toolbar-style|overlay-scrolling|dialogs-use-header|enable-animations|decoration-layout|hint-font-metrics|cursor-blink-time|xft-dpi|xft-hintstyle|xft-rgba):'
        printf '       -- gtk3 (warnings here mean a bad settings.ini key) --\n'
        gtk-query-settings 2>&1 | grep -E "$GTKQ" | sed 's/^ */       /'
        gtk-query-settings 2>&1 >/dev/null | grep -i 'unknown key' | sed 's/^/  \033[1;31mFAIL\033[0m /' && fails=$((fails+1))
    else
        warn "gtk-query-settings not installed (libgtk-3-bin)"
    fi
    if command -v gtk4-query-settings >/dev/null 2>&1; then
        printf '       -- gtk4 --\n'
        gtk4-query-settings 2>&1 | grep -E "$GTKQ" | sed 's/^ */       /'
        gtk4-query-settings 2>&1 >/dev/null | grep -i 'unknown key' | sed 's/^/  \033[1;31mFAIL\033[0m /' && fails=$((fails+1))
    fi

    printf '\n\033[1m-- portals (GTK dialogs -> Breeze) --\033[0m\n'
    note "system preference file" "$(grep -h '^default=' /usr/share/xdg-desktop-portal/*-portals.conf 2>/dev/null | head -1)"
    note "Settings impl"         "$(grep -h '^org.freedesktop.impl.portal.Settings=' /usr/share/xdg-desktop-portal/*.conf 2>/dev/null | head -1)"
    FC="$(grep -h '^org.freedesktop.impl.portal.FileChooser=' /usr/share/xdg-desktop-portal/*.conf "$HOME/.config/xdg-desktop-portal/portals.conf" 2>/dev/null | head -1)"
    note "FileChooser impl" "${FC:-(none listed - falls through to default=kde)}"
    if pgrep -f 'xdg-desktop-portal-kde' >/dev/null; then
        printf '  \033[1;32mOK  \033[0m %-46s running\n' "xdg-desktop-portal-kde"
    else
        printf '  \033[1;31mFAIL\033[0m %-46s not running\n' "xdg-desktop-portal-kde"; fails=$((fails+1))
    fi
    chk "environment.d GTK_USE_PORTAL" "$(sed -n 's/^GTK_USE_PORTAL=//p' "$HOME/.config/environment.d/71-linuxonmac-visual.conf" 2>/dev/null)" "1"
    note "GTK_USE_PORTAL live in session" "$(systemctl --user show-environment 2>/dev/null | sed -n 's/^GTK_USE_PORTAL=//p')"
    if command -v gdbus >/dev/null 2>&1; then
        note "portal Settings color-scheme" "$(gdbus call --session -d org.freedesktop.portal.Desktop -o /org/freedesktop/portal/desktop \
            -m org.freedesktop.portal.Settings.Read org.freedesktop.appearance color-scheme 2>/dev/null)"
        note "portal Settings accent-color" "$(gdbus call --session -d org.freedesktop.portal.Desktop -o /org/freedesktop/portal/desktop \
            -m org.freedesktop.portal.Settings.Read org.freedesktop.appearance accent-color 2>/dev/null)"
    fi

    printf '\n\033[1m-- GTK file-dialog places --\033[0m\n'
    sed 's/^/       /' "$HOME/.config/gtk-3.0/bookmarks" 2>/dev/null || warn "no bookmarks file"

    printf '\n\033[1m-- Firefox --\033[0m\n'
    found=0
    for p in "$HOME"/.mozilla/firefox/*/; do
        [ -f "$p/user.js" ] || continue
        found=1
        printf '       %s\n' "${p#$HOME/}"
        grep -E 'toolbar-theme|content-theme|file-picker|sans-serif|prefersReducedMotion|overlay-scrollbars' "$p/user.js" | sed 's/^/         /'
    done
    [ "$found" = 1 ] || { printf '  \033[1;31mFAIL\033[0m %-46s\n' "no firefox profile has user.js"; fails=$((fails+1)); }

    printf '\n\033[1m-- avatar --\033[0m\n'
    note "generated source" "$( [ -f "$AVATAR_SRC" ] && echo "$AVATAR_SRC ($(stat -c%s "$AVATAR_SRC") bytes)" || echo missing )"
    note "~/.face.icon"     "$( [ -f "$HOME/.face.icon" ] && echo "present ($(stat -c%s "$HOME/.face.icon") bytes)" || echo missing )"
    note "AccountsService"  "$( [ -f "/var/lib/AccountsService/icons/$USER" ] && echo present || echo missing )"

    printf '\n\033[1m-- lock screen --\033[0m\n'
    lk() { kreadconfig6 --file kscreenlockerrc "$@" 2>/dev/null; }
    note "Greeter Theme"     "$(lk --group Greeter --key Theme)"
    note "Greeter wallpaper" "$(lk --group Greeter --group Wallpaper --group org.kde.image --group General --key Image)"
    chk  "Greeter FillMode"  "$(lk --group Greeter --group Wallpaper --group org.kde.image --group General --key FillMode)" "2"
    chk  "Greeter Blur"      "$(lk --group Greeter --group Wallpaper --group org.kde.image --group General --key Blur)"     "false"

    printf '\n\033[1m-- SDDM greeter --\033[0m\n'
    note "theme"            "$(grep -h '^Current=' /etc/sddm.conf.d/*.conf 2>/dev/null | head -1)"
    note "background"       "$(sed -n 's/^background=//p' /usr/share/sddm/themes/breeze/theme.conf.user 2>/dev/null)"
    note "greeter env"      "$(sed -n 's/^GreeterEnvironment=//p' /etc/sddm.conf.d/71-visual.conf 2>/dev/null)"
    note "Wayland HiDPI"    "$(sed -n '/^\[Wayland\]/,/^\[/{s/^EnableHiDPI=//p}' /etc/sddm.conf.d/71-visual.conf 2>/dev/null)"

    printf '\n\033[1m-- notifications / tooltips / dialogs --\033[0m\n'
    chk "plasmanotifyrc PopupPosition" "$(kreadconfig6 --file plasmanotifyrc --group Notifications --key PopupPosition 2>/dev/null)" "TopRight"
    note "plasmanotifyrc PopupTimeout" "$(kreadconfig6 --file plasmanotifyrc --group Notifications --key PopupTimeout 2>/dev/null)"
    note "plasmanotifyrc LowPriorityPopups" "$(kreadconfig6 --file plasmanotifyrc --group Notifications --key LowPriorityPopups 2>/dev/null)"
    note "plasmarc tooltip delay"      "$(kreadconfig6 --file plasmarc --group PlasmaToolTips --key Delay 2>/dev/null)"
    chk  "kwinrc Windows Placement"    "$(kreadconfig6 --file kwinrc --group Windows --key Placement 2>/dev/null)" "Centered"
    note "kdeglobals Tooltip bg"       "$(kg Colors:Tooltip BackgroundNormal)"
    note "gtk tooltip bg"              "$(sed -n 's/^@define-color tooltip_background_breeze //p' "$HOME/.config/gtk-3.0/colors.css" 2>/dev/null)"

    printf '\n\033[1m-- no-GPU guardrails (must all stay off) --\033[0m\n'
    for k in blurEnabled contrastEnabled kwin4_effect_translucencyEnabled; do
        chk "kwinrc Plugins $k" "$(kreadconfig6 --file kwinrc --group Plugins --key "$k" 2>/dev/null)" "false"
    done

    printf '\n'
    if [ "$fails" -eq 0 ]; then printf '\033[1;32mvisual polish: all checks passed\033[0m\n'
    else printf '\033[1;31mvisual polish: %d check(s) failed\033[0m\n' "$fails"; fi
    exit 0
fi

# ============================================================================
# APPLY
# ============================================================================
printf '\n\033[1m71-visual-polish.sh\033[0m — cross-toolkit coherence\n'

# ----------------------------------------------------------------------------
# 1. Icon theme: re-assert Papirus-Dark's inheritance, then audit coverage.
#
# Debian ships Papirus-Dark as a ~7.5k-file dark overlay whose index.theme
# inherits breeze-dark, not Papirus. Every icon the overlay does not carry —
# which is most app icons, every mimetype and every size above 24px — then
# falls through to Breeze and the desktop ends up half Papirus, half Breeze.
# 20-desktop-theme.sh patches this, but the file is dpkg-owned: any
# papirus-icon-theme upgrade silently reverts it. Re-asserting on every
# converge is the only thing that makes the fix survive.
# ----------------------------------------------------------------------------
step "Icon theme inheritance"
PD_INDEX=/usr/share/icons/Papirus-Dark/index.theme
if [ -f "$PD_INDEX" ]; then
    CUR_INH="$(sed -n 's/^Inherits=//p' "$PD_INDEX" | head -1)"
    case ",${CUR_INH}," in
        *,Papirus,*) ok "Papirus-Dark already inherits Papirus (${CUR_INH})" ;;
        *)
            sudo sed -i "s|^Inherits=.*|Inherits=Papirus,${CUR_INH}|" "$PD_INDEX"
            ok "re-asserted after package upgrade: Inherits=$(sed -n 's/^Inherits=//p' "$PD_INDEX" | head -1)"
            # Only rebuild the caches when the chain actually changed — a full
            # gtk-update-icon-cache over Papirus' ~86k files is minutes of CPU
            # on a guest that has collapsed under load before.
            for t in Papirus Papirus-Dark; do
                [ -d "/usr/share/icons/$t" ] && sudo nice -n 19 gtk-update-icon-cache -qf "/usr/share/icons/$t" 2>/dev/null
            done
            ok "icon caches rebuilt"
            ;;
    esac
else
    warn "Papirus-Dark not installed"
fi

# ----------------------------------------------------------------------------
# 2. GTK ↔ Qt parity, at the layer that actually decides.
#
# On Wayland GTK resolves settings in this order:
#     xdg-desktop-portal Settings  >  org.gnome.desktop.* GSettings  >  settings.ini
# settings.ini — the only place 20-desktop-theme.sh writes — is last. So the
# stock GNOME defaults in GSettings were quietly overruling it: Cantarell for
# document text, text-only toolbars where Breeze shows icon+text, GNOME's
# auto-hiding overlay scrollbars against Breeze's always-visible ones, a
# 1200ms caret blink against Qt's 1000ms, and an Adwaita Sans titlebar font.
# Each of those is a place a GTK window visibly stops matching a Qt window.
# ----------------------------------------------------------------------------
step "GTK settings via GSettings (the source Wayland actually reads)"
gset() { # gset <schema> <key> <value>
    if gsettings writable "$1" "$2" >/dev/null 2>&1; then
        gsettings set "$1" "$2" "$3" 2>/dev/null && info "$2 = $3"
    fi
}
IFACE=org.gnome.desktop.interface
WMP=org.gnome.desktop.wm.preferences
gset $IFACE color-scheme          'prefer-dark'
gset $IFACE gtk-theme             'Breeze-Dark'
gset $IFACE icon-theme            "$ICON_THEME"
gset $IFACE cursor-theme          "$CURSOR_THEME"
gset $IFACE cursor-size           "$CURSOR_SIZE"
gset $IFACE font-name             "$UI_FONT 10"
# Document text in GTK apps was Cantarell 11 — a font this guest does not even
# have styled anywhere else. Inter keeps prose in GTK apps matching Qt.
gset $IFACE document-font-name    "$UI_FONT 10"
gset $IFACE monospace-font-name   "$MONO_FONT 10"
# Breeze toolbars are icon + text beside; GTK's default here was text-only.
gset $IFACE toolbar-style         'both-horiz'
# Breeze scrollbars are always visible. GNOME's overlay scrollbars fade out and
# then reappear as a thin ghost, which is the single most obvious tell that a
# window is "the GTK one".
gset $IFACE overlay-scrolling     false
# Qt's caret blinks at 1000ms; GTK defaulted to 1200ms. Two text fields side by
# side blinking out of phase reads as sloppy.
gset $IFACE cursor-blink-time     1000
gset $IFACE enable-animations     false
gset $IFACE font-antialiasing     'grayscale'
gset $IFACE font-hinting          'slight'
gset $IFACE text-scaling-factor   1.0
# Matches kdeglobals [WM] activeFont (Inter, weight 600).
gset $WMP   titlebar-font         "$UI_FONT Semi-Bold 10"
gset $WMP   button-layout         'close,minimize,maximize:'
gset $WMP   titlebar-uses-system-font true
ok "GSettings aligned with kdeglobals"

# The same values in settings.ini, for GTK apps started outside the Wayland
# session (XWayland with no XSETTINGS reachable, or a bare `env -i` launch).
# kwriteconfig6 merges into the file key by key — kde-gtk-config rewrites this
# same file with KConfig at login, so this never truncates anyone's work.
step "GTK settings.ini (fallback layer)"
# GTK logs "Unknown key ..." to stderr for every property the running major
# version does not have, on every app launch, so the two versions get only the
# keys they actually understand.
for v in 3.0 4.0; do
    F="$HOME/.config/gtk-$v/settings.ini"
    mkdir -p "$(dirname "$F")"
    gini() { kwriteconfig6 --file "$F" --group Settings --key "$1" "$2" 2>/dev/null; }
    gdel() { kwriteconfig6 --file "$F" --group Settings --key "$1" --delete 2>/dev/null; }
    gini gtk-application-prefer-dark-theme 1
    gini gtk-enable-animations 0
    gini gtk-overlay-scrolling 0
    gini gtk-cursor-blink-time 1000
    # GNOME-style header bars put OK/Cancel in the titlebar; Breeze puts them in
    # a button box at the bottom. Requested here for the sake of GTK's own
    # built-in dialogs — note that GTK 3.24.49 / 4.18 on this guest report TRUE
    # regardless of what any settings.ini says, so this is a statement of
    # intent, not a working override. The dialogs that matter (file, print,
    # app chooser) are handled instead by routing them to the KDE portal below,
    # which is verifiable and does work.
    gini gtk-dialogs-use-header 0
    gini gtk-primary-button-warps-slider 1
    if [ "$v" = "3.0" ]; then
        # Icons in menus and on buttons: Breeze shows them, GTK3's modern
        # default does not. Both properties were removed in GTK4.
        gini gtk-menu-images 1
        gini gtk-button-images 1
        gdel gtk-hint-font-metrics
    else
        # Integer font metrics — correct at scale 1, and avoids the faint blur
        # subpixel glyph positioning gives you on a software rasteriser.
        # GTK4 only.
        gini gtk-hint-font-metrics 1
        gdel gtk-menu-images
        gdel gtk-button-images
    fi
    ok "gtk-$v/settings.ini merged"
done

# GTK2 is a single flat rc file, so it gets the same values written directly.
# 20-desktop-theme.sh writes ~/.gtkrc-2.0; only add what is missing.
GTKRC="$HOME/.gtkrc-2.0"
if [ -f "$GTKRC" ]; then
    grep -q '^gtk-toolbar-style' "$GTKRC" || echo 'gtk-toolbar-style=3' >> "$GTKRC"
    grep -q '^gtk-cursor-blink-time' "$GTKRC" || echo 'gtk-cursor-blink-time=1000' >> "$GTKRC"
    ok "gtkrc-2.0 topped up"
fi

# ----------------------------------------------------------------------------
# 3. libadwaita colour tokens.
#
# Breeze-Dark ships GTK2/3/4 stylesheets and kde-gtk-config keeps
# ~/.config/gtk-*/colors.css in sync with the AuroraDark scheme, so plain GTK
# apps already match exactly. libadwaita apps are the exception: they ignore
# gtk-theme-name entirely and hard-code their own palette, keyed off named
# colours. Nothing on this guest links libadwaita today, but almost every new
# GTK app does, so the override is written now rather than discovered later as
# a purple window in a blue desktop.
#
# Both spellings are emitted: @define-color for libadwaita <= 1.7 and the
# CSS custom properties 1.8+ switched to. Unknown properties are ignored by
# GTK's CSS parser, so carrying both costs nothing.
# ----------------------------------------------------------------------------
step "libadwaita colour tokens (GTK4)"
ADW="$HOME/.config/gtk-4.0/linuxonmac-adwaita.css"
mkdir -p "$(dirname "$ADW")"
cat > "$ADW" <<CSS
/* Generated by 71-visual-polish.sh — libadwaita named colours mapped onto the
   AuroraDark colour scheme. Flat and fully opaque throughout: this guest has
   no GPU, so every alpha-blended surface is CPU work for no visual gain. */
@define-color window_bg_color ${WIN_BG};
@define-color window_fg_color ${WIN_FG};
@define-color view_bg_color ${VIEW_BG};
@define-color view_fg_color ${VIEW_FG};
@define-color headerbar_bg_color ${HEAD_BG};
@define-color headerbar_fg_color ${WIN_FG};
@define-color headerbar_border_color ${WIN_FG};
@define-color headerbar_backdrop_color ${WIN_BG};
@define-color headerbar_shade_color rgba(0, 0, 0, 0.36);
@define-color sidebar_bg_color ${SIDE_BG};
@define-color sidebar_fg_color ${WIN_FG};
@define-color sidebar_backdrop_color ${HEAD_BG};
@define-color sidebar_shade_color rgba(0, 0, 0, 0.36);
@define-color secondary_sidebar_bg_color ${HEAD_BG};
@define-color secondary_sidebar_fg_color ${WIN_FG};
@define-color card_bg_color ${CARD_BG};
@define-color card_fg_color ${WIN_FG};
@define-color card_shade_color rgba(0, 0, 0, 0.36);
@define-color dialog_bg_color ${WIN_BG};
@define-color dialog_fg_color ${WIN_FG};
@define-color popover_bg_color ${TIP_BG};
@define-color popover_fg_color ${WIN_FG};
@define-color thumbnail_bg_color ${CARD_BG};
@define-color thumbnail_fg_color ${WIN_FG};
@define-color accent_bg_color ${ACCENT};
@define-color accent_fg_color #ffffff;
@define-color accent_color ${LINK};
@define-color destructive_bg_color ${NEGATIVE};
@define-color destructive_fg_color #ffffff;
@define-color destructive_color ${NEGATIVE};
@define-color success_bg_color ${POSITIVE};
@define-color success_fg_color #ffffff;
@define-color success_color ${POSITIVE};
@define-color warning_bg_color ${NEUTRAL};
@define-color warning_fg_color #000000;
@define-color warning_color ${NEUTRAL};
@define-color error_bg_color ${NEGATIVE};
@define-color error_fg_color #ffffff;
@define-color error_color ${NEGATIVE};
@define-color shade_color rgba(0, 0, 0, 0.36);
@define-color scrollbar_outline_color rgba(0, 0, 0, 0.5);
@define-color borders rgba(255, 255, 255, 0.12);

/* libadwaita 1.8+ reads these instead. */
:root {
  --window-bg-color: ${WIN_BG};
  --window-fg-color: ${WIN_FG};
  --view-bg-color: ${VIEW_BG};
  --view-fg-color: ${VIEW_FG};
  --headerbar-bg-color: ${HEAD_BG};
  --headerbar-fg-color: ${WIN_FG};
  --sidebar-bg-color: ${SIDE_BG};
  --sidebar-fg-color: ${WIN_FG};
  --card-bg-color: ${CARD_BG};
  --card-fg-color: ${WIN_FG};
  --dialog-bg-color: ${WIN_BG};
  --dialog-fg-color: ${WIN_FG};
  --popover-bg-color: ${TIP_BG};
  --popover-fg-color: ${WIN_FG};
  --accent-bg-color: ${ACCENT};
  --accent-fg-color: #ffffff;
  --accent-color: ${LINK};
  --destructive-bg-color: ${NEGATIVE};
  --success-bg-color: ${POSITIVE};
  --warning-bg-color: ${NEUTRAL};
  --error-bg-color: ${NEGATIVE};
}
CSS

# kde-gtk-config owns gtk.css and writes exactly "@import 'colors.css';".
# Append our import rather than replacing the file, and re-append every
# converge in case kde-gtk-config regenerated it.
GTK4CSS="$HOME/.config/gtk-4.0/gtk.css"
touch "$GTK4CSS"
if ! grep -q "linuxonmac-adwaita.css" "$GTK4CSS"; then
    # @import must precede other rules, but kde-gtk-config's file is nothing
    # but imports, so appending keeps it valid.
    printf '\n@import '\''linuxonmac-adwaita.css'\'';\n' >> "$GTK4CSS"
fi
ok "gtk-4.0/linuxonmac-adwaita.css written and imported (accent ${ACCENT})"

# ----------------------------------------------------------------------------
# 4. GTK file dialogs should be the Breeze file dialog.
#
# xdg-desktop-portal-kde is installed and /usr/share/xdg-desktop-portal/
# kde-portals.conf already names kde as the preferred backend — but a GTK app
# only asks the portal at all if it is told to. GTK_USE_PORTAL=1 flips that,
# so "Open File" in any GTK3 app becomes the same dialog Dolphin and Kate use:
# same colours, same font, same icons, same sidebar. Without it a GTK app pops
# a GTK file chooser, which is where the "light-mode dialog" complaint comes
# from — the GTK chooser under xdg-desktop-portal-gtk does not inherit the
# KDE colour scheme.
# ----------------------------------------------------------------------------
step "Routing GTK dialogs through the KDE portal"
ENVD="$HOME/.config/environment.d"
mkdir -p "$ENVD"
cat > "$ENVD/71-linuxonmac-visual.conf" <<'ENV'
# Ask xdg-desktop-portal for file/print/app-chooser dialogs. With
# xdg-desktop-portal-kde preferred, GTK apps get the Breeze dialogs.
GTK_USE_PORTAL=1
# Some toolkits (SDL, Electron, Java, anything using libXcursor directly)
# read only XCURSOR_*, ignoring both /usr/share/icons/default and GSettings.
XCURSOR_THEME=__CURSOR_THEME__
XCURSOR_SIZE=__CURSOR_SIZE__
ENV
sed -i "s|__CURSOR_THEME__|${CURSOR_THEME}|; s|__CURSOR_SIZE__|${CURSOR_SIZE}|" "$ENVD/71-linuxonmac-visual.conf"
ok "environment.d/71-linuxonmac-visual.conf (GTK_USE_PORTAL, XCURSOR_*)"

# environment.d only takes effect at the next login. Push the same values into
# the running session's activation environment so anything launched from the
# panel, KRunner or a new terminal picks them up now.
if command -v dbus-update-activation-environment >/dev/null 2>&1; then
    dbus-update-activation-environment --systemd \
        GTK_USE_PORTAL=1 XCURSOR_THEME="$CURSOR_THEME" XCURSOR_SIZE="$CURSOR_SIZE" 2>/dev/null \
        && ok "pushed into the live session activation environment" \
        || warn "could not update the live activation environment (needs a re-login)"
fi

# The portal's own preference file is already correct system-wide; report it
# rather than shadowing it with a user copy that could drift.
if ! grep -q '^default=kde' /usr/share/xdg-desktop-portal/kde-portals.conf 2>/dev/null; then
    warn "kde-portals.conf no longer prefers the kde backend — GTK dialogs will be GTK-styled"
fi

# GTK's file chooser sidebar should show the same places Dolphin does.
# Additive only: never remove an entry somebody else put here.
BM="$HOME/.config/gtk-3.0/bookmarks"
touch "$BM"
add_bookmark() { # add_bookmark <path> <label>
    [ -d "$1" ] || return 0
    grep -qxF "file://$1 $2" "$BM" && return 0
    grep -q "^file://$1\( \|$\)" "$BM" && return 0
    printf 'file://%s %s\n' "$1" "$2" >> "$BM"
}
add_bookmark "$HOME/Documents" "Documents"
add_bookmark "$HOME/Downloads" "Downloads"
add_bookmark "$HOME/Pictures"  "Pictures"
add_bookmark "$HOME/Desktop"   "Desktop"
add_bookmark "/mnt/mac"        "macOS Home"
ok "GTK file-dialog places: $(wc -l < "$BM") entries"

# ----------------------------------------------------------------------------
# 5. Firefox.
#
# The only substantial GTK app on this guest, and the one the brief calls out.
# Firefox does read the GTK theme, but three things still go wrong:
#   * its chrome theme defaults to "auto", which on a first run before the GTK
#     settings land latches to light and stays there;
#   * in-page content renders with prefers-color-scheme: light unless told
#     otherwise, so every page flashes white against a dark desktop;
#   * its file picker is GTK's own unless the portal is explicitly requested.
# user.js re-applies at every start, which is the same converge model the rest
# of this guest runs on.
# ----------------------------------------------------------------------------
step "Firefox appearance"
FF_ROOT="$HOME/.mozilla/firefox"
if [ -d "$FF_ROOT" ]; then
    write_userjs() {
        cat > "$1/user.js" <<JSEOF
// Generated by 71-visual-polish.sh — do not edit; regenerated at every login.

// --- chrome and content both dark, no light flash on startup ---------------
user_pref("browser.theme.toolbar-theme", 0);   // 0 = dark
user_pref("browser.theme.content-theme", 0);   // 0 = dark
user_pref("ui.systemUsesDarkTheme", 1);
user_pref("layout.css.prefers-color-scheme.content-override", 0);
user_pref("browser.display.use_system_colors", false);

// --- same type as the rest of the desktop ---------------------------------
user_pref("font.default.x-western", "sans-serif");
user_pref("font.name.sans-serif.x-western", "${UI_FONT}");
user_pref("font.name.monospace.x-western", "${MONO_FONT}");

// --- dialogs come from xdg-desktop-portal, i.e. Breeze --------------------
// 1 = always use the portal. The default (2) only does so inside a sandbox,
// which is why Firefox here shows a GTK file chooser instead of Dolphin's.
user_pref("widget.use-xdg-desktop-portal.file-picker", 1);
user_pref("widget.use-xdg-desktop-portal.mime-handler", 1);
user_pref("widget.use-xdg-desktop-portal.settings", 1);

// --- widget details that betray a foreign toolkit -------------------------
// Breeze scrollbars are always visible; GTK overlay scrollbars are not.
user_pref("widget.gtk.overlay-scrollbars.enabled", false);
// Checkboxes, radios and focus rings pick up the desktop accent colour.
user_pref("widget.non-native-theme.use-theme-accent", true);

// --- motion policy matches the desktop ------------------------------------
// The session runs with AnimationDurationFactor=0 and every KWin per-pixel
// effect disabled because there is no GPU. Firefox animating on its own would
// be both inconsistent and slow on llvmpipe.
user_pref("toolkit.cosmeticAnimations.enabled", false);
user_pref("ui.prefersReducedMotion", 1);

// --- first-run furniture that makes a fresh profile look unconfigured -----
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("datareporting.policy.firstRunURL", "");
JSEOF
    }
    n=0
    # Every directory named by profiles.ini, plus any profile directory that
    # already has a prefs.js (covers profiles created outside profiles.ini).
    for p in "$FF_ROOT"/*/; do
        p="${p%/}"
        case "$(basename "$p")" in "Crash Reports"|"Pending Pings"|"Profile Groups") continue ;; esac
        [ -f "$p/prefs.js" ] || [ -f "$p/times.json" ] || [ -f "$p/compatibility.ini" ] || continue
        write_userjs "$p" && n=$((n+1))
    done
    if [ "$n" -gt 0 ]; then ok "user.js written to $n Firefox profile(s)"
    else warn "no initialised Firefox profile found under $FF_ROOT"; fi
else
    warn "Firefox has never been run; no profile to configure"
fi

# ----------------------------------------------------------------------------
# 6. User avatar.
#
# Kickoff's header, the lock screen and the SDDM greeter all render the user
# as the stock grey silhouette, which is the single most "default install"
# thing left on screen. A flat monogram in the scheme's own accent colour
# costs nothing to render (no GPU involved) and reads as intentional.
# ----------------------------------------------------------------------------
step "User avatar"
sudo install -d -m 0755 /usr/local/share/linuxonmac
if [ ! -s "$AVATAR_SRC" ] || [ ! -s "$HOME/.face.icon" ]; then
    TMP_AV="$(mktemp /tmp/linuxonmac-avatar.XXXXXX.png)"
    if python3 - "$TMP_AV" "$ACCENT" "$USER" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont
out, accent, user = sys.argv[1], sys.argv[2], sys.argv[3]
S = 512
letter = (user[:1] or "?").upper()
img = Image.new("RGBA", (S, S), accent)          # flat fill: masked to a circle
d = ImageDraw.Draw(img)                           # by Plasma/SDDM themselves
font = None
for p in ("/usr/share/fonts/opentype/inter/InterDisplay-SemiBold.otf",
          "/usr/share/fonts/opentype/inter/Inter-SemiBold.otf",
          "/usr/share/fonts/opentype/inter/Inter-Bold.otf"):
    try:
        font = ImageFont.truetype(p, 260); break
    except Exception:
        continue
if font is None:
    font = ImageFont.load_default()
l, t, r, b = d.textbbox((0, 0), letter, font=font)
# Optical centring: centre the glyph's ink box, not its advance box.
d.text(((S - (r - l)) / 2 - l, (S - (b - t)) / 2 - t), letter, font=font, fill="#ffffff")
img.save(out, "PNG")
PY
    then
        sudo install -m 0644 "$TMP_AV" "$AVATAR_SRC"
        install -m 0644 "$TMP_AV" "$HOME/.face.icon"
        ok "generated a flat '$(printf '%s' "${USER:0:1}" | tr '[:lower:]' '[:upper:]')' monogram avatar in ${ACCENT}"
    else
        warn "could not generate an avatar (python3-pil missing?)"
    fi
    rm -f "$TMP_AV"
else
    ok "avatar already generated"
fi

if [ -s "$AVATAR_SRC" ]; then
    [ -s "$HOME/.face.icon" ] || install -m 0644 "$AVATAR_SRC" "$HOME/.face.icon"
    # AccountsService is what SDDM and the lock screen read. Prefer its D-Bus
    # API, which copies the file and updates the user record correctly; fall
    # back to writing the two files by hand if the service is not around.
    CUR_ICON="$(sudo sed -n 's/^Icon=//p' "/var/lib/AccountsService/users/$USER" 2>/dev/null | head -1)"
    if [ "$CUR_ICON" != "/var/lib/AccountsService/icons/$USER" ]; then
        if ! sudo busctl call org.freedesktop.Accounts /org/freedesktop/Accounts/User"$(id -u)" \
                org.freedesktop.Accounts.User SetIconFile s "$AVATAR_SRC" >/dev/null 2>&1; then
            sudo install -d -m 0775 /var/lib/AccountsService/icons /var/lib/AccountsService/users
            sudo install -m 0644 "$AVATAR_SRC" "/var/lib/AccountsService/icons/$USER"
            UF="/var/lib/AccountsService/users/$USER"
            if sudo test -f "$UF"; then
                sudo sed -i "/^Icon=/d" "$UF"
                sudo sed -i "/^\[User\]/a Icon=/var/lib/AccountsService/icons/$USER" "$UF"
            else
                printf '[User]\nIcon=/var/lib/AccountsService/icons/%s\n' "$USER" | sudo tee "$UF" >/dev/null
                sudo chmod 0600 "$UF"
            fi
        fi
        ok "AccountsService avatar set (Kickoff, lock screen, SDDM)"
    else
        ok "AccountsService avatar already set"
    fi
fi

# ----------------------------------------------------------------------------
# 7. Lock screen and SDDM greeter.
#
# 20-desktop-theme.sh already points both at the Breeze Dark look-and-feel and
# the Aurora wallpaper. What is left is how they *render* it.
# ----------------------------------------------------------------------------
step "Lock screen"
# PreserveAspectCrop. The wallpaper is 2940x1912 and the screen is 1470x956 —
# an exact 2:1 — so any fill mode crops nothing today, but pinning it means a
# later wallpaper of a different aspect fills rather than letterboxes.
kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper \
    --group org.kde.image --group General --key FillMode 2
# The image wallpaper plugin blurs the letterbox area behind a non-filling
# image. That is a full-screen software gaussian on a machine with no GPU, and
# with FillMode=2 there is no letterbox to blur anyway.
kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper \
    --group org.kde.image --group General --key Blur false
ok "lock screen wallpaper: fill (crop), no blur pass"

step "SDDM greeter"
if [ -d /usr/share/sddm/themes/breeze ]; then
    sudo install -d -m 0755 /etc/sddm.conf.d
    # A separate file from 20-desktop-theme.sh's 20-theme.conf; SDDM merges
    # /etc/sddm.conf.d/*.conf in name order, so neither script touches the
    # other's keys.
    sudo tee /etc/sddm.conf.d/71-visual.conf >/dev/null <<'SDDMEOF'
# Written by 71-visual-polish.sh.
[General]
# The greeter is a Qt Quick scene. Without this it asks llvmpipe to emulate
# OpenGL just to draw a flat login form, exactly the way the desktop session
# does before 60-graphics-performance.sh switches it to the software scene
# graph. Same switch here, so the login screen renders like the desktop.
GreeterEnvironment=QT_QUICK_BACKEND=software,QSG_RENDER_LOOP=basic,LIBGL_ALWAYS_SOFTWARE=1

[Wayland]
# The desktop is pinned to 1470x956 at scale 1. SDDM's HiDPI autodetection
# would independently decide to scale the greeter, giving a login screen at a
# different size to the session that follows it.
EnableHiDPI=false

[X11]
EnableHiDPI=false
SDDMEOF
    ok "greeter renders with the software scene graph, HiDPI autoscale pinned off"
else
    warn "sddm breeze theme not installed; skipping greeter"
fi

# ----------------------------------------------------------------------------
# 8. Notifications, tooltips and dialog placement.
#
# The panel layout here is macOS-shaped: a menu bar along the top edge and a
# dock along the bottom. Plasma's default notification position is the bottom
# right, i.e. directly on top of the dock.
# ----------------------------------------------------------------------------
step "Notifications"
kwriteconfig6 --file plasmanotifyrc --group Notifications --key PopupPosition TopRight
kwriteconfig6 --file plasmanotifyrc --group Notifications --key PopupTimeout 5000
# Low-priority notifications (background chatter from indexers and the like)
# stay out of the way but remain in the history, so nothing is lost.
kwriteconfig6 --file plasmanotifyrc --group Notifications --key LowPriorityPopups false
kwriteconfig6 --file plasmanotifyrc --group Notifications --key LowPriorityHistory true
# File-transfer style jobs auto-dismiss instead of leaving a stuck popup.
kwriteconfig6 --file plasmanotifyrc --group Jobs --key PermanentPopups false
ok "popups: top-right, clear of the dock, 5s, low-priority to history only"

step "Tooltips"
# Everything else in the session runs with animations off; a 700ms hover delay
# feels laggy next to that. Qt tooltip colours already come from kdeglobals
# [Colors:Tooltip], and the GTK side gets the same #2c3037 through colors.css,
# so the two toolkits' tooltips are already identical — this is only timing.
kwriteconfig6 --file plasmarc --group PlasmaToolTips --key Delay 500
ok "plasma tooltip delay 500ms"

step "Dialog placement"
# One 1470x956 screen. Smart placement cascades new windows towards the bottom
# right and pushes dialogs partly off-screen; Centered puts every new window
# and every modal in the same predictable place.
kwriteconfig6 --file kwinrc --group Windows --key Placement Centered
ok "new windows and dialogs centred"

# ----------------------------------------------------------------------------
# 9. Ask the running session to pick up what it can without a re-login.
# ----------------------------------------------------------------------------
step "Reloading the session"
# KWin re-reads kwinrc on this signal (placement, decoration tooltips).
qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 \
    || qdbus org.kde.KWin /KWin reconfigure >/dev/null 2>&1 \
    || warn "could not signal KWin; placement applies at next login"
# kded's gtkconfig module re-exports GTK settings to XWayland's XSETTINGS.
qdbus6 org.kde.kded6 /kded loadModule gtkconfig >/dev/null 2>&1 || true
ok "signalled KWin and kded"

cat <<'SUMMARY'

Applied. Takes effect immediately:
  * GSettings-level GTK parity (new GTK apps only)
  * Firefox user.js                (restart Firefox)
  * notification position, tooltip delay, window placement
  * lock screen wallpaper framing

Needs a re-login:
  * GTK_USE_PORTAL / XCURSOR_* for apps not started through D-Bus activation
  * the avatar in Kickoff's header
  * the SDDM greeter settings (next boot)
SUMMARY
