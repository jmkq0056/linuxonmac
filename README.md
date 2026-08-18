# linuxonmac

A [Virtualization.framework](https://developer.apple.com/documentation/virtualization)
app that runs Debian 13 arm64 with KDE Plasma 6 on an Apple Silicon Mac and makes it
feel like a second booted OS rather than a VM in a window: fullscreen on its own
macOS Space, native panel resolution, shared home directory, shared clipboard, and a
~2 second resume instead of a boot sequence.

## Why this exists

Bare-metal Linux on an M4/M5 Mac is not available, and not "not yet, next month":

- **Boot Camp** — Intel only. Gone with Apple Silicon.
- **Asahi Linux** — M1/M2 supported, M3 partial. M4/M5: no installer, no GPU driver,
  no ETA.
- **The blocker.** Apple's SPTM (Secure Page Table Monitor) runs at higher privilege
  than the OS kernel. Asahi's reverse-engineering harness on M1/M2 worked by running
  macOS/XNU as a guest under their own hypervisor and watching its hardware access.
  On M4/M5, `m1n1` loads into a world at GL2 with memory management already enabled,
  so XNU cannot be run as a guest. What is left — cold kernel auditing, hooking XNU
  exception handlers — is orders of magnitude slower. Upstream gives no timetable.
- Even if boot were solved there is no GPU driver: M3+ changed the GPU architecture
  substantially (hardware ray tracing, mesh shaders, dynamic caching).

So the remaining question is not "how do I boot Linux" but "how close to booted can a
VM feel". That is an app and UX problem, and Apple ships a *public* framework for it —
UTM's Apple backend, OrbStack, Lima and Tart are all clients of the same API, with no
privileged access involved.

Explicitly out of scope: SSD partitioning, waiting for Asahi, containers, x86 ISOs
under emulation, wrapping UTM.

**What "feels booted" means here**

1. Near-native CPU speed — virtualization, never emulation.
2. One gesture to switch in. No window-on-a-desktop feeling.
3. Instant resume — suspend/restore, not cold boot.
4. 1:1 correct display on the built-in retina panel. No scaling blur.
5. Filesystem and clipboard shared with the host without ceremony.

## Quickstart

Requirements: Apple Silicon Mac, macOS 14 or later, Swift toolchain (Xcode or the
Command Line Tools).

```sh
# 1. Get a Debian arm64 netinst image
#    https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/
#    Leave it in ~/Downloads and it will be picked up automatically.

# 2. Build and install to /Applications
./scripts/build.sh && ./scripts/install.sh

# 3. First run — windowed, because the Debian installer at native retina
#    resolution is microscopic
./scripts/run.sh --windowed --iso ~/Downloads/debian-13.6.0-arm64-netinst.iso

# 4. Everyday use — Spotlight, /Applications, or:
./scripts/launch.sh
```

At the installer's **Software selection** screen, untick GNOME and tick **KDE Plasma**.
Then follow [docs/GUEST-SETUP.md](docs/GUEST-SETUP.md), which configures the guest side
with idempotent scripts.

`scripts/run.sh` runs in the foreground with logs in the terminal.
`scripts/launch.sh` hands the app to LaunchServices so it outlives the shell; logs then
go to `~/Library/Application Support/linuxonmac/linuxonmac.log`.

### Command line options

| Flag | Effect |
|---|---|
| `--iso <path>` | Installer to attach. Defaults to the newest `*arm64*.iso` in `~/Downloads`, and only until the guest looks installed |
| `--no-iso` | Boot from disk only |
| `--share <path>` | Host directory exposed over virtiofs, tag `home`. Defaults to `$HOME` |
| `--no-rosetta` | Skip the Rosetta share |
| `--windowed` | Window instead of fullscreen on its own Space |
| `--reset` | Delete the VM bundle and start over. Destroys the guest |

"Looks installed" means either the `installed` marker written after the first clean
guest power-off, or a disk image with more than 2 GB of blocks actually allocated —
the marker alone is unreliable because suspending on quit means the guest usually
never powers off at all.

## What it does today

Everything in this list is implemented in `Sources/linuxonmac/`.

- **EFI boot** with persistent NVRAM (`VZEFIBootLoader` + `VZEFIVariableStore`) and a
  persistent machine identifier.
- **Suspend to disk on quit, resume on next launch.** Measured at about 2 seconds to a
  live Plasma session. Save/restore support is checked with
  `validateSaveRestoreSupport()` at startup, so closing the window never blocks on a
  save that was always going to fail, and a 30 second watchdog guarantees the app
  cannot hang waiting on one. The state file is deleted as part of restoring, so a
  failed restore can never be replayed into a corrupt guest.
- **Fullscreen on a dedicated macOS Space** (`.fullScreenPrimary`), so switching in and
  out is a three-finger swipe. This is most of the "feels like dual boot" effect.
- **Native-resolution display.** One `VZVirtioGraphicsDevice` scanout at the panel's
  true pixel size, with `automaticallyReconfiguresDisplay` so the guest follows window
  resizes. Nothing is upscaled; readability is handled by scaling inside the guest.
- **`capturesSystemKeys`**, so system-level combinations reach the guest. Toggleable
  from the View menu.
- **virtiofs share of `$HOME`** (tag `home`), plus the **Rosetta** share (tag `rosetta`)
  when Rosetta is installed on the host, for running x86_64 Linux binaries.
- **Clipboard sync over vsock**, both directions, text. See below.
- **Menu bar and status item** — pause, restart, shut down, force stop, full screen,
  clipboard controls, shared folder, guest IP, and an SSH session in Terminal.
- **Guest IP resolution** by matching the pinned MAC against the host's vmnet DHCP
  lease table (`/var/db/dhcpd_leases`).
- NAT networking, virtio sound in and out, entropy, memory balloon, vsock. The pointing
  device is `VZUSBScreenCoordinatePointingDevice`, so the pointer is absolute — no
  capture, no release hotkey.

### App shortcuts

Guest-side key handling and shortcut mapping are covered in [docs/INPUT.md](docs/INPUT.md);
these are the host app's own bindings, from `AppMenu.swift`.

| Shortcut | Action |
|---|---|
| `Cmd-Q` | Suspend and quit |
| `Cmd-Ctrl-P` | Pause / resume |
| `Cmd-Ctrl-R` | Restart guest |
| `Cmd-Ctrl-Q` | Shut down guest (ACPI request) |
| `Cmd-Ctrl-F` | Toggle full screen |
| `Cmd-Ctrl-K` | Toggle clipboard sync |
| `Cmd-Ctrl-C` | Send the macOS clipboard to the guest now |
| `Cmd-Ctrl-S` | Copy the SSH command |
| `Cmd-Ctrl-T` | Open an SSH session in Terminal |
| `Cmd-Shift-O` | Open the shared folder in Finder |

## Architecture

```
macOS host                                   Debian guest
──────────────────────────────────────       ────────────────────────────────
linuxonmac.app (Swift, AppKit)
  VMBuilder     builds the config
  VMSession     lifecycle + window ─────────▶ VZVirtioGraphicsDevice → Plasma
  ClipboardBridge ──── vsock 7788 ─────────▶ guest/clipboard-agent.py
  GuestNetwork  reads dhcpd_leases           enp0s1, NAT, DHCP lease
  AppMenu       menu bar + status item
       │
       └── virtiofs "home"  ────────────────▶ /mnt/mac
           virtiofs "rosetta" ──────────────▶ /mnt/rosetta + binfmt_misc
```

### Host

| File | Responsibility |
|---|---|
| `main.swift` | Option parsing, ISO discovery, `NSApplication` setup, suspend-on-terminate |
| `VMBuilder.swift` | Assembles `VZVirtualMachineConfiguration`; creates and persists disk, NVRAM, machine ID, MAC, scanout |
| `VMSession.swift` | Owns the VM and its window; start, restore, suspend, restart, shutdown |
| `ClipboardBridge.swift` | vsock clipboard, host half |
| `GuestNetwork.swift` | Guest IP from the vmnet lease table, matched on the pinned MAC |
| `AppMenu.swift` | Menu bar and `NSStatusItem`, both needed because the window lives fullscreen on another Space and captures system keys |
| `Paths.swift` | VM bundle layout, plus the `Tunables` sizing constants |
| `Log.swift` | stdout for foreground runs, log file for detached ones |

Sizing currently lives in `Tunables` (`Paths.swift`): 6 vCPUs, 10 GB RAM, and a 96 GB
sparse disk that only consumes what the guest writes. CPU count and memory are clamped
to the range the framework allows on this machine when the configuration is built.

### The VM bundle

Everything the VM owns is in `~/Library/Application Support/linuxonmac/Debian.vm/`.
Move it, back it up, or delete it as a unit.

| File | Purpose |
|---|---|
| `disk.img` | Sparse root disk |
| `nvram` | EFI variable store |
| `machine-identifier` | `VZGenericMachineIdentifier`, stable across launches |
| `mac-address` | Pinned MAC — stable IP, and required for resume |
| `scanout` | Pinned display size — required for resume |
| `state.vzvmsave` | Saved machine state, present only while suspended |
| `installed` | Marker written on the first clean guest power-off |

### Clipboard bridge

Virtualization.framework provides clipboard sharing for macOS guests only, so for a
Linux guest it has to be built. It runs over **vsock**, not TCP: vsock is a direct
host-guest channel that never touches the network stack, so the clipboard keeps working
when guest networking does not — which a host VPN with a small MTU has already caused
once on this machine.

The guest agent (`guest/clipboard-agent.py`) listens on vsock port 7788; the host
connects, retrying every 3 seconds until the agent is up, and reconnects if the link
drops. The wire format is a 4-byte big-endian length followed by a JSON object,
`{"t":"clip","fmt":"text","data":...}`, capped at 4 MB. The host observes the pasteboard
by polling `changeCount` — there is no change notification for `NSPasteboard`. The guest
side is event-driven, waiting on a single long-lived `wl-paste --watch`. Both sides
suppress the value they just wrote locally, otherwise every update ping-pongs forever.

### Reaching the guest over SSH

```sh
ssh -i ~/.ssh/linuxonmac jmkq@192.168.64.7
```

The address is stable **only because the MAC is pinned in the VM bundle** — the guest
keeps one DHCP lease instead of taking a new one on each launch. The menu's *Copy SSH
Command* and *Open SSH in Terminal* build this line from your macOS user name and the
IP resolved from the lease table, falling back to `192.168.64.7` when no lease is
found yet. Guest-side sshd and key setup is in
[docs/GUEST-SETUP.md](docs/GUEST-SETUP.md).

## The one gotcha: the configuration must not change

`restoreMachineStateFrom(url:)` compares the *whole* virtual machine configuration
against the one that was saved, and rejects any mismatch with a bare **`invalid
argument`** that names neither the field nor the reason. This has already cost real
debugging time twice: a randomly generated MAC and a scanout derived from whichever
display happened to be attached both meant the configuration was never twice the same,
so every resume silently degraded into a cold boot. Both are now persisted in the VM
bundle.

The rule generalises. **Anything that changes the configuration invalidates a saved
state** — CPU count, memory size, adding or removing a device, attaching an ISO,
changing the shared folder, toggling Rosetta. The failure is not destructive: the app
logs `Saved state could not be restored`, deletes the state file, and cold boots. But
the running desktop is gone. Change VM settings from a clean shutdown, not from a
suspended session.

## Known limitations

- **No GPU acceleration beyond virtio-gpu.** There is no Metal or Vulkan passthrough
  and no hardware video decode in the guest. 3D applications, games, and GPU compute
  are out. This is a ceiling of the framework, not of the app, and Parallels stays
  ahead here. The win of a custom app is integration, not rendering.
- **Clipboard is text only.** Images, rich text, and files are not carried; the payload
  is a UTF-8 string capped at 4 MB. The agent also depends on a Wayland session with
  `wl-clipboard` installed.
- **No file drag-and-drop** in either direction. `/mnt/mac` is the shared surface.
- **Browsers and GTK applications may not honour KDE keyboard shortcuts.** Chromium,
  Firefox and GTK apps do their own key handling, so shortcuts remapped at the Plasma
  level can be ignored inside them.
- **One display.** A single scanout, deliberately pinned; attaching an external monitor
  does not add a guest display, and the pinned size is what protects resume.
- **VM sizing is compile-time.** CPU count, memory and disk size are constants in
  `Tunables`; changing them requires a rebuild — and invalidates any saved state.
- **No snapshots.** There is exactly one saved state, written on quit and consumed on
  resume.
- **Ad-hoc signed.** `scripts/build.sh` signs with `-` and the virtualization
  entitlement. The binary must be signed for the framework to run at all, so running
  `.build/.../linuxonmac` directly will not work; go through the scripts.

## Troubleshooting

**It cold boots instead of resuming.** The configuration changed since the state was
saved. Check the log for `Saved state could not be restored` — see the section above.
`~/Library/Application Support/linuxonmac/linuxonmac.log` has the reason.

**`!! virtualization entitlement missing` at build time.** Signing must be the last
step; adding anything to the bundle after `codesign` invalidates the signature, and an
invalid signature means the entitlement is ignored and the VM refuses to start. Rerun
`./scripts/build.sh` from a clean `build/`.

**Clipboard menu says "connecting…" forever.** The guest agent is not listening.
Confirm the guest is in a graphical session and the agent service is running; the host
retries every 3 seconds and needs no restart once it comes up.

**Guest IP shows as unknown.** The lease table is only populated after the guest has
DHCPed. If it stays unknown after the desktop is up, the guest's network is down —
check for a host VPN, below.

**Networking works on the host but the guest stalls with no error.** A host VPN.
`VZNATNetworkDeviceAttachment` sends guest traffic through the host's network stack, so
the guest inherits whatever the host's default route does. A WireGuard tunnel at MTU
1380 lets small packets through — DNS resolves, handshakes complete — and silently drops
the first full-size response, which looks like a hang rather than a failure. Full
diagnosis and both fixes are in
[docs/GUEST-SETUP.md](docs/GUEST-SETUP.md#a-host-vpn-black-holes-guest-traffic).

**`Rosetta is not installed`.** `softwareupdate --install-rosetta`, or launch with
`--no-rosetta` if the guest is arm64-only.

**The app shows a generic icon in the Dock.** LaunchServices icon caching, not the
bundle. `./scripts/install.sh` re-registers the bundle and restarts the Dock.

**Starting over.** `./scripts/run.sh --reset` deletes the VM bundle, guest and all.

## Documentation

| Document | Covers |
|---|---|
| [docs/GUEST-SETUP.md](docs/GUEST-SETUP.md) | Installing and configuring the Debian guest: shares, Rosetta, clipboard agent, SSH, VPN and binfmt troubleshooting |
| [docs/DESKTOP-THEME.md](docs/DESKTOP-THEME.md) | Plasma appearance and desktop behaviour |
| [docs/INPUT.md](docs/INPUT.md) | Keyboard, trackpad and shortcut behaviour between host and guest |
| [docs/TERMINAL.md](docs/TERMINAL.md) | Terminal setup inside the guest |
| [docs/DEV-ENVIRONMENT.md](docs/DEV-ENVIRONMENT.md) | Development toolchain inside the guest |

## Roadmap

- [x] Swift package and ad-hoc signed `.app`
- [x] EFI boot from an arm64 ISO, persistent NVRAM
- [x] Accelerated display at native resolution
- [x] virtiofs share of `$HOME`, plus Rosetta
- [x] Fullscreen on a dedicated Space
- [x] Suspend / resume
- [x] Persistent guest identity — machine ID, MAC, scanout
- [x] Menu bar and status item
- [x] Clipboard sync over vsock
- [ ] Settings window, with CPU and memory editable without a rebuild — in progress.
      Note that changing either invalidates a saved state
- [ ] Splash screen while the guest starts or resumes — in progress
- [ ] Global hotkey to jump straight into the session
- [ ] `VZLinuxBootLoader` mode — boot a raw kernel and initrd from a host folder, for
      building your own kernel or distro

## Hardware and references

Developed against a MacBook Air M5, 24 GB RAM, 1 TB SSD, macOS host, guest Debian 13
"Trixie" arm64 with KDE Plasma 6. Nothing is specific to that machine beyond the
`Tunables` sizing.

- [Tart](https://github.com/cirruslabs/tart) — open source, Swift, same framework, small
  enough to read in an afternoon.
- Apple sample: *Running GUI Linux in a virtual machine on a Mac*.

## License

MIT
