#!/usr/bin/env bash
# Removes work the guest does for no benefit, and tunes Firefox for a GPU-less
# software-rendered desktop.
#
# WHAT THE MEASUREMENTS ACTUALLY SAID
#
# The compositor is the whole ballgame, and it is not tunable. A 10 s full-window
# scroll in Firefox at 1200x800 costs kwin_wayland ~40 s of CPU — about four
# cores — and a per-thread profile puts 42.0 s of a 42.3 s total inside the ten
# llvmpipe rasteriser threads, with kwin's own main thread using 0.32 s. That is
# ~10 megapixels per CPU-second: pure fill rate, nothing algorithmic to fix.
# Everything offered as a knob for it was measured and did nothing:
#
#   GLTextureFilter 2 / 1 / 0     40.7 / 40.6 / 40.1 s   (noise)
#   NightColor off                45.7 s vs 40.2 s on    (no gain)
#   Firefox window fullscreen     47-49 s                (no direct scanout;
#                                                         shm buffers can't be
#                                                         handed to the plane)
#   layout.frame_rate=30          36.9 fps, 43.5 s       (pref simply ignored)
#
# So this script does not touch KWin. There is no setting that makes llvmpipe
# fill faster, and adding keys that measured as noise would just be cargo cult.
#
# What IS worth having: the desktop costs 14.3% of a core whenever anything on
# screen animates at 60 Hz, 3.4% when nothing does, and 1.9% with every window
# hidden. The lever that survives is therefore "animate less and run less", which
# is what the two halves below do — Firefox stops animating what it does not need
# to, and a dozen daemons that cannot possibly be useful inside
# Virtualization.framework stop running at all.
#
# Be honest about the size of the second half: every background service disabled
# here was, together, using 2.5 s of CPU per 932 s of uptime — 0.27% of one core.
# It buys RAM, a slightly shorter boot, and no update-checker stealing the apt
# lock from the other guest scripts. It does not buy a faster desktop.
#
# Deliberately NOT touched: 60-graphics-performance.sh already owns
# QT_QUICK_BACKEND, QSG_RENDER_LOOP, output scale and the per-pixel KWin effects;
# 20-desktop-theme.sh owns NightColor and the fonts (already grayscale AA +
# slight hinting, which is the cheap option on a software rasteriser).
set -euo pipefail

VERIFY=0
[ "${1:-}" = "--verify" ] && VERIFY=1

ENV_FILE="$HOME/.config/environment.d/91-linuxonmac-ui-performance.conf"
AUTOSTART_DIR="$HOME/.config/autostart"

# Units that describe hardware Virtualization.framework does not emulate, or
# background chores with nothing to do on a machine whose packages are managed by
# these very scripts. Boot cost of the first five, from systemd-analyze blame:
# e2scrub_reap 187 ms, NetworkManager-wait-online 41 ms, ModemManager 42 ms,
# wpa_supplicant 35 ms, packagekit 53 ms.
SYSTEM_UNITS=(
    e2scrub_reap.service             # reaps stale e2scrub LVM snapshots; no LVM here
    NetworkManager-wait-online.service  # delays network-online.target for a virtio NIC
    ModemManager.service             # no modem can be attached to this VM
    wpa_supplicant.service           # no wireless device exists
    packagekit.service               # duplicate package backend; steals the apt lock
    bluetooth.service                # no Bluetooth controller is passed through
    cups.service                     # no printer, and printing goes via the host
    cups-browsed.service
    avahi-daemon.service             # mDNS discovery on a NAT'd guest interface
)

# User units, with their measured CPU over a 932 s session.
USER_UNITS=(
    obex.service                     # 13 ms  — Bluetooth object push
    mpris-proxy.service              # 17 ms  — Bluetooth media key bridge
)

# XDG autostarts, same session.
#   org.kde.discover.notifier  680 ms  — polls for updates the guest scripts own
#   org.kde.kdeconnect.daemon  170 ms  — pairs with a phone that cannot route here
#   org.kde.xwaylandvideobridge 139 ms — only used to screen-share X11 windows
AUTOSTARTS=(
    org.kde.discover.notifier
    org.kde.kdeconnect.daemon
    org.kde.xwaylandvideobridge
)

# --------------------------------------------------------------------- helpers

has_unit() { systemctl list-unit-files "$1" >/dev/null 2>&1 && \
             [ -n "$(systemctl list-unit-files --no-legend "$1" 2>/dev/null)" ]; }

user_ctl() { systemctl --user "$@" 2>/dev/null; }

ok=0; bad=0
# check DESC CMD...  -- runs CMD with `if`, so a failing check cannot trip set -e.
check() {
    desc=$1; shift
    if "$@" >/dev/null 2>&1; then printf '  ok    %s\n' "$desc"; ok=$((ok+1))
    else printf '  FAIL  %s\n' "$desc"; bad=$((bad+1)); fi
}
is_masked()      { [ "$(systemctl is-enabled "$1" 2>/dev/null || true)" = masked ]; }
is_masked_user() { [ "$(systemctl --user is-enabled "$1" 2>/dev/null || true)" = masked ]; }
kv_is()          { [ "$(kreadconfig6 --file "$1" --group "$2" --key "$3" 2>/dev/null || true)" = "$4" ]; }
ff_tuned() {
    n=0; t=0
    for d in "$HOME"/.mozilla/firefox/*/; do
        [ -f "$d/prefs.js" ] || continue
        n=$((n+1))
        grep -q 'linuxonmac ui-performance' "$d/user.js" 2>/dev/null && t=$((t+1))
    done
    [ "$n" -gt 0 ] && [ "$n" = "$t" ]
}

# ------------------------------------------------------------------- verify --

if [ "$VERIFY" = 1 ]; then
    echo "74-ui-performance --verify"

    check "baloo indexing disabled in baloofilerc" \
        grep -q '^Indexing-Enabled=false' "$HOME/.config/baloofilerc"
    check "kde-baloo.service masked" is_masked_user kde-baloo.service

    for u in "${SYSTEM_UNITS[@]}"; do
        has_unit "$u" || continue
        check "system unit masked: $u" is_masked "$u"
    done

    for u in "${USER_UNITS[@]}"; do
        [ -n "$(user_ctl list-unit-files --no-legend "$u" || true)" ] || continue
        check "user unit masked: $u" is_masked_user "$u"
    done

    for a in "${AUTOSTARTS[@]}"; do
        check "autostart suppressed: $a" \
            grep -q '^Hidden=true' "$AUTOSTART_DIR/$a.desktop"
    done

    check "screen locker auto-lock off" kv_is kscreenlockerrc Daemon Autolock false
    check "GSK_RENDERER=cairo in environment.d" grep -q '^GSK_RENDERER=cairo' "$ENV_FILE"
    check "firefox user.js present in every profile" ff_tuned

    printf '\n%d ok, %d failed\n' "$ok" "$bad"
    [ "$bad" = 0 ] || exit 1
    exit 0
fi

# ------------------------------------------------------------------- apply ---

# Baloo. It was already inactive when measured — Debian's autostart condition had
# it off and it had burned 15 ms all session — but nothing in the repo pinned it
# that way, so one stray `balooctl enable` or a fresh $HOME would put a
# filesystem crawler on a machine whose entire home is a virtiofs mount from
# macOS. Indexing over virtiofs is the worst case: every stat crosses to the host.
kwriteconfig6 --file baloofilerc --group "Basic Settings" --key "Indexing-Enabled" false
user_ctl stop kde-baloo.service || true
user_ctl mask kde-baloo.service || true

# System daemons for absent hardware.
for u in "${SYSTEM_UNITS[@]}"; do
    has_unit "$u" || continue
    sudo systemctl disable --now "$u" >/dev/null 2>&1 || true
    sudo systemctl mask "$u" >/dev/null 2>&1 || true
done

# User-session Bluetooth helpers.
for u in "${USER_UNITS[@]}"; do
    [ -n "$(user_ctl list-unit-files --no-legend "$u")" ] || continue
    user_ctl stop "$u" || true
    user_ctl mask "$u" || true
done

# XDG autostarts. A Hidden=true override in ~/.config/autostart shadows the
# system .desktop file without touching /etc/xdg, so package upgrades stay clean.
mkdir -p "$AUTOSTART_DIR"
for a in "${AUTOSTARTS[@]}"; do
    src=""
    for d in /etc/xdg/autostart "$HOME/.config/autostart"; do
        [ -f "$d/$a.desktop" ] && src="$d/$a.desktop"
    done
    [ -n "$src" ] || continue
    cat > "$AUTOSTART_DIR/$a.desktop" <<AUTOSTART
[Desktop Entry]
Type=Application
Name=$a
Exec=/bin/true
Hidden=true
X-GNOME-Autostart-enabled=false
AUTOSTART
done
pkill -f org.kde.xwaylandvideobridge >/dev/null 2>&1 || true
pkill -x kdeconnectd            >/dev/null 2>&1 || true
pkill -f DiscoverNotifier       >/dev/null 2>&1 || true

# The lock screen is a full QtQuick scene with the wallpaper behind it, i.e. one
# more thing for llvmpipe to fill, and it had already fired once during testing.
# There is no security boundary to defend here: the guest autologins and macOS
# owns the actual lock screen.
kwriteconfig6 --file kscreenlockerrc --group Daemon --key Autolock false
kwriteconfig6 --file kscreenlockerrc --group Daemon --key LockOnResume false

# GTK 4 defaults to the "ngl" renderer, which means llvmpipe emulating GL to draw
# flat 2D — the same trap QT_QUICK_BACKEND=software already sidesteps for Qt.
# Nothing on the guest currently links libgtk-4 (only the gtk4-* dev tools), so
# this is unmeasurable today and is here purely so the first GNOME app installed
# does not arrive on the slow path.
mkdir -p "$(dirname "$ENV_FILE")"
cat > "$ENV_FILE" <<'ENV'
GSK_RENDERER=cairo
ENV

# ------------------------------------------------------------------- firefox -
#
# Firefox is the heaviest app on the guest and the only one whose own settings
# move the needle. The prefs that did nothing measurable are left out and named
# in the header. What is left is the one thing the numbers did support — the
# desktop costs 14.3% of a core while something animates and 3.4% when nothing
# does — plus background chores that have no business running in a throwaway VM.
#
# user.js is re-read at every start, so these survive the user changing them in
# about:config; that is the point, since converge is the only thing keeping this
# guest configured.

FF_PREFS=$(cat <<'PREFS'
// linuxonmac ui-performance -- regenerated by scripts/guest/74-ui-performance.sh
// Do not hand-edit; converge overwrites this file at every graphical login.

// The single measured win. Compositing costs ~2.3 ms of CPU per frame, so any
// page that animates forever pins a seventh of a core in kwin for as long as it
// is on screen. prefers-reduced-motion makes well-behaved sites stop, and turns
// off Firefox's own tab/fullscreen transitions too.
user_pref("ui.prefersReducedMotion", 1);

// There is no GPU: state it once rather than let Firefox probe, fail and fall
// back at every start. gfx.canvas.accelerated would route 2D canvas through
// SWGL emulating GL; Skia's CPU path is the shorter road.
user_pref("gfx.webrender.software", true);
user_pref("gfx.canvas.accelerated", false);
user_pref("media.hardware-video-decoding.enabled", false);
user_pref("media.ffmpeg.vaapi.enabled", false);

// Background chores. Telemetry, crash pings and Pocket all cost network and
// wakeups on a VM that is rebuilt from scripts.
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("toolkit.telemetry.archive.enabled", false);
user_pref("browser.ping-centre.telemetry", false);
user_pref("extensions.pocket.enabled", false);
user_pref("browser.discovery.enabled", false);

// $HOME is a virtiofs mount from macOS, so every session-store write crosses to
// the host. Four times less often is still often enough to survive a crash.
user_pref("browser.sessionstore.interval", 60000);
PREFS
)

wrote=0
for p in "$HOME"/.mozilla/firefox/*/; do
    [ -f "$p/prefs.js" ] || continue
    printf '%s\n' "$FF_PREFS" > "$p/user.js"
    wrote=$((wrote+1))
done

# ------------------------------------------------------------------ summary --

printf 'ui-performance: baloo masked, %d system + %d user units masked, %d autostarts off, firefox tuned in %d profile(s)\n' \
    "${#SYSTEM_UNITS[@]}" "${#USER_UNITS[@]}" "${#AUTOSTARTS[@]}" "$wrote"
