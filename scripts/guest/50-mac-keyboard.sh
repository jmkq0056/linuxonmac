#!/usr/bin/env bash
# Makes the Command key behave like Command, everywhere.
#
# KDE's own shortcut system can only add Meta+ alternates for Qt/KDE apps, and
# Plasma already grabs most Meta+letter combinations before any application sees
# them — so Firefox, VS Code and every GTK app keep using Ctrl. keyd rewrites
# events at the evdev layer, below the display server, so the remap is universal.
#
# Physical Control is deliberately left alone: Ctrl+C must keep sending SIGINT.
# The cost is that Cmd+C in a terminal also sends SIGINT, so terminal copy stays
# Ctrl+Shift+C. Fixing that needs per-application awareness (xremap with its KWin
# script), which keyd cannot do.
set -euo pipefail

if ! command -v keyd >/dev/null; then
    sudo apt-get -o DPkg::Lock::Timeout=900 install -y keyd
fi

sudo mkdir -p /etc/keyd
sudo tee /etc/keyd/default.conf >/dev/null <<'CONF'
[ids]
*

[main]
leftmeta = leftcontrol
rightmeta = leftcontrol
CONF

sudo systemctl enable keyd >/dev/null
sudo systemctl restart keyd

# Cmd arrives as Control now, so the Cmd+Space reflex needs KRunner on Ctrl+Space.
kwriteconfig6 --file kglobalshortcutsrc --group krunner.desktop \
    --key _launch "Ctrl+Space\tAlt+Space\tAlt+F2,Alt+Space\tAlt+F2,KRunner"

echo "keyd: $(systemctl is-active keyd)"
