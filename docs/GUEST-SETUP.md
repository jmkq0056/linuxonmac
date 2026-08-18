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
installed on the host. Register it with the kernel so x86_64 ELF binaries just
execute:

```sh
sudo mkdir -p /mnt/rosetta
echo 'rosetta /mnt/rosetta virtiofs ro,nofail 0 0' | sudo tee -a /etc/fstab
sudo mount -a

sudo dpkg --add-architecture amd64
sudo apt update

sudo tee /etc/systemd/system/rosetta-binfmt.service >/dev/null <<'UNIT'
[Unit]
Description=Register Rosetta as the x86_64 ELF interpreter
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo ":rosetta:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x3e\\x00:\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff:/mnt/rosetta/rosetta:CF" > /proc/sys/fs/binfmt_misc/register'

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl enable --now rosetta-binfmt
```

If you only ever run arm64 software, launch with `--no-rosetta` and skip this.

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
