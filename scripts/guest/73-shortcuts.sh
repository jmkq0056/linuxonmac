#!/usr/bin/env bash
# Makes the whole shortcut layer coherent now that Cmd is Control.
#
# 50-mac-keyboard.sh made the Command key emit Control at the evdev layer so
# that Cmd+C/V/A work in Firefox and every GTK app. The side effect is that
# Meta stopped existing as a modifier: Plasma's defaults (Meta alone, Meta+Space,
# Meta+arrows, Meta+D, Meta+PgDown ...) all became unreachable, and every global
# shortcut moved to Ctrl+ started competing with the applications underneath it.
#
# The fix rests on one observation: keyd can still *emit* Meta even though no
# physical key produces it any more. That turns Meta into a private namespace
# only keyd can reach, so compositor actions can live on Meta+<key> where they
# can never swallow a key an application wanted:
#
#     Cmd+<key>            -> Ctrl+<key>      application shortcuts, unchanged
#     Cmd+<a few keys>     -> Meta+<key>      compositor actions, zero collisions
#     Ctrl+<key>           -> Ctrl+<key>      untouched; Ctrl+C still sends SIGINT
#
# This script therefore owns /etc/keyd/default.conf. 50-mac-keyboard.sh rewrites
# that file unconditionally at every login and runs first, so the only way to
# extend it is to rewrite it afterwards. What is written here is a strict
# superset: leftmeta/rightmeta still behave as Control except for the handful of
# keys listed in [cmd].
set -euo pipefail

VERIFY=0
[ "${1:-}" = "--verify" ] && VERIFY=1
TAB=$'\t'
fail=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }
head_(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. keyd: the Command layer
# ---------------------------------------------------------------------------
# [cmd:C] means "behave as Control unless the key is listed below", and keyd
# strips the layer's own modifier from anything that *is* listed, so `left =
# home` emits a bare Home while Shift+Cmd+Left still emits Shift+Home.
read -r -d '' KEYD_CONF <<'CONF' || true
# Managed by linuxonmac scripts/guest/73-shortcuts.sh — edits here are reverted
# at the next graphical login.
[ids]
*

[main]
leftmeta = layer(cmd)
rightmeta = layer(cmd)

# Command behaves as Control, except for the keys below.
[cmd:C]

# Copy/paste that also work in the terminal. Ctrl+Ins and Shift+Ins are the
# other clipboard bindings every toolkit already understands — Qt's
# QKeySequence::Copy, GTK's text bindings, Firefox, VS Code — and crucially
# Konsole binds them too, where Ctrl+C is reserved for SIGINT. Cmd+X is
# deliberately NOT mapped to Shift+Del: in Dolphin that means "delete
# permanently, no trash", and cutting has no meaning in a terminal anyway.
c = C-insert
v = S-insert

# Spotlight. Lands on Plasma's own Meta+Space, so Ctrl+Space stays free for
# editor autocompletion.
space = M-space

# Cmd+Tab / Cmd+` hold Meta for as long as Command is held, which is what
# KWin's window switcher needs to stay open and commit on release. Ctrl+Tab is
# left alone so browsers and terminals keep their tab cycling.
tab = swapm(cmdswitch, M-tab)
grave = swapm(cmdgroup, M-grave)

# Minimise / hide.
m = M-pagedown
h = M-pagedown

# macOS line and document navigation. Word-wise movement stays on the physical
# Control key, where Linux has always had it.
left = home
right = end
up = C-home
down = C-end

# Back / forward, which macOS puts on Cmd+[ and Cmd+].
leftbrace = A-left
rightbrace = A-right

[cmdswitch:M]
tab = M-tab
grave = M-S-tab
right = M-tab
left = M-S-tab

[cmdgroup:M]
grave = M-grave
tab = M-grave

# Composite layers must follow the layers they are built from.
[cmd+shift]
c = C-S-c
v = C-S-v
m = M-pageup

# macOS puts a handful of window/system actions on Ctrl+Cmd. Those chords would
# otherwise collapse into plain Ctrl, since Cmd already is Control.
[cmd+control]
f = M-f
q = M-l
space = M-dot
left = M-C-left
right = M-C-right
up = M-C-up
down = M-C-down
CONF

if [ "$VERIFY" = 0 ]; then
    command -v keyd.rvaiya >/dev/null || command -v keyd >/dev/null || \
        sudo apt-get -o DPkg::Lock::Timeout=900 install -y keyd
    sudo mkdir -p /etc/keyd
    if ! printf '%s\n' "$KEYD_CONF" | sudo cmp -s - /etc/keyd/default.conf; then
        printf '%s\n' "$KEYD_CONF" | sudo tee /etc/keyd/default.conf >/dev/null
        sudo systemctl enable keyd >/dev/null 2>&1 || true
        sudo systemctl restart keyd
    fi
fi

# ---------------------------------------------------------------------------
# 2. Global shortcuts
# ---------------------------------------------------------------------------
# Format is "active,default,friendly name"; \t separates alternates. Individual
# keys only — kglobalshortcutsrc is shared with Plasma itself.
gs() { # group key value
    if [ "$VERIFY" = 1 ]; then
        got=$(kreadconfig6 --file kglobalshortcutsrc --group "$1" --key "$2" 2>/dev/null)
        want_active=${3%%,*}
        got_active=${got%%,*}
        if [ "$got_active" = "$want_active" ]; then ok "[$1] $2 = ${want_active//$TAB/ or }"
        else bad "[$1] $2 = '${got_active//$TAB/ or }' (want '${want_active//$TAB/ or }')"; fi
    else
        kwriteconfig6 --file kglobalshortcutsrc --group "$1" --key "$2" "$3"
    fi
}
svc() { # desktop-file key value   (the [services][...] mirror)
    if [ "$VERIFY" = 1 ]; then
        got=$(kreadconfig6 --file kglobalshortcutsrc --group services --group "$1" --key "$2" 2>/dev/null)
        [ "$got" = "$3" ] && ok "[services][$1] $2" || bad "[services][$1] $2 = '$got' (want '$3')"
    else
        kwriteconfig6 --file kglobalshortcutsrc --group services --group "$1" --key "$2" "$3"
    fi
}

head_ "Window and application switching"
# Reached as Cmd+Tab / Cmd+Shift+Tab / Cmd+` via the keyd layers above.
gs kwin "Walk Through Windows"              "Meta+Tab${TAB}Alt+Tab,Alt+Tab,Walk Through Windows"
gs kwin "Walk Through Windows (Reverse)"    "Meta+Shift+Tab${TAB}Alt+Shift+Tab,Alt+Shift+Tab,Walk Through Windows (Reverse)"
gs kwin "Walk Through Windows of Current Application" \
        "Meta+\`${TAB}Alt+\`,Alt+\`,Walk Through Windows of Current Application"
gs kwin "Walk Through Windows of Current Application (Reverse)" \
        "Meta+~${TAB}Alt+~,Alt+~,Walk Through Windows of Current Application (Reverse)"

head_ "Mission Control"
# macOS puts these on the physical Control key, which keyd never touches.
gs kwin "Overview"     "Ctrl+Up,Meta+W,Toggle Overview"
gs kwin "Grid View"    "Ctrl+Shift+Up,Meta+G,Toggle Grid View"
gs kwin "ExposeClass"  "Ctrl+Down,Ctrl+F7,Toggle Present Windows (Window class)"
# Redundant with the above, and they were holding Ctrl+F9/F10 hostage.
gs kwin "Expose"       "none,Ctrl+F9,Toggle Present Windows (Current desktop)"
gs kwin "ExposeAll"    "none,Ctrl+F10${TAB}Launch (C),Toggle Present Windows (All desktops)"

head_ "Window management"
gs kwin "Window Minimize"   "Meta+PgDown,Meta+PgDown,Minimize Window"          # Cmd+M, Cmd+H
gs kwin "Window Maximize"   "Meta+PgUp,Meta+PgUp,Maximize Window"              # Cmd+Shift+M
gs kwin "Window Fullscreen" "Meta+F,,Make Window Fullscreen"                   # Ctrl+Cmd+F
gs kwin "Kill Window"       "Ctrl+Alt+Esc,Meta+Ctrl+Esc,Kill Window"           # Cmd+Opt+Esc
gs kwin "Show Desktop"      "Ctrl+Alt+D,Meta+D,Peek at Desktop"
gs kwin "Window Quick Tile Left"   "Ctrl+Alt+Left,Meta+Left,Quick Tile Window to the Left"
gs kwin "Window Quick Tile Right"  "Ctrl+Alt+Right,Meta+Right,Quick Tile Window to the Right"
gs kwin "Window Quick Tile Top"    "Ctrl+Alt+Up,Meta+Up,Quick Tile Window to the Top"
gs kwin "Window Quick Tile Bottom" "Ctrl+Alt+Down,Meta+Down,Quick Tile Window to the Bottom"
# Reached as Ctrl+Cmd+arrow, exactly as macOS switches Spaces.
gs kwin "Switch One Desktop to the Left"  "Meta+Ctrl+Left,Meta+Ctrl+Left,Switch One Desktop to the Left"
gs kwin "Switch One Desktop to the Right" "Meta+Ctrl+Right,Meta+Ctrl+Right,Switch One Desktop to the Right"

head_ "Session"
gs ksmserver "Lock Session" "Meta+L${TAB}Screensaver,Meta+L${TAB}Screensaver,Lock Session"  # Ctrl+Cmd+Q
gs plasmashell "activate application launcher" "Ctrl+Alt+Space${TAB}Alt+F1,Meta${TAB}Alt+F1,Activate Application Launcher"
gs plasmashell "show-on-mouse-pos" "Ctrl+Alt+V,Meta+V,Show Clipboard Items at Mouse Position"

head_ "Search"
# Cmd+Space arrives as Meta+Space. 50-mac-keyboard.sh's Ctrl+Space stopgap never
# worked: it wrote to the legacy [krunner.desktop] component with a literal
# backslash-t instead of a tab, so kglobalaccel never registered it. Remove it,
# both so the dead entry stops claiming Ctrl+Space and so editors keep the key.
gs "org.kde.krunner.desktop" _launch \
   "Meta+Space${TAB}Alt+Space${TAB}Alt+F2${TAB}Search,Alt+Space${TAB}Alt+F2${TAB}Search,KRunner"
svc "org.kde.krunner.desktop" _launch "Meta+Space${TAB}Alt+Space${TAB}Alt+F2${TAB}Search"
if [ "$VERIFY" = 0 ]; then
    kwriteconfig6 --file kglobalshortcutsrc --group "krunner.desktop" --key _launch --delete 2>/dev/null || true
    kwriteconfig6 --file kglobalshortcutsrc --group services --group "krunner.desktop" --key _launch --delete 2>/dev/null || true
else
    stale=$(kreadconfig6 --file kglobalshortcutsrc --group "krunner.desktop" --key _launch 2>/dev/null)
    [ -z "$stale" ] && ok "stale [krunner.desktop] entry removed" || bad "stale [krunner.desktop] _launch=$stale"
fi

head_ "Screenshots"
# Spectacle's defaults are Print and Meta+Print variants. This keyboard has no
# Print key and Meta is gone, so screenshots were entirely unreachable.
gs "org.kde.spectacle.desktop" _k_friendly_name "Spectacle"
gs "org.kde.spectacle.desktop" _launch "Ctrl+Shift+5${TAB}Print,Print${TAB}Meta+Shift+S,Launch Spectacle"
gs "org.kde.spectacle.desktop" FullScreenScreenShot "Ctrl+Shift+3${TAB}Shift+Print,Shift+Print,Capture Entire Desktop"
gs "org.kde.spectacle.desktop" RectangularRegionScreenShot "Ctrl+Shift+4,Meta+Shift+Print,Capture Rectangular Region"
gs "org.kde.spectacle.desktop" ActiveWindowScreenShot "Ctrl+Shift+6,Meta+Print,Capture Active Window"
svc "org.kde.spectacle.desktop" _launch "Ctrl+Shift+5${TAB}Print"
svc "org.kde.spectacle.desktop" FullScreenScreenShot "Ctrl+Shift+3${TAB}Shift+Print"
svc "org.kde.spectacle.desktop" RectangularRegionScreenShot "Ctrl+Shift+4"
svc "org.kde.spectacle.desktop" ActiveWindowScreenShot "Ctrl+Shift+6"

# ---------------------------------------------------------------------------
# 3. Verification
# ---------------------------------------------------------------------------
if [ "$VERIFY" = 1 ]; then
    head_ "keyd"
    [ "$(systemctl is-active keyd)" = active ] && ok "keyd running" || bad "keyd not running"
    if printf '%s\n' "$KEYD_CONF" | sudo cmp -s - /etc/keyd/default.conf; then
        ok "/etc/keyd/default.conf matches this script"
    else
        bad "/etc/keyd/default.conf differs (50-mac-keyboard.sh ran last?)"
    fi
    if sudo journalctl -u keyd -n 40 --no-pager 2>/dev/null | grep -qi "ERROR\|invalid"; then
        bad "keyd logged a config error"
    else
        ok "keyd parsed its config without errors"
    fi

    head_ "Collisions"
    # A global grab is consumed by the compositor before any window sees it, so
    # two actions on one chord means one of them silently never fires.
    python3 - <<'PY' || fail=1
import re, os, collections
p = os.path.expanduser("~/.config/kglobalshortcutsrc")
group, seen = None, collections.defaultdict(list)
for line in open(p):
    line = line.rstrip("\n")
    if line.startswith("["): group = line.strip(); continue
    # [services][x] mirrors the component group of the same name; counting both
    # would report every service shortcut as colliding with itself.
    if group and group.startswith("[services]"): continue
    if "=" not in line or line.startswith("_k_"): continue
    k, v = line.split("=", 1)
    # KConfig stores the alternate-separator tab as the two characters \t.
    for s in v.split(",")[0].replace("\\t", "\t").split("\t"):
        s = s.strip()
        if s and s.lower() != "none":
            seen[s].append(f"{group} {k}")
clash = {s: w for s, w in seen.items() if len(w) > 1}
if clash:
    for s, w in sorted(clash.items()):
        print(f"  \033[31m✗\033[0m {s} claimed by {len(w)}: {'; '.join(w)}")
    raise SystemExit(1)
print("  \033[32m✓\033[0m no chord is claimed by two actions")
PY

    head_ "Live session"
    # kwin_wayland owns org.kde.kglobalaccel and reads kglobalshortcutsrc only at
    # startup, so this says whether a re-login is still outstanding.
    # 0x11000001 = Meta+Tab.
    if gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
         --method org.kde.KGlobalAccel.getGlobalShortcutsByKey 285212673 2>/dev/null \
         | grep -q "Walk Through Windows"; then
        ok "Meta+Tab is live — the running session already has these bindings"
    else
        printf '  \033[33m!\033[0m written to disk but not live yet — log out and back in\n'
    fi

    head_ "$([ $fail = 0 ] && echo 'all checks passed' || echo 'CHECKS FAILED')"
    exit $fail
fi

cat <<'SUMMARY'

shortcuts: Cmd+Space search, Cmd+Tab switch, Cmd+M/H minimise, Cmd+C/V copy
           and paste (terminal included), Ctrl+Up overview, Cmd+Shift+3/4/5 shots
           Global shortcut changes apply at the NEXT LOGIN: on Wayland
           kwin_wayland reads kglobalshortcutsrc once, at startup.
           The keyd half is live immediately.
SUMMARY
