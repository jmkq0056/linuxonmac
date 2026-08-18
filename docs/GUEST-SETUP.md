# Guest setup — Debian 13 (Trixie) arm64 + KDE Plasma 6

Everything that has to happen *inside* the guest to turn a stock Debian install into a
system that feels like the machine booted into it: the host filesystem share, Rosetta,
the clipboard agent, SSH, and clean shutdown.

The host side — building the app, attaching the installer ISO, suspend/resume — is in
the [README](../README.md).

## Before you start

You need a Debian 13 arm64 install that already boots from disk. If you are not there
yet, see the [quickstart](../README.md#quickstart). Two choices during the Debian
installer matter later:

- At **Software selection**, untick **GNOME** and tick **KDE Plasma**. GNOME's
  compositor is the single biggest source of lag in an arm64 VM. Keep **standard system
  utilities**.
- Give the guest user **the same name as your macOS user**. The app's *Copy SSH Command*
  and *Open SSH in Terminal* build `ssh -i ~/.ssh/linuxonmac <macOS user>@<guest IP>`,
  so a matching name means those work with no editing.

Everything else in the installer can stay at its default.

## How the setup scripts work

Guest configuration lives in `scripts/guest/` in this repository. The scripts are
**idempotent**: they check the state of the system before changing it, so running one
twice is a no-op rather than a duplicated `/etc/fstab` line or a second binfmt
registration. Re-run them after a guest upgrade, or when something looks wrong, rather
than reverse-engineering what changed.

They are not run from macOS. They run inside the guest, as your normal user, escalating
with `sudo` where they need to. Once the host share is mounted (below), the repository
is visible from the guest and the scripts can be run straight out of it — no copying, no
`scp`.

Run them in the order they are numbered. This document describes what each step does and
how to verify it, so you can also do any of it by hand.

## 1. Mount the host home directory

This one step is manual, because it is what makes the scripts reachable in the first
place. The app exposes your macOS home over virtiofs under the tag `home`.

```sh
sudo mkdir -p /mnt/mac
echo 'home /mnt/mac virtiofs defaults,nofail 0 0' | sudo tee -a /etc/fstab
sudo mount -a
ln -s /mnt/mac ~/mac
```

`/mnt/mac` is now your macOS home, read-write, no file copying. `nofail` matters: without
it, a share that is missing — because the app was launched with `--share` pointing
somewhere else, or with a different bundle — turns into a boot that stops at an emergency
shell.

The repository is now at `/mnt/mac/Documents/linuxonmac` (wherever it lives on the host),
so the rest of the setup runs from `/mnt/mac/.../scripts/guest/`.

## 2. Run the setup scripts

| Area | What it configures | Verify with |
|---|---|---|
| Display | Plasma scaling at 200% so the native-resolution panel is readable | Text is sharp, not interpolated |
| Desktop responsiveness | Animation speed instant, compositor backend and tearing prevention | `System Settings → Display & Monitor → Compositor` |
| Rosetta | `/mnt/rosetta` mount, `binfmt_misc` registration, `dpkg --add-architecture amd64` | `cat /proc/sys/fs/binfmt_misc/rosetta` |
| Clipboard | `wl-clipboard`, the vsock agent, and a user service that starts it with the session | `systemctl --user status` on the agent service |
| Shutdown | `acpid`, so the guest honours the host's shutdown request | `systemctl is-active acpid` |
| SSH | `openssh-server` and your host public key in `authorized_keys` | `ssh -i ~/.ssh/linuxonmac <user>@<guest IP>` from macOS |

The rest of this section is what those steps do, and why.

### Display scaling

The app hands the guest the panel's true pixel resolution — roughly 2940x1912 on a 13"
Air — because anything smaller is upscaled by the host and goes soft. At 100% that is
unreadably small, so the scaling happens in the guest, where it stays crisp:

**System Settings → Display & Monitor → Scale → 200%**, then log out and back in.

Do not compensate on the host side by giving the VM a smaller display. Guest-side
scaling renders at full resolution; host-side scaling interpolates.

### Desktop responsiveness

Plasma's defaults cost more in a VM than they do on metal:

- **System Settings → General Behavior → Animation speed → Instant**
- **System Settings → Display & Monitor → Compositor** — *Rendering backend* **OpenGL
  3.1**, *Tearing prevention* **Never**

Wider appearance and behaviour tuning is in [DESKTOP-THEME.md](DESKTOP-THEME.md).

### Rosetta — running x86_64 Linux binaries

The app attaches Rosetta as a virtiofs share tagged `rosetta` whenever Rosetta is
installed on the host. (If it is not: `softwareupdate --install-rosetta` on macOS. If you
only ever run arm64 software, launch with `--no-rosetta` and skip this entirely.)

```sh
sudo mkdir -p /mnt/rosetta
echo 'rosetta /mnt/rosetta virtiofs ro,nofail 0 0' | sudo tee -a /etc/fstab
sudo mount -a
```

Registration belongs in `/etc/binfmt.d/`, which `systemd-binfmt` reads at every boot — no
custom unit required:

```sh
sudo tee /etc/binfmt.d/rosetta.conf >/dev/null <<'CONF'
:rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/mnt/rosetta/rosetta:CF
CONF

sudo systemctl restart systemd-binfmt
cat /proc/sys/fs/binfmt_misc/rosetta   # "enabled"
```

**The magic and the mask must be exactly the same byte length — 20 bytes each.** One byte
too many in the mask and registration fails with nothing but `Invalid argument`, naming
neither the field nor the length. See the troubleshooting section below.

To install x86_64 packages afterwards:

```sh
sudo dpkg --add-architecture amd64
sudo apt update
```

### Clipboard agent

Virtualization.framework provides clipboard sharing for **macOS guests only**, so for a
Linux guest it has to be built. `guest/clipboard-agent.py` is the guest half; the host
half is `ClipboardBridge.swift`.

It speaks **vsock**, not TCP. vsock is a direct host-guest channel that never touches the
network stack, so the clipboard keeps working when the guest's networking does not —
which the VPN problem below has already caused once on this machine.

Requirements in the guest:

- `wl-clipboard` — the agent drives `wl-paste --watch` and `wl-copy`, so it needs a
  **Wayland** session. Plasma 6 defaults to Wayland; on an X11 session the agent will
  start and then do nothing.
- `python3` (Debian 13's system Python is enough; the agent has no third-party
  dependencies).
- A user service that starts the agent with the graphical session and restarts it if it
  dies. It has to be a *user* service, not a system one, because it needs the session's
  `WAYLAND_DISPLAY`.

The unit the script installs is equivalent to:

```ini
[Unit]
Description=linuxonmac clipboard agent
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart=/usr/local/bin/clipboard-agent.py
Restart=always
RestartSec=2

[Install]
WantedBy=graphical-session.target
```

The host connects to vsock port 7788 and retries every 3 seconds until the agent
answers, so ordering does not matter: start the guest first, start the agent later, and
the bridge comes up on its own. The status item and the Clipboard menu in the app show
`Connected over vsock` once it has.

Limits worth knowing: **text only**, UTF-8, capped at 4 MB per transfer. Images, rich
text and files are not carried in either direction, and there is no drag-and-drop —
`/mnt/mac` is the shared surface for anything that is not text.

### Clean shutdown

Quitting the app suspends the guest to disk. When suspend is unavailable, it falls back
to an ACPI shutdown request, which Debian only honours if `acpid` is installed:

```sh
sudo apt install -y acpid
sudo systemctl enable --now acpid
```

Without it, *Shut Down Guest* appears to do nothing.

### SSH from macOS

On the **host**, once:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/linuxonmac -C linuxonmac
```

In the **guest**:

```sh
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cat /mnt/mac/.ssh/linuxonmac.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Then, from macOS:

```sh
ssh -i ~/.ssh/linuxonmac jmkq@192.168.64.7
```

That address is stable **only because the MAC is pinned in the VM bundle**. The app
persists the MAC in `~/Library/Application Support/linuxonmac/Debian.vm/mac-address`, so
the guest keeps one DHCP lease instead of taking a new address on every launch — and the
app can resolve the current address by matching that MAC against `/var/db/dhcpd_leases`.
The status item shows it, and *Copy SSH Command* puts the whole line on the clipboard.

## Verifying the whole thing

```sh
mountpoint -q /mnt/mac && echo "host home mounted"
mountpoint -q /mnt/rosetta && echo "rosetta mounted"
cat /proc/sys/fs/binfmt_misc/rosetta | head -1        # enabled
systemctl is-active acpid ssh
python3 -c "import socket; socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM); print('vsock ok')"
echo hello | wl-copy && wl-paste                      # then check the macOS clipboard
```

## Troubleshooting

### A host VPN black-holes guest traffic

Symptom: apt, the Debian installer, or anything else that pulls over the network stalls
with **no error at all**. The installer reaches *Scanning the mirror…* and stops at a few
percent; `<Cancel>` looks frozen because the process is blocked in a socket read.

Cause: `VZNATNetworkDeviceAttachment` sends guest traffic out through the host's network
stack, so the guest inherits the host's default route and every problem attached to it.
A WireGuard tunnel — Surfshark, in the case that produced this note — typically runs at
**MTU 1380** while the guest NIC assumes 1500. Small packets get through, so DNS resolves
and the TCP handshake completes; the first full-size response packet is silently dropped.
Everything that reports a status reports success right up until nothing moves.

Confirm it from **macOS**:

```sh
netstat -rn | grep '^default'
scutil --nc list
ifconfig utun22          # whichever interface owns the default route
```

An `mtu` below 1500 on the interface owning the default route is the fingerprint.

Two fixes:

1. **Disconnect the VPN.** In the Debian installer, go back to the main menu and re-run
   *Configure the package manager*. Nothing already written to disk is lost.
2. **Keep the VPN and match the guest MTU to the tunnel's:**

   ```sh
   sudo ip link set dev enp0s1 mtu 1380
   ```

   Persist it in `/etc/systemd/network/` or through NetworkManager once the desktop is
   up. Split tunnelling that excludes the VM subnet works too, where the VPN client
   supports it.

The clipboard bridge is deliberately unaffected by all of this: vsock does not go through
the network stack, so copy and paste keep working while the guest's networking is dead.

### Rosetta registration fails with only "Invalid argument"

`systemd-binfmt` rejects a malformed registration without saying which field is wrong.
The cause is almost always length: **the mask must be exactly as many bytes as the magic
— 20 bytes each.** Count them:

```sh
python3 - <<'PY'
import re
line = open("/etc/binfmt.d/rosetta.conf").read().strip()
_, name, kind, offset, magic, mask, interpreter, flags = line.split(":")
size = lambda field: len(re.sub(r"\\x[0-9a-fA-F]{2}", ".", field))
print("magic", size(magic), "bytes;  mask", size(mask), "bytes")
PY
```

Both numbers must read 20. If they differ, fix the file and
`sudo systemctl restart systemd-binfmt`. `systemctl status systemd-binfmt` shows the
failing line but not the reason.

### The clipboard says "connecting…" forever

The host retries every 3 seconds and never gives up, so a permanent "connecting" means
the guest side is not listening.

```sh
systemctl --user list-units 'clip*'          # the unit the setup script installed
systemctl --user status clipboard-agent      # is it running?
journalctl --user -u clipboard-agent -n 50   # what did it say?
echo $WAYLAND_DISPLAY                        # empty means an X11 session
which wl-paste wl-copy
```

An X11 session is the most common cause: the agent depends on `wl-paste --watch`. Log out
and pick **Plasma (Wayland)** at the login screen.

### The guest boots to an emergency shell

A virtiofs mount in `/etc/fstab` without `nofail`, after the app was launched with a
different `--share` or with `--no-rosetta`. Both mount lines above carry `nofail` for
exactly this reason. Recover with `sudo mount -o remount,rw /`, fix `/etc/fstab`, reboot.

### A resume turned into a cold boot

That is a host-side problem, not a guest one: any change to the VM configuration
invalidates the saved state. See
[the README](../README.md#the-one-gotcha-the-configuration-must-not-change).

## Related documents

- [DESKTOP-THEME.md](DESKTOP-THEME.md) — Plasma appearance and desktop behaviour
- [INPUT.md](INPUT.md) — keyboard, trackpad and shortcut behaviour
- [TERMINAL.md](TERMINAL.md) — terminal setup
- [DEV-ENVIRONMENT.md](DEV-ENVIRONMENT.md) — development toolchain in the guest
