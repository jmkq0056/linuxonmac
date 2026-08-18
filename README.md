# linuxonmac

Near-native Linux on Apple Silicon (M5) — a custom
[Virtualization.framework](https://developer.apple.com/documentation/virtualization)
app that makes a Linux VM *feel* like a booted OS instead of a window on a desktop.

## Why not just dual boot?

Bare-metal Linux on an M5 MacBook Air is not possible today. This is settled:

- **Boot Camp** — Intel only, gone with Apple Silicon.
- **Asahi Linux** — M1/M2 supported, M3 partial. **M4 and M5: no installer, no GPU driver, no ETA.**
- **The blocker (as of Aug 2026):** Apple's SPTM (Secure Page Table Monitor) runs at higher
  privilege than the OS kernel. The Asahi reverse-engineering harness on M1/M2 was running
  macOS/XNU as a guest under their own hypervisor and watching its hardware access. On M4/M5,
  `m1n1` loads into a world at GL2 with memory management already enabled, so XNU can't be run
  as a guest. What's left is cold kernel auditing or hooking XNU exception handlers — orders of
  magnitude slower. Upstream gives no timetable.
- Even if boot were solved, there's no GPU driver: M3+ changed the GPU architecture substantially
  (hardware ray tracing, mesh shaders, dynamic caching).

Explicitly out of scope: SSD partitioning, waiting for Asahi, Docker/containers,
x86 ISOs under emulation, UTM.

## The actual goal

> A Linux environment on Apple Silicon that feels indistinguishable from having booted into it.

That's an app-level and UX problem, not a kernel problem.

**Success criteria**

1. Near-native CPU speed — virtualization, never emulation.
2. One gesture or one hotkey to switch in. No reboot, no window-on-a-desktop feeling.
3. Instant resume — suspend/restore, not cold boot.
4. 1:1 correct display on the built-in retina panel. No scaling blur, no pushing 4x pixels.
5. Filesystem and clipboard shared with the host without ceremony.

## Approach

Apple ships a **public** framework for this. UTM's Apple backend, OrbStack, Lima and Tart are all
just clients of it — no privileged access involved. Anything they do is reachable from a custom
Swift app.

| API | Purpose |
|---|---|
| `VZEFIBootLoader` | Boots stock arm64 distro ISOs |
| `VZEFIVariableStore` | Persistent NVRAM |
| `VZVirtioGraphicsDeviceConfiguration` | Metal-backed accelerated display |
| `VZVirtioFileSystemDeviceConfiguration` | virtiofs host folder mount |
| `VZVirtioSocketDevice` | host ↔ guest communication |
| `VZVirtioBlockDeviceConfiguration` | Disk attachment |
| `VZLinuxRosettaDirectoryShare` | Run x86 Linux binaries near-native via Rosetta |

### Minimal skeleton

```swift
let config = VZVirtualMachineConfiguration()
config.cpuCount = 6
config.memorySize = 10 * 1024 * 1024 * 1024

let bootloader = VZEFIBootLoader()
bootloader.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: nvramURL)
config.bootLoader = bootloader

let disk = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

try config.validate()
let vm = VZVirtualMachine(configuration: config)
try await vm.start()
```

### Where a custom app beats existing tools

Not raw rendering — the graphics ceiling is whatever Virtualization.framework exposes, so
Parallels stays ahead there. The win is **integration**, which every existing tool handles poorly:

- Auto-launch fullscreen onto a dedicated macOS Space.
- Automatic 1:1 resolution matching to the active display.
- Suspend/resume, so entry is instant instead of a boot sequence.
- A global hotkey that jumps straight into the Linux session.
- Sensible virtiofs mounts configured on first run, not buried in settings.

Swift + AppKit. No kernel hacking, no reverse engineering.

## Running it

Guest: **Debian 13 "Trixie" arm64 + KDE Plasma 6**. Official arm64 media, apt,
and the desktop that stays fast under virtio-gpu.

```sh
# 1. Grab the installer (701 MB)
#    https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/

# 2. Build the runner — ad-hoc signed with com.apple.security.virtualization
./scripts/build.sh

# 3. Install. Windowed, because the installer at native retina is microscopic.
./scripts/run.sh --windowed --iso ~/Downloads/debian-13.6.0-arm64-netinst.iso

# 4. Everyday use — fullscreen on its own Space, boots from disk
./scripts/launch.sh
```

At the installer's **Software selection** screen, untick GNOME and tick **KDE
Plasma**. Then work through [docs/GUEST-SETUP.md](docs/GUEST-SETUP.md).

### Options

| Flag | Effect |
|---|---|
| `--iso <path>` | Installer to attach. Defaults to the newest `*arm64*.iso` in `~/Downloads` until the guest has powered off cleanly once |
| `--no-iso` | Boot from disk only |
| `--share <path>` | Host directory exposed over virtiofs (tag `home`). Defaults to `$HOME` |
| `--no-rosetta` | Skip the Rosetta share |
| `--windowed` | Window instead of fullscreen on its own Space |
| `--reset` | Delete the VM bundle and start over. Destroys the guest |

`scripts/run.sh` runs in the foreground with logs in the terminal.
`scripts/launch.sh` hands it to LaunchServices so it outlives the shell; logs
go to `~/Library/Application Support/linuxonmac/linuxonmac.log`.

### What it does today

- EFI boot with persistent NVRAM and a stable machine identity
- Metal-backed `VZVirtioGraphicsDevice` at the panel's true pixel resolution,
  reconfiguring live as the window resizes — no upscaling, no blur
- Fullscreen onto a **dedicated macOS Space** — three-finger swipe to switch,
  which is the bulk of the "feels like dual boot" effect
- `capturesSystemKeys` so Cmd-Tab and friends reach the guest
- virtiofs share of `$HOME`, plus Rosetta when it is installed
- NAT networking, virtio sound in/out, entropy, balloon, vsock
- **Suspend to disk on window close, resume on next launch** — the state file is
  consumed on restore so a failed resume can never be replayed, and the
  configuration is checked with `validateSaveRestoreSupport()` up front so
  closing never blocks on a save that was always going to fail

Everything lives in one bundle at
`~/Library/Application Support/linuxonmac/Debian.vm/` — move it, back it up, or
delete it as a unit.

## Baseline tuning (any hypervisor, do this first)

- Hypervisor backed by Apple Virtualization.framework, never QEMU emulation.
- arm64 guest ISOs only.
- Run the VM fullscreen on its own macOS Space — three-finger swipe to switch. This single change
  is most of the "feels like dual boot" effect.
- KDE Plasma or XFCE, not GNOME. GNOME's compositor is the dominant source of VM lag on arm64.
- ~8–12 GB RAM, ~6 cores. Don't oversubscribe cores.
- Disable guest desktop animations; install guest tools for clipboard and shared folders.
- Set a real 1:1 guest resolution, not a scaled retina one.

## Roadmap

- [x] Swift package + signed `.app` scaffold
- [x] EFI boot from an arm64 ISO
- [x] Accelerated `VZVirtioGraphicsDevice` display at native resolution
- [x] virtiofs share of `$HOME`, plus Rosetta
- [x] Window launching fullscreen on its own Space
- [x] Suspend / resume
- [ ] Global hotkey to jump straight into the session
- [ ] vsock clipboard agent (the framework has no clipboard channel for Linux guests)
- [ ] `VZLinuxBootLoader` mode — boot a raw kernel + initrd straight from a host
      folder, for anyone wanting to build their own kernel or distro

## Target hardware

MacBook Air M5, 24 GB RAM, 1 TB SSD, arm64, macOS host.

## References

- [Tart](https://github.com/cirruslabs/tart) — open source, Swift, small codebase, same framework.
- Apple sample: *Running GUI Linux in a virtual machine on a Mac*.

## License

MIT
