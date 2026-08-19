#!/usr/bin/env bash
# Checks that everything configured in the guest is actually in effect.
#
# Run it, reboot the guest, run it again. Anything that changes between the two
# runs was never really persisted — Plasma in particular rewrites its config
# from memory when it exits, so a setting written while it was running can be
# reverted on logout without anything reporting an error.
set -uo pipefail

GUEST="${GUEST:-192.168.64.7}"
KEY="${KEY:-$HOME/.ssh/linuxonmac}"
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=15 "jmkq@$GUEST")

pass=0; fail=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        printf '  ok    %-34s %s\n' "$label" "$actual"; pass=$((pass + 1))
    else
        printf '  FAIL  %-34s got %-22s want %s\n' "$label" "${actual:-<empty>}" "$expected"; fail=$((fail + 1))
    fi
}
present() {
    local label="$1" actual="$2"
    if [ -n "$actual" ] && [ "$actual" != "MISSING" ]; then
        printf '  ok    %-34s %s\n' "$label" "$actual"; pass=$((pass + 1))
    else
        printf '  FAIL  %-34s not present\n' "$label"; fail=$((fail + 1))
    fi
}

echo "Verifying guest at $GUEST"
echo

raw=$("${SSH[@]}" 'bash -s' <<'REMOTE'
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
       DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
D="Apple Inc. Virtual USB Digitizer"
V=1452; P=33030
echo "natural_scroll=$(kreadconfig6 --file kwinrc --group Libinput --group $V --group $P --group "$D" --key NaturalScroll)"
echo "scroll_factor=$(kreadconfig6 --file kwinrc --group Libinput --group $V --group $P --group "$D" --key ScrollFactor)"
echo "icon_theme=$(kreadconfig6 --file kdeglobals --group Icons --key Theme)"
echo "login_shell=$(getent passwd jmkq | cut -d: -f7)"
echo "node=$(command -v node >/dev/null && node --version || echo MISSING)"
echo "claude=$(command -v claude >/dev/null && claude --version 2>/dev/null | head -1 || echo MISSING)"
echo "clipboard_enabled=$(systemctl --user is-enabled clipboard-agent 2>/dev/null)"
echo "clipboard_active=$(systemctl --user is-active clipboard-agent 2>/dev/null)"
echo "mac_mount=$(findmnt -no TARGET /mnt/mac 2>/dev/null || echo MISSING)"
echo "rosetta_mount=$(findmnt -no TARGET /mnt/rosetta 2>/dev/null || echo MISSING)"
echo "fstab_entries=$(grep -c virtiofs /etc/fstab)"
echo "binfmt_rosetta=$(head -1 /proc/sys/fs/binfmt_misc/rosetta 2>/dev/null || echo MISSING)"
echo "autologin=$(grep -c '^User=jmkq' /etc/sddm.conf.d/autologin.conf 2>/dev/null || echo 0)"
echo "sudo_nopasswd=$(sudo -n true 2>/dev/null && echo yes || echo no)"
echo "panels=$(grep -c 'plugin=org.kde.panel' ~/.config/plasma-org.kde.plasma.desktop-appletsrc 2>/dev/null)"
echo "plasmashell=$(pgrep -c plasmashell)"
REMOTE
)

get() { echo "$raw" | grep "^$1=" | cut -d= -f2-; }

echo "input"
check "natural scroll"        "true"  "$(get natural_scroll)"
check "scroll factor"         "0.4"   "$(get scroll_factor)"
echo "shell and tooling"
check "login shell"           "/usr/bin/zsh" "$(get login_shell)"
present "node (non-interactive)"  "$(get node)"
present "claude code"             "$(get claude)"
echo "clipboard bridge"
check "unit enabled"          "enabled" "$(get clipboard_enabled)"
check "unit active"           "active"  "$(get clipboard_active)"
echo "filesystem"
check "/mnt/mac mounted"      "/mnt/mac"     "$(get mac_mount)"
check "/mnt/rosetta mounted"  "/mnt/rosetta" "$(get rosetta_mount)"
check "fstab virtiofs entries" "2"           "$(get fstab_entries)"
check "rosetta binfmt"        "enabled"      "$(get binfmt_rosetta)"
echo "session"
check "sddm autologin"        "1"   "$(get autologin)"
check "passwordless sudo"     "yes" "$(get sudo_nopasswd)"
check "panel containments"    "2"   "$(get panels)"
check "plasmashell instances" "1"   "$(get plasmashell)"
present "icon theme"          "$(get icon_theme)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
