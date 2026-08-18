# Guest setup — Debian 13 (Trixie) arm64 + KDE Plasma

Run these inside the guest after the install finishes. They turn a stock
Debian install into something that feels like the machine booted into it.

## 1. During the Debian installer

Only one screen matters. At **Software selection**:

- untick **GNOME** — its compositor is the single biggest source of lag in an
  arm64 VM
- tick **KDE Plasma**
- keep **standard system utilities**

Everything else can stay at its default.

## 2. Mount the host home directory

The runner exposes your macOS home over virtiofs under the tag `home`.

```sh
sudo mkdir -p /mnt/mac
echo 'home /mnt/mac virtiofs defaults,nofail 0 0' | sudo tee -a /etc/fstab
sudo mount -a
```

`/mnt/mac` is now your macOS home, read-write, no file copying. A symlink keeps
it close to hand:

```sh
ln -s /mnt/mac ~/mac
```

## 3. Display scaling

The runner hands the guest the panel's true pixel resolution — roughly
2940x1912 on a 13" Air — because anything smaller gets upscaled and goes soft.
At 100% that is unreadably small, so scale in the guest, where it stays crisp:

**System Settings → Display & Monitor → Scale → 200%**

Log out and back in. Text is now retina-sharp instead of interpolated.

## 4. Kill the animations

Plasma's default animations cost more in a VM than they do on metal.

**System Settings → General Behavior → Animation speed → Instant**

Then turn the compositor down a notch:

**System Settings → Display & Monitor → Compositor** — set *Rendering backend*
to **OpenGL 3.1**, *Tearing prevention* to **Never**.

## 5. Rosetta — running x86_64 Linux binaries

The runner attaches Rosetta as a virtiofs share tagged `rosetta` whenever it is
installed on the host. Mount it and register it as the interpreter for x86_64
ELF binaries:

```sh
sudo mkdir -p /mnt/rosetta
echo 'rosetta /mnt/rosetta virtiofs ro,nofail 0 0' | sudo tee -a /etc/fstab
sudo mount -a
```

Registration belongs in `/etc/binfmt.d/`, which `systemd-binfmt` reads at every
boot — no custom unit required:

```sh
sudo tee /etc/binfmt.d/rosetta.conf >/dev/null <<'CONF'
:rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/mnt/rosetta/rosetta:CF
CONF

sudo systemctl restart systemd-binfmt
cat /proc/sys/fs/binfmt_misc/rosetta   # should print "enabled"
```

**The magic and the mask must be the same length — 20 bytes each.** A mask with
one byte too many fails with nothing but `Invalid argument`, which names neither
the field nor the length.

To actually install x86_64 packages afterwards:

```sh
sudo dpkg --add-architecture amd64
sudo apt update
```

If you only ever run arm64 software, launch with `--no-rosetta` and skip all of
this.

## 6. Guest agent for a clean shutdown

Closing the runner window suspends the guest to disk. When suspend is not
available it falls back to an ACPI shutdown request, which Debian only honours
if `acpid` is present:

```sh
sudo apt install -y acpid
sudo systemctl enable --now acpid
```

## What is not available

**Clipboard sharing.** Virtualization.framework provides it for macOS guests
only — there is no clipboard channel for Linux guests, in this runner or any
other one built on the framework. The `VZVirtioSocketDevice` is already in the
configuration for exactly this reason; a vsock clipboard agent is the planned
route. Until then, `/mnt/mac` is the shared surface.

## Troubleshooting

### The installer hangs at "Scanning the mirror..."

A host VPN is the usual cause. `VZNATNetworkDeviceAttachment` sends guest
traffic out through the host's network stack, so whatever the host's default
route is, the guest inherits its problems.

Check for a tunnel that owns the default route:

```sh
netstat -rn | grep '^default'
scutil --nc list
ifconfig utun22   # whichever interface the default route names
```

A WireGuard tunnel typically runs at **MTU 1380** while the guest NIC assumes
1500. Small packets get through, so DNS resolves and the TCP handshake
completes — the installer reaches "Scanning the mirror" and then stalls at a
few percent when the first full-size response packet is silently dropped.
`<Cancel>` appears frozen because the process is blocked in a socket read.

**Disconnect the VPN**, then in the installer go back to the main menu and re-run
*Configure the package manager*. Nothing already written to disk is lost.

To keep a VPN running alongside the guest, either exclude the VM subnet from the
tunnel (split tunnelling) or match the guest MTU to the tunnel's:

```sh
sudo ip link set dev enp0s1 mtu 1380
```

Persist it in `/etc/systemd/network/` or via NetworkManager once the desktop is
up. `nofail` is already set on the virtiofs mounts above so a networking problem
never blocks boot.
