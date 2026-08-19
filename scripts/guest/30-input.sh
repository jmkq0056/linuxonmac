#!/usr/bin/env bash
# 30-input.sh — make the Debian/KDE Plasma 6 guest's pointer and keyboard feel like macOS.
#
# Run INSIDE the guest, as the desktop user, with a Plasma Wayland session running:
#   bash scripts/guest/30-input.sh
#
# Idempotent: every write goes through kwriteconfig6 or an XML merge, so re-running
# converges rather than accumulating. It never overwrites a whole shared config file.
#
# What it does
#   1. Natural (macOS-direction) scrolling + a scroll factor for the VZ pointing device.
#   2. Adds Meta+<key> as an ALTERNATE to KDE's standard shortcuts, so Cmd+C/V/X/...
#      work in Qt/KDE apps while Ctrl+C keeps sending SIGINT in terminals.
#   3. Frees the Meta+<letter> combinations Plasma had reserved globally, which would
#      otherwise swallow Cmd+W / Cmd+T / Cmd+A / Cmd+S / Cmd+V / Cmd+Q / Cmd+G.
#   4. Binds Meta+Space to KRunner (Spotlight muscle memory).
#   5. Teaches Konsole the same Cmd bindings alongside its own Ctrl+Shift ones.
#
# See docs/INPUT.md for the reasoning, the verification evidence and the known gaps.

set -uo pipefail

SCROLL_FACTOR="${SCROLL_FACTOR:-1}"   # libinput default. 0.5 felt sluggish in use.
NATURAL_SCROLL="${NATURAL_SCROLL:-true}"
RELOAD_GLOBAL_SHORTCUTS="${RELOAD_GLOBAL_SHORTCUTS:-1}"

TAB=$'\t'
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
err()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# --- session env -------------------------------------------------------------
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

for t in kwriteconfig6 kreadconfig6 python3; do
    command -v "$t" >/dev/null || { err "missing required tool: $t"; exit 1; }
done
HAVE_GDBUS=0; command -v gdbus >/dev/null && HAVE_GDBUS=1
HAVE_SESSION=0
if [ "$HAVE_GDBUS" = 1 ] && gdbus call --session --dest org.kde.KWin --object-path /KWin \
        --method org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1; then
    HAVE_SESSION=1
fi

###############################################################################
head_ "1. Pointing device — natural scrolling + scroll factor"
###############################################################################
# KWin/Wayland keys per-device libinput settings off the DECIMAL USB vendor and
# product ids; /proc/bus/input/devices reports them in HEX. mawk (Debian's default
# awk) has no strtonum(), so convert with bash's printf instead.
#
# NOTE: KWin persists these in ~/.config/kcminputrc, NOT ~/.config/kwinrc.
# (kwinApp()->inputConfig() opens kcminputrc; anything written to kwinrc is
# silently ignored.)  Verified: KWin's own D-Bus property setter writes there.

read -r DEV_VENDOR_HEX DEV_PRODUCT_HEX DEV_NAME <<<"$(
python3 - <<'PY'
import re
blocks = open('/proc/bus/input/devices').read().split('\n\n')
best = None
for b in blocks:
    mi = re.search(r'^I: Bus=\S+ Vendor=(\S+) Product=(\S+)', b, re.M)
    mn = re.search(r'^N: Name="(.*)"', b, re.M)
    mh = re.search(r'^H: Handlers=(.*)$', b, re.M)
    if not (mi and mn and mh):
        continue
    handlers = mh.group(1).split()
    # A pointing device is one libinput exposes through a mouseN handler.
    if not any(h.startswith('mouse') for h in handlers):
        continue
    score = 2 if 'Digitizer' in mn.group(1) else 1
    if best is None or score > best[0]:
        best = (score, mi.group(1), mi.group(2), mn.group(1))
if best:
    print(best[1], best[2], best[3])
PY
)"

if [ -z "${DEV_NAME:-}" ]; then
    err "no pointing device found in /proc/bus/input/devices — skipping scroll setup"
else
    # HEX -> DECIMAL without gawk/strtonum.
    DEV_VENDOR=$(printf '%d' "0x${DEV_VENDOR_HEX}")
    DEV_PRODUCT=$(printf '%d' "0x${DEV_PRODUCT_HEX}")
    ok "device: ${DEV_NAME}  vendor 0x${DEV_VENDOR_HEX}=${DEV_VENDOR}  product 0x${DEV_PRODUCT_HEX}=${DEV_PRODUCT}"

    kw_input() { kwriteconfig6 --file kcminputrc \
        --group Libinput --group "$DEV_VENDOR" --group "$DEV_PRODUCT" --group "$DEV_NAME" \
        --key "$1" "$2"; }
    kr_input() { kreadconfig6 --file kcminputrc \
        --group Libinput --group "$DEV_VENDOR" --group "$DEV_PRODUCT" --group "$DEV_NAME" \
        --key "$1"; }

    kw_input NaturalScroll "$NATURAL_SCROLL"
    kw_input ScrollFactor  "$SCROLL_FACTOR"
    ok "kcminputrc: NaturalScroll=$(kr_input NaturalScroll)  ScrollFactor=$(kr_input ScrollFactor)"

    # Apply to the *running* KWin as well, so no logout is needed. KWin's setters
    # also write the config, so this is belt-and-braces, not a second source of truth.
    if [ "$HAVE_SESSION" = 1 ]; then
        SYSNAMES=$(gdbus call --session --dest org.kde.KWin --object-path /org/kde/KWin/InputDevice \
            --method org.freedesktop.DBus.Properties.Get org.kde.KWin.InputDeviceManager devicesSysNames \
            2>/dev/null | grep -o "'event[0-9]*'" | tr -d "'")
        for sn in $SYSNAMES; do
            p=/org/kde/KWin/InputDevice/$sn
            n=$(gdbus call --session --dest org.kde.KWin --object-path "$p" \
                --method org.freedesktop.DBus.Properties.Get org.kde.KWin.InputDevice name 2>/dev/null)
            case "$n" in *"$DEV_NAME"*) ;; *) continue;; esac
            gdbus call --session --dest org.kde.KWin --object-path "$p" \
                --method org.freedesktop.DBus.Properties.Set org.kde.KWin.InputDevice \
                naturalScroll "<${NATURAL_SCROLL}>" >/dev/null 2>&1
            gdbus call --session --dest org.kde.KWin --object-path "$p" \
                --method org.freedesktop.DBus.Properties.Set org.kde.KWin.InputDevice \
                scrollFactor "<${SCROLL_FACTOR}>" >/dev/null 2>&1
            live_ns=$(gdbus call --session --dest org.kde.KWin --object-path "$p" \
                --method org.freedesktop.DBus.Properties.Get org.kde.KWin.InputDevice naturalScroll 2>/dev/null)
            live_sf=$(gdbus call --session --dest org.kde.KWin --object-path "$p" \
                --method org.freedesktop.DBus.Properties.Get org.kde.KWin.InputDevice scrollFactor 2>/dev/null)
            ok "live KWin ($sn): naturalScroll=${live_ns} scrollFactor=${live_sf}"
        done
    else
        warn "no running KWin found — scroll settings apply at next login"
    fi
fi

###############################################################################
head_ "2. Cmd+<key> for KDE/Qt standard actions (kdeglobals [Shortcuts])"
###############################################################################
# KStandardShortcut::initialize() reads kdeglobals group [Shortcuts], key = the
# standard action name, and parses the value with QKeySequence::listFromString(),
# whose separator is "; " (semicolon + space).  Writing an entry REPLACES the
# hardcoded defaults, so each line below repeats the defaults and appends Meta+.
# Ctrl+C is therefore untouched: in a terminal it still sends SIGINT.
sc() { kwriteconfig6 --file kdeglobals --group Shortcuts --key "$1" "$2"; }
sc Copy      "Ctrl+C; Ctrl+Ins; Meta+C"
sc Paste     "Ctrl+V; Shift+Ins; Meta+V"
sc Cut       "Ctrl+X; Shift+Del; Meta+X"
sc SelectAll "Ctrl+A; Meta+A"
sc Undo      "Ctrl+Z; Meta+Z"
sc Redo      "Ctrl+Shift+Z; Meta+Shift+Z"
sc Save      "Ctrl+S; Meta+S"
sc Find      "Ctrl+F; Meta+F"
sc FindNext  "F3; Meta+G"
sc FindPrev  "Shift+F3; Meta+Shift+G"
sc Replace   "Ctrl+R; Meta+Shift+F"
sc Close     "Ctrl+W; Ctrl+Esc; Meta+W"
sc Quit      "Ctrl+Q; Meta+Q"
sc New       "Ctrl+N; Meta+N"
sc Open      "Ctrl+O; Meta+O"
sc Print     "Ctrl+P; Meta+P"
for k in Copy Paste Cut SelectAll Undo Redo Save Find FindNext FindPrev Replace Close Quit New Open Print; do
    printf '  %-10s %s\n' "$k" "$(kreadconfig6 --file kdeglobals --group Shortcuts --key "$k")"
done

###############################################################################
head_ "3. Free the Meta+<letter> combos Plasma reserved globally"
###############################################################################
# A global shortcut is grabbed by the compositor and never reaches the focused
# window, so Meta+W/T/A/S/V/Q/G had to move or Cmd+W etc. could never work.
# Format is:  Key=active,default,Friendly Name   with \t between alternates.
# The default field is preserved so "Reset to Defaults" in System Settings works.
gs() { kwriteconfig6 --file kglobalshortcutsrc --group "$1" --key "$2" "$3"; }

gs kwin "Overview"              "Ctrl+Up,Meta+W,Toggle Overview"
gs kwin "Grid View"             "Ctrl+Down,Meta+G,Toggle Grid View"
gs kwin "Edit Tiles"            "Meta+Shift+T,Meta+T,Toggle Tiles Editor"
gs kwin "view_actual_size"      "Meta+Ctrl+0,Meta+0,Zoom to Actual Size"
gs kwin "view_zoom_in"          "Meta+Ctrl++${TAB}Meta+Ctrl+=,Meta++${TAB}Meta+=,Zoom In"
gs kwin "view_zoom_out"         "Meta+Ctrl+-,Meta+-,Zoom Out"
gs plasmashell "next activity"          "none,none,Walk through activities"
gs plasmashell "stop current activity"  "none,Meta+S,Stop Current Activity"
gs plasmashell "manage activities"      "none,Meta+Q,Show Activity Switcher"
gs plasmashell "show-on-mouse-pos"      "Meta+Shift+V,Meta+V,Show Clipboard Items at Mouse Position"

# KRunner = Spotlight.  Component id is the desktop file name; action is _launch.
# Keep the stock Alt+Space / Alt+F2 / Search alternates alongside Meta+Space.
gs "org.kde.krunner.desktop" "_k_friendly_name" "KRunner"
gs "org.kde.krunner.desktop" "_launch" \
   "Meta+Space${TAB}Alt+Space${TAB}Alt+F2${TAB}Search,Alt+Space${TAB}Alt+F2${TAB}Search,KRunner"

for kv in "kwin|Overview" "kwin|Grid View" "kwin|Edit Tiles" "kwin|view_actual_size" \
          "kwin|view_zoom_in" "kwin|view_zoom_out" "plasmashell|next activity" \
          "plasmashell|stop current activity" "plasmashell|manage activities" \
          "plasmashell|show-on-mouse-pos" "org.kde.krunner.desktop|_launch"; do
    g=${kv%%|*}; k=${kv#*|}
    printf '  [%s] %-24s %s\n' "$g" "$k" "$(kreadconfig6 --file kglobalshortcutsrc --group "$g" --key "$k")"
done

# On Plasma 6 Wayland the global-shortcut registry lives INSIDE kwin_wayland --
# it, not kglobalacceld, owns the org.kde.kglobalaccel D-Bus name (kglobalacceld
# is the X11-only path and exits immediately under Wayland).  KWin reads
# kglobalshortcutsrc once at startup and does not watch it, so these bindings
# only become active after a log out / log back in.
#
# Do NOT try to shortcut that with
#   org.kde.KGlobalAccel.setForeignShortcutKeys
# -- on this build that call kills the process on the other end, which under
# Wayland is the compositor, taking the whole session with it.
if [ "$RELOAD_GLOBAL_SHORTCUTS" = 1 ] && [ "$HAVE_SESSION" = 1 ]; then
    gdbus call --session --dest org.kde.KWin --object-path /KWin \
        --method org.kde.KWin.reconfigure >/dev/null 2>&1 && ok "asked KWin to reconfigure"
    if gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
         --method org.kde.KGlobalAccel.getGlobalShortcutsByKey 268435488 2>/dev/null \
         | grep -q _launch; then
        ok "Meta+Space is live on KRunner"
    else
        warn "Meta+Space not registered yet — log out and back in, then re-check with:"
        warn "  gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \\"
        warn "    --method org.kde.KGlobalAccel.getGlobalShortcutsByKey 268435488"
    fi
else
    warn "global shortcut changes apply at next login"
fi

###############################################################################
head_ "4. Konsole — Cmd+C copies while Ctrl+C still sends SIGINT"
###############################################################################
# Konsole overrides the KDE standard shortcuts with its own Ctrl+Shift ones
# (Konsole::ACCEL == Qt::CTRL|Qt::SHIFT on Linux, src/Shortcut_p.h), so section 2
# does not reach it.  KXmlGui's supported override point is <ActionProperties> in
# the user copy of the .rc file; KXmlGuiVersionHandler merges that section into
# the app's newer built-in .rc on every start, and KXMLGUIFactory applies it with
# QAction::setShortcuts(QKeySequence::listFromString(...)) — i.e. multiple
# bindings separated by "; ".  Because it REPLACES the list, every line repeats
# Konsole's verified defaults and only appends the Meta+ one.
python3 - <<'PY'
import os, xml.etree.ElementTree as ET

BASE = os.path.expanduser('~/.local/share/kxmlgui5/konsole')

FILES = {
    # SessionController actions (terminal-level)
    'sessionui.rc': {
        'edit_copy':       'Ctrl+Shift+C; Ctrl+Ins; Meta+C',
        'edit_paste':      'Ctrl+Shift+V; Shift+Ins; Meta+V',
        'select-all':      'Meta+A',                 # no upstream default
        'edit_find':       'Ctrl+Shift+F; Meta+F',
        'edit_find_next':  'F3; Meta+G',
        'edit_find_prev':  'Shift+F3; Meta+Shift+G',
        'close-session':   'Ctrl+Shift+W; Meta+W',
        'file_print':      'Ctrl+Shift+P; Meta+P',
        'enlarge-font':    'Ctrl++; Ctrl+=; Meta++; Meta+=',
        'shrink-font':     'Ctrl+-; Meta+-',
        'reset-font-size': 'Ctrl+Alt+0; Meta+0',
        'clear-history':   'Meta+K',                 # no upstream default; Cmd+K in Terminal.app
    },
    # MainWindow actions (window/tab-level)
    'konsoleui.rc': {
        'new-tab':      'Ctrl+Shift+T; Meta+T',
        'new-window':   'Ctrl+Shift+N; Meta+N',
        'close-window': 'Ctrl+Shift+Q; Meta+Q',
    },
}
GUINAME = {'sessionui.rc': 'session', 'konsoleui.rc': 'konsole'}
# Action names that belong to the *other* rc file; strip them if a stale run
# put them here, otherwise they are dead weight.
STALE = {'edit_copy', 'edit_paste'}

os.makedirs(BASE, exist_ok=True)
for fname, wanted in FILES.items():
    path = os.path.join(BASE, fname)
    if os.path.exists(path) and os.path.getsize(path) > 0:
        tree = ET.parse(path)          # already merged with the built-in rc
        root = tree.getroot()
    else:
        # Minimal seed: version 1 always loses to the built-in rc, so the version
        # handler copies our <ActionProperties> into it and rewrites this file.
        root = ET.Element('gui', {'name': GUINAME[fname], 'version': '1'})
        tree = ET.ElementTree(root)
    ap = root.find('ActionProperties')
    if ap is None:
        ap = ET.SubElement(root, 'ActionProperties')
    # Collapse any duplicates a previous run may have left behind.
    seen = {}
    for a in list(ap.findall('Action')):
        n = a.get('name')
        if n in seen:
            ap.remove(a)
        else:
            seen[n] = a
    for name, shortcut in wanted.items():
        el = seen.get(name)
        if el is None:
            el = ET.SubElement(ap, 'Action', {'name': name})
            seen[name] = el
        el.set('shortcut', shortcut)
    # Drop entries this script does not own from a stale earlier attempt.
    for a in list(ap.findall('Action')):
        if a.get('name') not in wanted and a.get('name') in STALE:
            ap.remove(a)
    ET.indent(tree, space=' ')
    tree.write(path, encoding='unicode', xml_declaration=True)
    print('  wrote %s (%d actions)' % (path, len(wanted)))
PY

###############################################################################
head_ "Done"
###############################################################################
cat <<'MSG'
  Live now             : scrolling (KWin was updated over D-Bus).
  Needs an app restart : Cmd+ bindings inside KDE/Qt apps and Konsole -- both
                         KStandardShortcut and KXmlGui read their config once,
                         at application startup.
  Needs a re-login     : the global shortcuts in section 3, including Meta+Space
                         for KRunner. On Wayland kwin_wayland owns the shortcut
                         registry and only reads kglobalshortcutsrc at startup.
  Not covered          : GTK apps, Firefox, Electron/VS Code -- see docs/INPUT.md.
MSG
