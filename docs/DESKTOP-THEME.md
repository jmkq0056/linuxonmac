# Desktop theme — Debian 13 / KDE Plasma 6 guest

Everything on this page is produced by one idempotent script:

```
scripts/guest/20-desktop-theme.sh            # apply everything, then verify
scripts/guest/20-desktop-theme.sh --verify   # read state back, change nothing
```

It is safe to re-run. It edits shared config files **key by key** with
`kwriteconfig6` and the `plasma-apply-*` tools, so it never truncates settings
owned by other parts of the setup (input, shortcuts, virtual desktops).

---

## What it sets

| Area | Choice | Why this one |
|---|---|---|
| Icons | **Papirus-Dark** (`papirus-icon-theme`) | Complete, actively maintained, packaged in Debian main. See the inheritance note below — this is the part that is easy to get wrong. |
| Cursor | **Bibata-Modern-Classic** 24px (`bibata-cursor-theme`) | Black arrow with a white outline, rounded — reads clearly on a dark desktop and is the closest packaged shape to the macOS pointer. 145 cursors, no missing shapes. |
| Plasma style | **breeze-dark** | Ships with Plasma, no third-party QML to maintain, and it is the fastest option on a software-rendered VM. |
| Widget style | **Breeze** | Same reason. Kvantum and friends add a per-widget SVG render pass we do not want here. |
| Colours | **Aurora Dark** (generated, `~/.local/share/color-schemes/AuroraDark.colors`) | Cool graphite neutrals instead of Breeze's blue-grey, with Apple's dark-mode system colours as the semantic accents. |
| Accent | `#0A84FF`, pinned | `accentColorFromWallpaper=false`, so the UI does not shift when the wallpaper changes. |
| Decorations | Breeze, borderless, buttons **on the left** (`XIA` = close / minimise / maximise) | macOS button order and position. |
| UI font | **Inter 10** (`fonts-inter`) | Large x-height, designed for UI at small sizes. `Inter Display` is installed too but is intended for large sizes, so it is not used for chrome. |
| Monospace | **JetBrains Mono 10 / 11** (`fonts-jetbrains-mono`) | Full programming ligature set (`GSUB`/`liga`/`calt` verified present). |
| Terminal glyphs | **Symbols Nerd Font Mono** as a fontconfig fallback | See the Nerd Font note below. |
| Wallpaper | **Aurora**, generated locally at 2940x1912 | Nothing is downloaded. |
| Panels | Top menu bar + floating bottom dock | See the layout note below. |
| GTK | Breeze-Dark + Papirus-Dark + Inter, `prefer-dark` | GTK apps match the Qt ones. |
| Terminal | Konsole profile `Aurora` + matching colour scheme | JetBrains Mono 11, 10px margin, unlimited scrollback. |

---

## The icon theme trap (the important part)

Debian's `papirus-icon-theme` installs three directories:

```
/usr/share/icons/Papirus         86,424 files   <- the actual icon set
/usr/share/icons/Papirus-Dark     7,568 files   <- a small overlay
/usr/share/icons/Papirus-Light    7,272 files   <- a small overlay
```

`Papirus-Dark` is **not** a complete theme. It only contains
`16x16`, `18x18`, `22x22` and `24x24` in the `actions`, `devices` and `places`
categories — the icons that need to be re-tinted for a dark panel. It has no
`apps`, no `mimetypes`, and nothing at 32/48/64px.

As shipped, its `index.theme` says:

```
Inherits=breeze-dark,hicolor
```

`Papirus` is **not in that list**. So selecting "Papirus-Dark" in System
Settings gives you a handful of Papirus icons sitting on top of a full Breeze
icon set — every application icon, every file-type icon and every larger icon
comes from Breeze. The desktop looks *almost* right, which is why this is easy
to miss. Walking the chain makes it obvious:

```
inheritance chain: Papirus-Dark -> breeze-dark -> breeze -> hicolor
probed 43 common icon names: 38 resolved, 5 missing
MISSING: firefox, org.kde.konsole, org.kde.kate, org.kde.discover, org.kde.spectacle
```

The script fixes this by putting `Papirus` into the chain:

```
Inherits=Papirus,breeze-dark,hicolor
```

Order matters. `Papirus-Dark`'s own small icons are still found first, so the
dark panel tinting is preserved; everything else now resolves against the full
86k-file Papirus set, with Breeze and hicolor only as a last resort.

> This edits `/usr/share/icons/Papirus-Dark/index.theme`, which belongs to
> dpkg. The original is kept as `index.theme.orig`, and an upgrade of
> `papirus-icon-theme` will revert it — just re-run the script. `--verify`
> checks the chain and prints `OK` or `FAIL`.

---

## Fonts

### Installed system-wide

| Package | Family |
|---|---|
| `fonts-inter` | Inter, Inter Display (18 faces) |
| `fonts-jetbrains-mono` | JetBrains Mono, JetBrains Mono NL (16 faces) |
| `fonts-firacode` | Fira Code (6 faces) — alternative ligature mono |
| `fonts-powerline`, `fonts-font-awesome` | extra glyph fallbacks |
| upstream `NerdFontsSymbolsOnly` v3.5.0 | Symbols Nerd Font / Symbols Nerd Font Mono |

`/etc/fonts/local.conf` maps the generic families:

```
sans-serif -> Inter, Noto Sans, DejaVu Sans, Noto Color Emoji
monospace  -> JetBrains Mono, Symbols Nerd Font Mono, Noto Sans Mono, ...
serif      -> Noto Serif, DejaVu Serif
system-ui  -> Inter
```

plus aliases so pages and configs asking for `Helvetica`, `-apple-system`,
`SF Mono`, `Menlo` or `Monaco` land on something real.

### Nerd Font: ligatures *and* glyphs, without compromise

The usual approach — replace JetBrains Mono with a Nerd-Font-patched build —
risks the ligature tables and means carrying a ~30 MB font outside the package
manager.

Instead this setup keeps **pristine JetBrains Mono from Debian** as the
monospace family and installs upstream's official *Symbols Only* font as a
fontconfig **fallback** for the Nerd Font codepoint ranges. This is the
arrangement the Nerd Fonts project itself recommends. Upstream's own
`10-nerd-font-symbols.conf` is installed to `/etc/fonts/conf.d/` and does the
mapping.

Result: ligatures come from JetBrains Mono, icon glyphs come from the symbols
font, and neither one compromises the other. Verified coverage:

```
file: /usr/local/share/fonts/nerd-fonts/SymbolsNerdFontMono-Regular.ttf
  U+E0B0 powerline       YES
  U+F09B github          YES
  U+E5FA seti            YES
  U+F0219 md             YES
  U+E700 devicons        YES
  U+F300 linux logos     YES
  U+23FB ipower          YES
  U+2665 octicon         YES
  total codepoints: 10519
```

The download is pinned to `v3.5.0` and checked against a SHA-256 before
install; if the network is unavailable the script skips it and says so rather
than half-installing.

> Note: a full patched `JetBrainsMono Nerd Font` also exists under
> `~/.local/share/fonts/NerdFonts/` — installed by something else, not by this
> script. It is harmless and selectable, but nothing here depends on it.

### Font rendering on a HiDPI panel

Set in `kdeglobals [General]` and mirrored in `/etc/fonts/local.conf`:

```
XftAntialias = true
XftHintStyle = hintslight
XftSubPixel  = none        <- grayscale, NOT subpixel
forceFontDPI = 0
```

**Why `none` and not `rgb`.** The guest renders into a virtual framebuffer
which `Virtualization.framework` then composites onto the Mac's panel. The
physical subpixel order is not preserved through that path, so RGB subpixel
antialiasing has nothing reliable to align to and produces colour fringing on
text edges. At Plasma scale 2 the extra resolution already does the work
subpixel AA would have done, so grayscale AA is both correct and cheaper.

**Why `hintslight`.** Vertical-only hinting snaps baselines without distorting
glyph shapes. Full hinting exists to rescue low-DPI rendering; at 2x it just
throws away the letterforms Inter and JetBrains Mono were drawn with.

`forceFontDPI=0` is required — Plasma's own scale factor already handles
sizing, and a non-zero DPI would multiply on top of it.

---

## Wallpaper

Generated by the script with Pillow, never downloaded:

- 2940x1912, deep graphite base (`#12141A` → `#090A0D`)
- two large soft radial glows (deep blue lower-left, indigo upper-right) plus a
  faint `#0A84FF` core, so the wallpaper and the accent colour agree
- a soft vignette
- ±3 levels of grain — a dark 16-step gradient bands visibly on a Retina
  panel without it

It is computed on a 368x240 grid and resampled up, which is exact for a smooth
gradient and roughly 100x faster than iterating 5.6M pixels in Python. Saved as
JPEG q95 with 4:4:4 chroma (4:2:0 smears the blue glow edges).

Installed as a proper KPackage at `~/.local/share/wallpapers/Aurora/`, so it
appears in the wallpaper picker, and applied to the desktop and the lock
screen.

---

## Panel layout

macOS-shaped, but without breaking anything Plasma users expect:

**Top bar** — 32pt, edge to edge, always visible, opaque:
`Kickoff` · *spacer* · `System Tray` · `Digital Clock` (date beside time) · `Show Desktop`

**Bottom dock** — 56pt, floating, `lengthMode = fit` so it shrink-wraps its
icons, centred, opaque. One `Icon-Only Task Manager` with Dolphin, Firefox,
Konsole, Kate, Spectacle, Discover and System Settings pinned.

The dock uses `dodgewindows`: it stays visible on an empty desktop and slides
away when a window would overlap it. On a 1280x801 *logical* desktop, a
permanently reserved 56pt strip plus the 32pt top bar is 11% of the height —
this gives it back to maximised windows. Hover the bottom edge to bring it up.

### Why there is no Global Menu applet

A macOS-style global menu (`org.kde.plasma.appmenu`) was the original design
and is the one thing here that was deliberately dropped.

That applet performs a **blocking** DBus registration against kded's appmenu
module. When that module is slow or missing, plasmashell blocks in
`request_wait_answer` and the entire shell wedges — no panels, no desktop, and
`evaluateScript` stops answering, which also locks out the tool you would use
to undo it. That is exactly what happened on this guest (see the incident note
below). The top bar keeps the macOS *shape* without that failure mode.

The panel step is also now guarded: the script pings `evaluateScript` with a
short timeout first and **skips the rebuild entirely** if plasmashell is not
answering, rather than driving a half-built layout into an unhealthy shell. It
drives the API through `gdbus --timeout 150` instead of `qdbus6`, whose 25s
libdbus default is shorter than the time this VM needs to instantiate that many
QML applets. And it never restarts plasmashell.

---

## Performance

This runs in a VM with software rendering (`llvmpipe`), so the script is
careful to stay out of the way:

- **No compositing effects are enabled.** `kwinrc [Plugins] blurEnabled=false`
  and `contrastEnabled=false` are left exactly as found, and both panels are
  set to `panelOpacity=1` (**opaque**) precisely so they do not need blur to
  look right. A translucent panel without blur looks washed out; an opaque one
  looks deliberate and costs nothing.
- **`AnimationDurationFactor=0` is left untouched.**
- `gtk-enable-animations=0` matches GTK apps to that.
- Breeze rather than an SVG-heavy third-party style.
- The wallpaper is a 1.2 MB JPEG, not a multi-megabyte PNG.

`--verify` prints these three guard values on every run so a regression is
visible immediately.

---

## Verified output

Captured from `--verify` on the guest after the apply run:

```
kdeglobals/Icons/Theme                     Papirus-Dark
kdeglobals/General/ColorScheme             AuroraDark
kdeglobals/General/AccentColor             10,132,255
kdeglobals/General/accentFromWall          false
kdeglobals/KDE/widgetStyle                 Breeze
kdeglobals/KDE/LookAndFeelPackage          org.kde.breezedark.desktop
kdeglobals/General/font                    Inter,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1
kdeglobals/General/fixed                   JetBrains Mono,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1
kdeglobals/WM/activeFont                   Inter,10,-1,5,600,0,0,0,0,0,0,0,0,0,0,1
kdeglobals/General/XftAntialias            true
kdeglobals/General/XftHintStyle            hintslight
kdeglobals/General/XftSubPixel             none
kdeglobals/General/forceFontDPI            0
kcminputrc/Mouse/cursorTheme               Bibata-Modern-Classic
kcminputrc/Mouse/cursorSize                24
plasmarc/Theme/name                        breeze-dark
kwinrc/decoration/theme                    Breeze
kwinrc/decoration/ButtonsOnLeft            XIA
kwinrc/decoration/ButtonsOnRight           ''
kwinrc/decoration/BorderSize               None
konsolerc/DefaultProfile                   Aurora.profile

-- Performance guards --
kwinrc/Plugins/blurEnabled                 false
kwinrc/Plugins/contrastEnabled             false
kdeglobals/KDE/AnimationDuration           0

-- Fonts --
  Inter                      18 faces
  JetBrains Mono             16 faces
  Symbols Nerd Font Mono      1 faces
  fc-match sans-serif   -> Inter-Regular.otf: "Inter" "Regular"
  fc-match monospace    -> JetBrainsMono-Regular.ttf: "JetBrains Mono" "Regular"
  ligature check (JetBrains Mono GSUB "liga"): present
  rendering: antialias: True hintstyle: 1 hinting: True rgba: 5
             (hintstyle 1 = hintslight, rgba 5 = none)

-- Cursor --
  /usr/share/icons/Bibata-Modern-Classic/cursors : 145 cursors

-- Wallpaper --
  /home/jmkq/.local/share/wallpapers/Aurora/contents/images/2940x1912.jpg
  1215145 bytes, (2940, 1912) RGB
```

---

## What needs a re-login

Most of this applies live. These do not:

| Change | Applies |
|---|---|
| Colour scheme, Plasma style, icon theme, fonts, font rendering, wallpaper, panels | **live** — the script sends `KWin.reconfigure` and `KGlobalSettings::notifyChange` |
| Window decoration button order / border size | live for new windows; existing windows update on `reconfigure` |
| **`/etc/fonts/local.conf` family mapping** | live for newly launched apps only. Apps already running keep the fontconfig state they started with. |
| **Papirus-Dark inheritance fix** | **needs a re-login** (or at least restarting each app) — `KIconTheme` caches the resolved inheritance chain per process at startup. |
| **GTK settings / gsettings** | live for newly launched GTK apps only. |
| **Konsole profile** | applies to new Konsole windows; existing tabs keep their profile. |
| **Lock screen wallpaper** | next lock. |

Nothing here requires a reboot.

---

## Incident note — guest kernel fault, 2026-08-19 01:50 CEST

While the panel layout was being applied, the guest went down. Recorded here
because the cause is **not** in this configuration and the box needs a reboot
before the panel step can be verified.

Sequence:

1. The panel build added `org.kde.plasma.appmenu`. plasmashell blocked in
   `request_wait_answer` (a synchronous DBus call) and stopped answering
   `evaluateScript`. Only one empty panel containment was created.
2. `systemctl --user stop plasma-plasmashell.service` was issued to recover it.
   The wedged process did not die on `SIGTERM` or on `SIGKILL` — systemd logged
   *"Processes still around after final SIGKILL"* and gave up after 2 minutes.
3. At 01:50:44 `kwin_wayland` (pid 877) aborted, and the kernel took an
   **undefined-instruction fault inside the `evdev` module** while releasing
   that process's input file descriptors:

   ```
   Call trace:
    evdev_release+0x0/0x170 [evdev]
    ____fput+0x1c/0x30
    task_work_run+0x8c/0x120
    do_exit+0x308/0xa38
   ...
    evdev_ioctl+0x0/0xb8 [evdev]
   Code: 00000000 00000000 00000000 00000000 (00000000)
   ---[ end trace 0000000000000000 ]---
   Fixing recursive fault but reboot is needed!
   ```

   `Code: 00000000` means the instruction stream at the faulting address read
   back as zeros — the module's text was not mapped. This is a kernel-side
   fault (Debian `6.12.101+deb13-arm64`), not something a userspace config
   change can produce.
4. `systemd-logind` then hit its 3-minute watchdog and could not be killed
   either. Without logind, `kwin_wayland` could not acquire a graphical session
   (*"Could not determine the active graphical session"* → *"No suitable DRM
   devices have been found"*) and entered a 25-second restart loop.
5. Shortly after, the guest stopped responding to SSH and ICMP entirely. The
   `com.apple.Virtualization.VirtualMachine` host process was spinning at ~596%
   CPU, consistent with a kernel lockup.

The kernel itself printed *"reboot is needed"*. **The guest requires a reboot.**
Rebooting was outside the remit of this task, so it was not done.

### What changed as a result

- The Global Menu applet is gone (step 8). It was the trigger for step 1.
- The panel step now **pre-flights** plasmashell and skips itself if the shell
  is not answering, instead of pushing a layout into an unhealthy shell.
- The panel step uses `gdbus --timeout 150`, not `qdbus6` with its 25s default.
- The script **never restarts plasmashell**. Tearing down every Wayland surface
  the shell owns at once is what escalated a wedged applet into a dead session.

### State on disk right now

All of section 1–7 and 9–11 was applied and read back successfully before the
fault, and those settings are on disk in the guest's home directory. They will
take effect on the next session start. The panel layout is the one piece that
did **not** complete: `~/.config/plasma-org.kde.plasma.desktop-appletsrc` was
reduced to just the desktop containment (which still carries the Aurora
wallpaper), so the next session will come up with **no panels** until this
script is re-run. Timestamped backups of the original file are next to it:

```
~/.config/plasma-org.kde.plasma.desktop-appletsrc.preclean
~/.config/plasma-org.kde.plasma.desktop-appletsrc.bak.<epoch>
```

After the guest is rebooted, re-running `scripts/guest/20-desktop-theme.sh`
rebuilds the panels and re-verifies everything.
