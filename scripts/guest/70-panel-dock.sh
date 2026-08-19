#!/usr/bin/env bash
# 70-panel-dock.sh — panel composition and window behaviour, Mac-shaped.
#
# Run INSIDE the guest, as the desktop user, with a Plasma Wayland session up:
#   bash scripts/guest/70-panel-dock.sh            # apply
#   bash scripts/guest/70-panel-dock.sh --verify   # read everything back
#
# 20-desktop-theme.sh already builds the two panels this desktop needs — an
# edge-to-edge top bar and a floating, shrink-wrapped bottom dock — and it
# rebuilds them from scratch on every login. This script runs afterwards and
# does the three things that layout was missing:
#
#   1. The global menu. KDE apps on this guest already export their menus over
#      DBus and then draw no menu bar of their own, because kded's appmenu
#      module is loaded and plasma-integration hands them a QDBusMenuBar the
#      moment a registrar exists. With nothing in the panel listening, those
#      menus went nowhere: Dolphin, Kate and System Settings were shipping a
#      menu bar to a surface that did not exist. Adding org.kde.plasma.appmenu
#      is not decoration here, it reconnects menus that were already detached.
#   2. Trash at the end of the dock, behind a separator — the one Dock item
#      macOS puts there and Plasma's default dock does not.
#   3. Window behaviour: click-to-focus, drag-to-edge tiling, an app-shaped
#      Alt+Tab, and a working modifier for move/resize-anywhere.
#
# Three constraints shape every choice below.
#
#   No GPU. Mesa is llvmpipe, so nothing per-pixel is enabled: the switcher is
#   icon-only rather than thumbnails, window highlighting during Alt+Tab is off,
#   and no screen edge triggers an effect on hover.
#
#   No Meta key. keyd rewrites Cmd to Control at the evdev layer (50-mac-
#   keyboard.sh), which also removes Meta as a modifier applications can see.
#   KWin's default modifier for "drag a window from anywhere" is Meta, so that
#   gesture was simply dead; section 4 moves it to Alt. Every keyboard shortcut
#   proper lives in kglobalshortcutsrc, which another script owns — this one
#   never writes that file.
#
#   Shared config. kwinrc and plasma-org.kde.plasma.desktop-appletsrc are
#   written by several scripts, so every change here is a single key through
#   kwriteconfig6, or goes through the Plasma scripting API. No file is ever
#   rewritten whole.
#
# ---------------------------------------------------------------------------
# The evaluateScript trap
# ---------------------------------------------------------------------------
# org.kde.PlasmaShell.evaluateScript reports success to some D-Bus clients even
# when the JavaScript it was handed threw, which is how a panel-building script
# can "succeed" and leave no panel at all. Three defences are used here:
#
#   * gdbus, not dbus-send or qdbus. gdbus does surface the JS exception as a
#     D-Bus error and a non-zero exit, verified on this guest for both a
#     SyntaxError and a ReferenceError.
#   * every script prints an LOM70 sentinel as its last statement, so a run that
#     threw part way through is detectable from the output alone.
#   * the plasmashell journal is checked for JS errors logged since this run
#     started, not since some fixed window.
#
# And the JavaScript is written to a file and passed as "$(cat file)", never
# inlined through a heredoc into a D-Bus command line.
#
# ---------------------------------------------------------------------------
# Why the applets are positioned by coordinate
# ---------------------------------------------------------------------------
# A panel's live applet order is not p.widgetIds — that is creation order. The
# order on screen comes from the AppletOrder config key, which the panel QML
# reads exactly once, in LayoutManager.restore() at panel load. Writing
# AppletOrder afterwards does nothing; worse, LayoutManager.save() runs on every
# applet add or remove and overwrites it with the real on-screen order.
#
# Two consequences, both used below:
#
#   * To place an applet, pass coordinates: addWidget(plugin, x, y) reaches
#     LayoutManager.addApplet(), which inserts at indexAtCoordinates(x, y).
#     x=100 on this 1470pt-wide top bar lands between the launcher's midpoint
#     and the spacer's midpoint, which is index 1 whether the launcher is 24pt
#     or 40pt wide.
#   * To read the live order back, read AppletOrder — because Plasma wrote it,
#     it is the on-screen truth, and mapping its ids through widgetById gives a
#     verifiable list of plugin names in display order.
#
# ---------------------------------------------------------------------------
# Deliberately not done
# ---------------------------------------------------------------------------
#   Virtual desktops. Left at one. Plasma reaches them by Meta+number and by the
#   Overview effect, and this guest has neither a Meta key nor a shortcut file
#   this script may write. A pager applet would be the only handle left, and a
#   Spaces switcher you can reach only by clicking a panel widget is worse than
#   no Spaces at all. The whole VM already lives on one macOS Space.
#
#   Hot corners. macOS ships with them off, and the top-left corner is where the
#   menu bar's leftmost item is; an Overview effect firing while someone reaches
#   for the launcher would be both wrong and, on llvmpipe, slow. Every screen
#   edge action is set to None. Drag-to-edge tiling is unaffected — that is a
#   drag, not a hover, and cannot fire by accident.
#
#   The systray item list. It lives in the systray containment, which
#   20-desktop-theme.sh recreates with a fresh id on every login, so anything
#   written there is stale within one boot. Plasma already auto-hides passive
#   items behind the arrow, which leaves the bar about as sparse as macOS's.
#
# ---------------------------------------------------------------------------
# The appmenu circuit breaker
# ---------------------------------------------------------------------------
# docs/DESKTOP-THEME.md records an incident in which org.kde.plasma.appmenu
# wedged plasmashell: the applet registers against kded's appmenu module with a
# blocking DBus call, and if that module is slow or absent, the shell blocks in
# request_wait_answer and the whole desktop stops.
#
# Because this script re-runs at every login, a wedge would be permanent rather
# than a one-off. So the applet is added only behind a breaker:
#
#   * the registrar is pinged first, and skipped entirely if it does not answer;
#   * state is written BEFORE the applet is added, so a run that never came back
#     leaves "attempting" behind, and the next run reads that as a crash and
#     refuses to try again;
#   * plasmashell is health-checked after, and a failure latches "broken".
#
# Recovery from a latched breaker: delete
# ~/.local/state/linuxonmac/70-panel-dock.state. To opt out without deleting
# anything, run with LOM_APPMENU=0.

set -uo pipefail

MODE="apply"
case "${1:-}" in
    --verify) MODE="verify" ;;
    "")       ;;
    *)        printf 'usage: %s [--verify]\n' "$0" >&2; exit 2 ;;
esac

WANT_APPMENU="${LOM_APPMENU:-1}"

ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
err()   { printf '  \033[31m✗\033[0m %s\n' "$*"; }
step()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

# --- session env -------------------------------------------------------------
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

APPLETSRC="${HOME}/.config/plasma-org.kde.plasma.desktop-appletsrc"
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/linuxonmac"
STATE_FILE="${STATE_DIR}/70-panel-dock.state"
JS_DIR="${XDG_RUNTIME_DIR}/linuxonmac-70"
SWITCHER_DIR="/usr/share/kwin/tabbox/big_icons"

mkdir -p "$STATE_DIR" "$JS_DIR" 2>/dev/null

for t in kwriteconfig6 kreadconfig6 gdbus awk; do
    command -v "$t" >/dev/null || { err "missing required tool: $t"; exit 1; }
done

# Everything logged by plasmashell from here on is attributable to this run.
# journalctl --since takes a local timestamp, which is what date prints.
RUN_START="$(date '+%Y-%m-%d %H:%M:%S')"

state_get() { [ -f "$STATE_FILE" ] && awk -F= -v k="$1" '$1==k{print $2}' "$STATE_FILE" | tail -1; }
state_set() {
    local k="$1" v="$2" tmp="${STATE_FILE}.tmp"
    { [ -f "$STATE_FILE" ] && grep -v "^${k}=" "$STATE_FILE"; printf '%s=%s\n' "$k" "$v"; } > "$tmp" 2>/dev/null
    mv -f "$tmp" "$STATE_FILE" 2>/dev/null
    sync 2>/dev/null
}

# Run a JS file through plasmashell. gdbus surfaces a JS exception as a D-Bus
# error and a non-zero exit; a long explicit timeout keeps a slow shell from
# looking like a failure and inviting a second, racing attempt.
plasma_eval_file() {
    timeout 200 gdbus call --session --dest org.kde.plasmashell \
        --object-path /PlasmaShell --method org.kde.PlasmaShell.evaluateScript \
        --timeout 180 "$(cat "$1")" 2>&1
}

plasmashell_alive() {
    timeout 40 gdbus call --session --dest org.kde.plasmashell \
        --object-path /PlasmaShell --method org.kde.PlasmaShell.evaluateScript \
        --timeout 30 'print("alive")' 2>/dev/null | grep -q alive
}

# The live, on-screen applet order of one containment, as plugin names.
# AppletOrder is written by Plasma's own LayoutManager.save(), so it is the
# display order — unlike the creation order the scripting API reports.
live_order() {
    local loc="$1"          # 3 = top edge, 4 = bottom edge
    [ -f "$APPLETSRC" ] || return 0
    awk -v want="$loc" '
        /^\[Containments\]\[[0-9]+\]$/ {
            cid = $0; gsub(/[^0-9]/, "", cid); ctx = "cont"; next
        }
        /^\[Containments\]\[[0-9]+\]\[Applets\]\[[0-9]+\]$/ {
            n = split($0, a, /\]\[/); aid = a[4]; gsub(/[^0-9]/, "", aid)
            acid = a[2]; gsub(/[^0-9]/, "", acid)
            ctx = "applet"; next
        }
        /^\[Containments\]\[[0-9]+\]\[General\]$/ {
            gid = $0; gsub(/\[Containments\]\[/, "", gid); gsub(/\].*/, "", gid)
            ctx = "general"; next
        }
        /^\[/ { ctx = "other"; next }
        ctx == "cont"    && /^location=/  { loc[cid]  = substr($0, 10) }
        ctx == "cont"    && /^plugin=/    { plug[cid] = substr($0, 8) }
        ctx == "applet"  && /^plugin=/    { type[acid "/" aid] = substr($0, 8) }
        ctx == "general" && /^AppletOrder=/ { ord[gid] = substr($0, 13) }
        END {
            for (c in loc) {
                if (loc[c] != want || plug[c] != "org.kde.panel") continue
                n = split(ord[c], ids, ";")
                out = ""
                for (i = 1; i <= n; i++) {
                    t = type[c "/" ids[i]]
                    if (t == "") continue
                    sub(/^org\.kde\.plasma\./, "", t); sub(/^org\.kde\./, "", t)
                    out = (out == "") ? t : out " " t
                }
                print out
                exit
            }
        }
    ' "$APPLETSRC"
}

# kwriteconfig6 --file kwinrc, but reports what it set so --verify has something
# to compare against and an apply run reads as a list of decisions.
kwin_set() {  # group key value
    kwriteconfig6 --file kwinrc --group "$1" --key "$2" "$3" 2>/dev/null
}
kwin_get() {
    kreadconfig6 --file kwinrc --group "$1" --key "$2" 2>/dev/null
}

###############################################################################
if [ "$MODE" = "apply" ]; then
###############################################################################

###############################################################################
step "1. Window switcher package"
###############################################################################
# KWin ships only the thumbnail-grid switcher; the icon-only ones live in
# kwin-addons. "Large Icons" is a row of application icons with a caption,
# which is both what Cmd+Tab looks like and the cheapest switcher available —
# no live window thumbnails means no compositing work while it is open.
if [ -d "$SWITCHER_DIR" ]; then
    ok "kwin-addons present (big_icons switcher available)"
else
    if sudo nice -n 19 apt-get -o DPkg::Lock::Timeout=900 install -y kwin-addons \
            >/tmp/lom70-apt.log 2>&1; then
        ok "installed kwin-addons"
    else
        warn "kwin-addons install failed (see /tmp/lom70-apt.log) — keeping the stock switcher"
    fi
fi

###############################################################################
step "2. Global menu — is it safe to add?"
###############################################################################
APPMENU_OK=0
BREAKER="$(state_get appmenu)"

if [ "$WANT_APPMENU" = "0" ]; then
    warn "LOM_APPMENU=0 — global menu disabled by request"
elif [ "$BREAKER" = "broken" ]; then
    warn "breaker latched: a previous run left plasmashell unresponsive after adding"
    warn "the global menu. Not retrying. Clear it with: rm $STATE_FILE"
elif [ "$BREAKER" = "attempting" ]; then
    # Written before the applet was added and never overwritten, which means the
    # run that wrote it did not survive to confirm. That is the wedge.
    err "previous run recorded 'attempting' and never completed — latching breaker"
    state_set appmenu broken
elif ! timeout 15 gdbus call --session --dest org.kde.kappmenu --object-path /KAppMenu \
        --method org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1; then
    warn "org.kde.kappmenu is not answering — skipping the global menu this run"
    warn "(not latching the breaker: an absent registrar is a transient condition)"
else
    ok "org.kde.kappmenu answered — registrar is live, blocking registration will return"
    APPMENU_OK=1
fi

###############################################################################
step "3. Panel composition"
###############################################################################
if ! plasmashell_alive; then
    err "plasmashell is not answering evaluateScript — skipping all panel work."
    err "Everything in sections 4-7 still applies; re-run once the shell is healthy."
else
    cat > "${JS_DIR}/panels.js" <<JSEOF
var WANT_APPMENU = $( [ "$APPMENU_OK" = 1 ] && echo true || echo false );
JSEOF
    cat >> "${JS_DIR}/panels.js" <<'JSEOF'
var out = [];

// The scripting API's widgetIds is creation order. The display order is the
// AppletOrder config key, which Plasma itself keeps current.
function liveOrder(p) {
    p.currentConfigGroup = ["General"];
    var raw = String(p.readConfig("AppletOrder") || "");
    var ids = (raw.length > 0) ? raw.split(";") : [];
    var res = [];
    for (var i = 0; i < ids.length; i++) {
        var id = parseInt(ids[i], 10);
        if (isNaN(id)) { continue; }
        var w = null;
        try { w = p.widgetById(id); } catch (e) { w = null; }
        if (w) { res.push({ id: id, type: String(w.type) }); }
    }
    // A panel built moments ago may not have saved yet; creation order is then
    // the display order, because nothing has been moved.
    if (res.length === 0) {
        var wid = p.widgetIds;
        for (var j = 0; j < wid.length; j++) {
            try { res.push({ id: wid[j], type: String(p.widgetById(wid[j]).type) }); } catch (e) {}
        }
    }
    return res;
}

function indexOfType(list, t) {
    for (var i = 0; i < list.length; i++) { if (list[i].type === t) { return i; } }
    return -1;
}

function removeAllOfType(p, t) {
    var n = 0, ids = p.widgetIds;
    for (var i = 0; i < ids.length; i++) {
        var w = null;
        try { w = p.widgetById(ids[i]); } catch (e) { w = null; }
        if (w && String(w.type) === t) { w.remove(); n++; }
    }
    return n;
}

function findPanel(where) {
    for (var i = 0; i < panelIds.length; i++) {
        var p = panelById(panelIds[i]);
        if (p.location === where) { return p; }
    }
    return null;
}

// --- top bar ---------------------------------------------------------------
var bar = findPanel("top");
if (bar === null) {
    // Safety net. Nothing should reach this: 20-desktop-theme.sh builds the top
    // bar. But a run that leaves no panel at all is the one unacceptable
    // outcome, so build a complete one rather than bail.
    out.push("top:MISSING-rebuilt");
    bar = new Panel("org.kde.panel");
    bar.location = "top";
    bar.height = 32;
    bar.floating = false;
    bar.lengthMode = "fill";
    bar.alignment = "center";
    bar.hiding = "none";
    bar.currentConfigGroup = ["General"];
    bar.writeConfig("panelOpacity", 2);
    bar.addWidget("org.kde.plasma.kickoff");
    if (WANT_APPMENU) { bar.addWidget("org.kde.plasma.appmenu"); }
    var sp = bar.addWidget("org.kde.plasma.panelspacer");
    sp.currentConfigGroup = ["General"];
    sp.writeConfig("expanding", true);
    bar.addWidget("org.kde.plasma.systemtray");
    var ck = bar.addWidget("org.kde.plasma.digitalclock");
    ck.currentConfigGroup = ["Appearance"];
    ck.writeConfig("showDate", true);
    ck.writeConfig("dateDisplayFormat", 1);
    ck.writeConfig("dateFormat", "custom");
    ck.writeConfig("customDateFormat", "ddd d MMM");
    ck.writeConfig("showSeconds", 0);
    bar.addWidget("org.kde.plasma.showdesktop");
}

if (WANT_APPMENU) {
    var ord = liveOrder(bar);
    var ai = indexOfType(ord, "org.kde.plasma.appmenu");
    var ki = indexOfType(ord, "org.kde.plasma.kickoff");
    // macOS puts the app's menus immediately right of the Apple menu; here that
    // is immediately right of the launcher, or leftmost if there is none.
    var want = (ki >= 0) ? ki + 1 : 0;
    if (ai >= 0 && ai !== want) {
        removeAllOfType(bar, "org.kde.plasma.appmenu");
        ai = -1;
        out.push("appmenu:repositioning");
    }
    if (ai < 0) {
        // x=100 is past the launcher's midpoint and short of the spacer's, so
        // indexAtCoordinates() returns 1 for any plausible launcher width.
        var am = bar.addWidget("org.kde.plasma.appmenu", 100, 16);
        am.currentConfigGroup = ["Appearance"];
        am.writeConfig("compactView", false);   // the full menu bar, not one button
        out.push("appmenu:added-at-" + want);
    } else {
        out.push("appmenu:already-at-" + ai);
    }
} else {
    // Either the breaker latched or LOM_APPMENU=0. Both mean "this desktop must
    // not have a global menu", which has to include one a previous run left
    // behind — otherwise turning it off does nothing until the next time
    // 20-desktop-theme.sh happens to rebuild the bar.
    var gone = removeAllOfType(bar, "org.kde.plasma.appmenu");
    if (gone > 0) { out.push("appmenu:removed-" + gone); }
}

// --- dock ------------------------------------------------------------------
var dock = findPanel("bottom");
if (dock === null) {
    out.push("dock:MISSING-rebuilt");
    dock = new Panel("org.kde.panel");
    dock.location = "bottom";
    dock.height = 56;
    dock.floating = true;
    dock.lengthMode = "fit";      // shrink-wraps to its icons, like the Dock
    dock.alignment = "center";
    dock.hiding = "none";
    dock.currentConfigGroup = ["General"];
    dock.writeConfig("panelOpacity", 2);
    var tasks = dock.addWidget("org.kde.plasma.icontasks");
    tasks.currentConfigGroup = ["General"];
    tasks.writeConfig("launchers", [
        "applications:org.kde.dolphin.desktop",
        "applications:firefox-esr.desktop",
        "applications:org.kde.konsole.desktop",
        "applications:org.kde.kate.desktop",
        "applications:org.kde.spectacle.desktop",
        "applications:systemsettings.desktop"
    ].join(","));
    tasks.writeConfig("groupingStrategy", 1);
    tasks.writeConfig("maxStripes", 1);
    tasks.writeConfig("showOnlyCurrentDesktop", false);
    tasks.writeConfig("showOnlyCurrentScreen", false);
    tasks.writeConfig("showOnlyCurrentActivity", false);
    tasks.writeConfig("wheelEnabled", false);
}

// Trash at the far end behind a divider, which is the one piece of the macOS
// Dock that Plasma's default dock has no equivalent of. addWidget() without
// coordinates appends, so the pair naturally lands last — but only if both are
// absent or both already last, hence the rebuild-the-tail branch.
var dord = liveOrder(dock);
var n  = dord.length;
var si = indexOfType(dord, "org.kde.plasma.marginsseparator");
var ti = indexOfType(dord, "org.kde.plasma.trash");
if (si === n - 2 && ti === n - 1 && n >= 2) {
    out.push("dock:tail-ok");
} else {
    removeAllOfType(dock, "org.kde.plasma.marginsseparator");
    removeAllOfType(dock, "org.kde.plasma.trash");
    dock.addWidget("org.kde.plasma.marginsseparator");
    dock.addWidget("org.kde.plasma.trash");
    out.push("dock:tail-rebuilt");
}

print("LOM70 " + out.join(" | "));
JSEOF

    if [ "$APPMENU_OK" = 1 ]; then
        # Written before the applet is instantiated. If the shell wedges here,
        # this is the evidence the next run needs.
        state_set appmenu attempting
    fi

    PANEL_OUT="$(plasma_eval_file "${JS_DIR}/panels.js")"
    printf '  %s\n' "$(printf '%s' "$PANEL_OUT" | tr -d "()',")"

    case "$PANEL_OUT" in
        *LOM70*)
            ok "panel script ran to completion (sentinel present)"
            if [ "$APPMENU_OK" = 1 ]; then
                if plasmashell_alive; then
                    state_set appmenu ok
                    ok "plasmashell healthy after adding the global menu"
                else
                    state_set appmenu broken
                    err "plasmashell stopped answering after the global menu was added."
                    err "Breaker latched; the next login rebuilds the bar without it."
                fi
            fi
            ;;
        *)
            err "panel script did not reach its sentinel — plasmashell reported:"
            printf '    %s\n' "$PANEL_OUT"
            [ "$APPMENU_OK" = 1 ] && state_set appmenu broken
            ;;
    esac
fi

###############################################################################
step "4. Focus, raise and placement"
###############################################################################
# Click to focus, and clicking raises — the macOS model. Focus never follows the
# pointer and nothing auto-raises on hover, so a window under the cursor while
# you type into another one stays out of the way.
kwin_set Windows FocusPolicy ClickToFocus
kwin_set Windows AutoRaise false
kwin_set Windows AutoRaiseInterval 0
kwin_set Windows DelayFocusInterval 0
kwin_set Windows ClickRaise true
kwin_set Windows NextFocusPrefersMouse false
# Low. A window that asks for focus while you are typing elsewhere gets its
# entry marked instead of stealing the keyboard, which is what macOS does with
# a bouncing Dock icon.
kwin_set Windows FocusStealingPreventionLevel 1
# Zoom on double-click, as on macOS.
kwin_set Windows TitlebarDoubleClickCommand Maximize
# The desktop is 1470x956 logical. Centred beats cascaded at that size: a
# cascade walks new windows off the bottom-right within four or five windows.
kwin_set Windows Placement Centered
kwin_set Windows RollOverDesktops false
kwin_set Windows SeparateScreenFocus false
ok "click-to-focus, click-raises, no auto-raise, centred placement, double-click zooms"

###############################################################################
step "5. Snapping and drag-to-edge tiling"
###############################################################################
# macOS 15 tiles on a drag to an edge or a corner; KWin has done it for years
# and calls it electric borders. Halves at the edges, quarters in the corners,
# maximise at the top.
kwin_set Windows ElectricBorderMaximize true
kwin_set Windows ElectricBorderTiling true
kwin_set Windows ElectricBorderCornerRatio 0.25
# A small magnetic pull to screen edges and to other windows. macOS has none of
# this, but 8pt is below the threshold where it feels like the window is being
# taken away from you, and it makes edge alignment on a small desktop painless.
kwin_set Windows BorderSnapZone 8
kwin_set Windows WindowSnapZone 8
kwin_set Windows CenterSnapZone 0
kwin_set Windows SnapOnlyWhenOverlapping false
ok "drag-to-edge halves/quarters/maximise; 8pt snap to edges and windows"

###############################################################################
step "6. Screen edges — nothing on hover"
###############################################################################
# Every hover action off. macOS ships hot corners disabled, the top-left corner
# here holds the launcher and the top-right holds the clock, and on llvmpipe an
# Overview effect firing by accident is expensive as well as wrong. Tiling in
# section 5 is unaffected: that is a drag, not a hover.
for edge in Top TopRight Right BottomRight Bottom BottomLeft Left TopLeft; do
    kwin_set ElectricBorders "$edge" None
done
kwin_set TabBox BorderActivate 9
kwin_set TabBox BorderAlternativeActivate 9
kwin_set Effect-overview BorderActivate 9
kwin_set Effect-overview BorderActivateAll 9
kwin_set Effect-windowview BorderActivate 9
kwin_set Effect-windowview BorderActivateAll 9
kwin_set Effect-windowview BorderActivateClass 9
# kwin-addons ships the desktop cube; it is per-pixel work and there is one
# virtual desktop for it to spin.
kwin_set Plugins cubeEnabled false
ok "all eight edges and corners inert; overview/windowview/cube unbound"

###############################################################################
step "7. Task switcher"
###############################################################################
# One entry per application, most-recently-used order, icons not thumbnails:
# Cmd+Tab, as closely as an Alt+Tab can manage.
#
# ApplicationsMode is TabBoxConfig::ClientApplicationsMode —
#   0 AllWindowsAllApplications, 1 AllWindowsCurrentApplication,
#   2 OneWindowPerApplication.
# The KCM exposes 2 as the "Only one window per application" checkbox.
if [ -d "$SWITCHER_DIR" ]; then
    kwin_set TabBox LayoutName big_icons
else
    warn "big_icons switcher not installed — leaving LayoutName alone"
fi
kwin_set TabBox ApplicationsMode 2
kwin_set TabBox SwitchingMode 0        # 0 = recently used
kwin_set TabBox MinimizedMode 0        # 0 = minimized windows included
kwin_set TabBox DesktopMode 0          # 0 = all desktops
kwin_set TabBox ActivitiesMode 0       # 0 = all activities
kwin_set TabBox MultiScreenMode 0      # 0 = all screens
kwin_set TabBox ShowDesktopMode 0      # no synthetic "Show Desktop" entry
kwin_set TabBox ShowTabBox true
# Fading every other window out to highlight the selection is a full-screen
# per-pixel pass on a software rasterizer, and macOS does not do it.
kwin_set TabBox HighlightWindows false
kwin_set TabBoxAlternative LayoutName thumbnail_grid
kwin_set TabBoxAlternative ApplicationsMode 0
kwin_set TabBoxAlternative HighlightWindows false
ok "Alt+Tab: large icons, one entry per app, most-recently-used, no highlighting"

###############################################################################
step "8. Move and resize from anywhere"
###############################################################################
# KWin's default modifier for grabbing a window without aiming at its titlebar
# is Meta, and keyd has rewritten Meta to Control at the evdev layer, so that
# gesture currently does not exist. Alt restores it: Alt+drag moves, Alt+right-
# drag resizes. Alt is the historical X11 binding, so nothing here is surprising
# to a Linux user either.
kwin_set MouseBindings CommandAllKey Alt
kwin_set MouseBindings CommandAll1 Move
kwin_set MouseBindings CommandAll2 "Toggle raise and lower"
kwin_set MouseBindings CommandAll3 Resize
# Alt+scroll must not resize windows out from under a scrolling gesture.
kwin_set MouseBindings CommandAllWheel Nothing
ok "Alt+drag moves, Alt+right-drag resizes, Alt+scroll does nothing"

###############################################################################
step "9. Apply"
###############################################################################
# KWin re-reads its config in place. Unlike restarting plasmashell this tears
# down no Wayland surfaces, so it is safe on this VM.
if timeout 30 gdbus call --session --dest org.kde.KWin --object-path /KWin \
        --method org.kde.KWin.reconfigure >/dev/null 2>&1; then
    ok "kwin reconfigured — sections 4-8 are live now"
else
    warn "kwin did not answer reconfigure; sections 4-8 apply at the next login"
fi

fi  # end apply
###############################################################################

###############################################################################
step "Verification"
###############################################################################

# Plasma writes AppletOrder from its own event loop, a beat after the applet is
# added. Reading the file too early sees the pre-add order.
[ "$MODE" = "apply" ] && sleep 3

FAIL=0
note_fail() { err "$*"; FAIL=1; }

# --- panels -----------------------------------------------------------------
NPANEL=$(grep -c '^plugin=org\.kde\.panel$' "$APPLETSRC" 2>/dev/null)
case "${NPANEL:-0}" in
    2) ok "panel containments in appletsrc: 2 (top bar + dock)" ;;
    0) note_fail "NO PANEL AT ALL — re-run 20-desktop-theme.sh, then this script" ;;
    *) note_fail "${NPANEL} panel containments (expected 2)" ;;
esac

TOPBAR="$(live_order 3)"
DOCK="$(live_order 4)"
printf '  top bar : %s\n' "${TOPBAR:-<none>}"
printf '  dock    : %s\n' "${DOCK:-<none>}"

case "$TOPBAR" in
    *appmenu*) ok "global menu present in the top bar" ;;
    "")        note_fail "top bar has no readable applet order" ;;
    *)         if [ "${LOM_APPMENU:-1}" = "0" ]; then
                   ok "global menu absent (LOM_APPMENU=0)"
               else
                   warn "global menu absent — breaker=$(state_get appmenu), see $STATE_FILE"
               fi ;;
esac
case "$TOPBAR" in
    "kickoff appmenu "*) ok "global menu sits immediately right of the launcher" ;;
    *appmenu*)           warn "global menu is present but not in slot 2" ;;
esac
case "$DOCK" in
    *"marginsseparator trash") ok "dock ends with separator + trash" ;;
    "")                        note_fail "dock has no readable applet order" ;;
    *)                         warn "dock tail is not separator+trash" ;;
esac

# --- plasmashell health -----------------------------------------------------
if plasmashell_alive; then
    ok "plasmashell answers evaluateScript"
else
    note_fail "plasmashell is NOT answering evaluateScript"
fi

JSERR="$(journalctl --user -u plasma-plasmashell --since "$RUN_START" --no-pager 2>/dev/null \
         | grep -E 'SyntaxError|ReferenceError|is not defined|is not a function' | head -5)"
if [ -n "$JSERR" ]; then
    note_fail "plasmashell logged JavaScript errors during this run:"
    printf '    %s\n' "$JSERR"
else
    ok "no JavaScript errors in the plasmashell journal since this run started"
fi

# --- kwin -------------------------------------------------------------------
check() {  # group key expected
    local got; got="$(kwin_get "$1" "$2")"
    if [ "$got" = "$3" ]; then
        printf '  \033[32m✓\033[0m %-22s %-28s = %s\n' "[$1]" "$2" "$got"
    else
        printf '  \033[31m✗\033[0m %-22s %-28s = %s (expected %s)\n' "[$1]" "$2" "${got:-<unset>}" "$3"
        FAIL=1
    fi
}
check Windows       FocusPolicy               ClickToFocus
check Windows       ClickRaise                true
check Windows       AutoRaise                 false
check Windows       TitlebarDoubleClickCommand Maximize
check Windows       Placement                 Centered
check Windows       ElectricBorderTiling      true
check Windows       ElectricBorderMaximize    true
check Windows       BorderSnapZone            8
check Windows       WindowSnapZone            8
check TabBox        ApplicationsMode          2
check TabBox        SwitchingMode             0
check TabBox        HighlightWindows          false
check MouseBindings CommandAllKey             Alt
check MouseBindings CommandAllWheel           Nothing
check ElectricBorders TopLeft                 None
check ElectricBorders TopRight                None
if [ -d "$SWITCHER_DIR" ]; then
    check TabBox LayoutName big_icons
else
    warn "kwin-addons not installed — big_icons switcher unavailable"
fi

# The other agents' invariants, checked because this script writes the same
# files and must be seen not to have disturbed them.
printf '  \033[2m-- untouched by this script, checked anyway --\033[0m\n'
printf '    titlebar buttons left = %s   blur = %s   scale = %s\n' \
    "$(kwin_get org.kde.kdecoration2 ButtonsOnLeft)" \
    "$(kwin_get Plugins blurEnabled)" \
    "$(kreadconfig6 --file kdeglobals --group KScreen --key ScaleFactor 2>/dev/null)"

printf '\n'
if [ "$FAIL" = 0 ]; then
    printf '  \033[1;32mPASS\033[0m panel, dock and window behaviour verified\n'
else
    printf '  \033[1;31mFAIL\033[0m see the marked lines above\n'
fi

if [ "$MODE" = "apply" ]; then
    cat <<'MSG'

  Live now             : everything in sections 4-8 (kwin reconfigured in place),
                         and the panel changes in section 3.
  Needs an app restart : the global menu only picks up applications started
                         after it existed. Already-open KDE apps keep drawing
                         nothing where their menu bar would be until relaunched.
  Not covered          : GTK apps and Firefox do not export menus over DBus and
                         keep their own in-window menus. That is a property of
                         those toolkits, not of this configuration.
MSG
fi

exit "$FAIL"
