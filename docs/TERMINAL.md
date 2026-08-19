# Terminal and shell

The guest is where the real work happens — editing, building, running Claude Code — so
the terminal is the one piece of the desktop that has to be genuinely good rather than
merely present. This is what `scripts/guest/40-terminal.sh` sets up and why.

Run it once, as the desktop user, inside the guest:

```sh
./scripts/guest/40-terminal.sh
```

It is idempotent — re-running it is how you pick up changes, and it will not duplicate
anything it has already written.

## Choices

### Terminal: Konsole (kept)

Konsole was already installed as part of the KDE Plasma task (`4:25.04.2-1`). An earlier
check made it look missing because `konsole --version` printed nothing over SSH — that
was Qt failing to find a display and falling back to the `xcb` platform plugin, not a
missing binary:

```
qt.qpa.xcb: could not connect to display
qt.qpa.plugin: Could not load the Qt platform plugin "xcb" in ""
```

`dpkg -l konsole` confirms it is installed and `/usr/bin/konsole` exists. No replacement
was needed, and Konsole is the right fit anyway:

- It is the native Plasma terminal, so it inherits the session's Wayland scaling, the
  Plasma colour scheme integration, and KDE's global shortcuts without extra work. On a
  HiDPI panel at scale 2 that matters — third-party terminals are exactly where
  fractional/integer scaling bugs show up.
- Split views, tabs, profiles, and a searchable scrollback are built in.
- It is already in the apt dependency graph, so it stays patched with the rest of the
  desktop.

Alacritty and WezTerm were the alternatives considered. Both are good, but on Wayland
under Plasma neither buys anything Konsole lacks here, and both add a separate config
language and update path for no gain. Ghostty is not packaged for Debian arm64.

### Font: JetBrainsMono Nerd Font Mono, 12pt

Debian has no Nerd Fonts package, so the script fetches the upstream release and installs
the Regular/Bold/Italic/BoldItalic cuts into `~/.local/share/fonts/NerdFonts` (user-scoped,
so it never collides with another installer's apt packages). The no-ligature "NL" cuts are
skipped to keep the font picker readable.

The **Mono** variant is deliberate. Nerd Fonts ship a proportional cut whose icons are
wider than one cell; the Mono cut keeps every glyph to a single cell, which is what a
terminal grid needs. Both report `spacing=100` to fontconfig, so both appear in Konsole's
font list — picking the wrong one is an easy mistake that shows up as drifting columns.

12pt is chosen for the 2940x1912 panel at Plasma scale 2: that is a 1470x956 logical
viewport, so 12pt gives roughly 50 rows full-screen — comfortable without wasting lines.

### Colour scheme: Catppuccin Mocha

Shipped as a real Konsole `.colorscheme` with all 16 ANSI colours plus intense/faint
variants, rather than leaning on a Plasma theme. The same palette is reused for
`LS_COLORS` (via `vivid`'s `catppuccin-mocha` theme) and for the starship prompt colours,
so directory listings, the prompt, and TUI output all agree.

`bat` has no Catppuccin theme built in and **errors out on an unknown theme name**, so
the script probes `bat --list-themes` and picks the best available — it resolved to
`Coldark-Dark`. That probe is why `BAT_THEME` is written into a generated file at install
time instead of being hardcoded.

### Shell: zsh (login), bash kept working

zsh is the login shell. The reasoning:

- **Completion.** zsh's completion system is the single biggest day-to-day difference:
  menu selection, descriptions, case-insensitive and partial-word matching, and
  colourised candidates. bash's readline completion is not close.
- **Real history sharing.** `SHARE_HISTORY` shares history live between open terminals.
  The bash equivalent is a `PROMPT_COMMAND` hack that any other tool can clobber — and in
  fact did here (see *Interop* below).
- **Autosuggestions and syntax highlighting** are packaged by Debian
  (`zsh-autosuggestions`, `zsh-syntax-highlighting`), so no git clones and no separate
  update path.
- It costs nothing measurable: 16 ms interactive startup, *faster* than the configured
  bash at 18 ms.

**bash is not abandoned.** It gets the same aliases, history policy, `LS_COLORS`,
starship prompt, and fzf/zoxide bindings via the same shared config, so it remains a
fully usable fallback. The script also refuses to switch the login shell until it has
proved zsh actually starts:

```sh
zsh -i -c 'echo ZSH_INTERACTIVE_OK'   # must succeed
zsh -l -i -c 'echo ZSH_LOGIN_OK'      # must succeed
```

Only then does it add zsh to `/etc/shells` and run `chsh`. If either check fails the
script dies with the login shell untouched, so a broken zsh config cannot lock you out.

### Prompt: starship

`starship` 1.22.1 from Debian apt — no curl-to-shell installer, and it is a native arm64
build. Two-line layout: context on the first line, a bare `❯` to type against on the
second, with the exit status, job count, and clock right-aligned. Slow or irrelevant
modules (`package`, `docker_context`, `aws`, `gcloud`) are disabled.

## Layout

```
~/.config/shell/common.sh     shared by both shells: PATH, env, aliases, functions
~/.config/shell/bash.sh       bash-only: history, shopt, readline, prompt
~/.config/shell/zsh.sh        zsh-only: history, completion, keys, plugins, prompt
~/.config/shell/generated.sh  LS_COLORS + BAT_THEME, resolved at install time
~/.config/starship.toml       prompt
~/.local/share/konsole/       Terminal.profile, CatppuccinMocha.colorscheme
~/.config/fontconfig/conf.d/75-emoji-fallback.conf
```

`~/.bashrc` and `~/.zshrc` only ever contain a marked four-line block:

```sh
# >>> linuxonmac terminal setup >>>
[ -f "$HOME/.config/shell/common.sh" ] && . "$HOME/.config/shell/common.sh"
[ -f "$HOME/.config/shell/zsh.sh" ] && . "$HOME/.config/shell/zsh.sh"
# <<< linuxonmac terminal setup <<<
```

Re-running the script strips the old block and appends a fresh one, so it never
accumulates and never fights edits made outside the markers.

## Startup cost

Measured in the guest, 25 runs each, warm caches:

| shell | | |
|---|---|---|
| zsh, login + interactive | `zsh -l -i -c exit` | **20 ms** |
| zsh, interactive | `zsh -i -c exit` | **16 ms** |
| bash, interactive | `bash -i -c exit` | **18 ms** |

Two things keep it there:

- **Cached tool init.** `starship init`, `zoxide init`, and `fzf --zsh` each cost a
  subprocess. Their output is cached under `~/.cache/shell/` and regenerated only when
  the tool's binary is newer than the cache, so normal startup is a plain `source`.
- **Deferred `compinit` security check.** The full insecure-directory scan runs at most
  once a day; otherwise `compinit -C` uses the cached dump.

## Quality of life

**History** — 200,000 entries, timestamped, shared live between terminals, duplicates
dropped (`HIST_IGNORE_ALL_DUPS`, `HIST_SAVE_NO_DUPS`), and anything typed with a leading
space stays out of the file. zsh's history lives at `~/.local/state/zsh/history`.

**Keys** — Up/Down do prefix history search (type `git`, press Up, get only your `git`
commands). Home/End/Delete and Ctrl-arrow word motion are bound explicitly, because zsh's
defaults for these are wrong in most terminals. `WORDCHARS` is trimmed so Ctrl-W stops at
path separators instead of eating a whole path. Ctrl-Space accepts an autosuggestion.
Ctrl-R and Ctrl-T are fzf.

**Aliases** degrade gracefully — `ls`/`ll`/`la`/`lt` use `eza` when present and fall back
to coreutils `ls --color=auto` when not. Debian ships `bat` and `fd` under the names
`batcat` and `fdfind` to avoid binary clashes; thin wrapper functions restore the
expected names without shadowing anything.

**Flow control is off** in both Konsole and zsh, so a stray Ctrl-S cannot freeze the
terminal mid-session — a genuinely common way to lose a Claude Code run.

## Claude Code specifics

Konsole does not export `COLORTERM` on its own, which makes truecolor-capable TUIs fall
back to 256 colours. The profile sets it explicitly:

```
Environment=TERM=xterm-256color,COLORTERM=truecolor
```

with a defensive fallback in `common.sh` for when tmux or ssh drops it. Verified inside a
real Konsole-equivalent PTY:

```
TERM=xterm-256color COLORTERM=truecolor
```

and the prompt emits true 24-bit SGR sequences (`\e[1;38;2;137;180;250m` — Catppuccin
blue `#89b4fa`), not indexed colour.

Emoji needed a fontconfig fix. Noto Color Emoji was installed but fontconfig resolved
emoji to DejaVu Sans' monochrome outlines first. The naive fix — `<prefer>` the emoji
font on the generic families — makes `fc-match monospace` return *Noto Color Emoji*,
which is worse. `75-emoji-fallback.conf` instead names each chain's real primary face
first and the emoji font second:

```
emoji      -> Noto Color Emoji
monospace  -> JetBrainsMono Nerd Font Mono
sans-serif -> Inter
serif      -> Noto Serif
```

## Interop with `10-dev-environment.sh`

That script hooks `~/.config/devenv/shell.sh` into `~/.bashrc` **and** `~/.profile`, and
its interactive half is bash-specific (`shopt`, `PS1` with bash escapes,
`fnm env --shell bash`, `direnv hook bash`, fzf's `key-bindings.bash`). Two consequences
were handled here:

- `~/.zprofile` sources `~/.profile` under `emulate sh`, so zsh inherits its PATH and
  environment — `node`, `npm`, `claude`, `JAVA_HOME`, pnpm and Flutter all resolve in
  zsh. Errors are swallowed so a bash-ism dropped into `~/.profile` can never break
  login. `common.sh` also adds the fnm/pnpm/Flutter paths directly as a fallback, in case
  that chain is ever broken.
- The fnm and direnv hooks installed that way are `PROMPT_COMMAND`-based and **never fire
  in zsh**, so `zsh.sh` re-installs the zsh-native ones
  (`fnm env --use-on-cd --shell zsh`, `direnv hook zsh`). Per-directory Node switching and
  direnv work in zsh as a result.

In **bash**, `devenv/shell.sh` is sourced after this setup's block, so its aliases and
`PS1` win there. That is left alone deliberately — bash is the fallback shell, and
fighting over load order between two independent installers is worse than letting the
later one win. In zsh, which is the login shell, this setup's aliases apply.

## What needs a new terminal or a re-login

- **Konsole profile, font, colours, scrollback, bell** — apply to **newly opened Konsole
  windows and tabs**. Already-open windows keep the profile they started with.
- **Login shell change to zsh** — applies to **new login sessions**. An already-running
  bash session stays bash; `exec zsh -l` switches immediately, or just open a new
  terminal. Konsole spawns the shell from `/etc/passwd`, so a new Konsole window is
  already a zsh session.
- **Shell config, aliases, prompt** — apply to any newly started shell.
- **Fontconfig emoji rule** — applies to newly started applications.

## Verified

Run in the guest, real output:

- `dpkg -l konsole` → `ii konsole 4:25.04.2-1 arm64`
- `kreadconfig6 --file konsolerc --group "Desktop Entry" --key DefaultProfile` →
  `Terminal.profile` (read back, not just written)
- `getent passwd jmkq` → `/usr/bin/zsh`
- `fc-match "JetBrainsMono Nerd Font Mono"` →
  `JetBrainsMonoNerdFontMono-Regular.ttf: "JetBrainsMono Nerd Font Mono" "Regular"`
- Glyph coverage read from the font's cmap via fontconfig — powerline separators
  (`U+E0B0`, `U+E0B2`), git branch (`U+E0A0`), dev icons (`U+E718` node, `U+E7A8` rust,
  `U+E73C` python), `U+F0320` (5-digit PUA), box drawing and `❯`/`✓`/`✗` all **present**;
  emoji (`U+1F600`) and CJK (`U+4E2D`) correctly **absent**, which is what proves the
  check is real and not matching everything.
- In a real PTY: `TERM=xterm-256color`, `COLORTERM=truecolor`, `zle` active, **zero bytes
  on stderr** during login.
- Startup timings in the table above.

Konsole's own font rasterisation was **not** captured as a screenshot: `org.kde.KWin` was
not registered on the session bus during this work and the KWin screenshot D-Bus call
timed out, and restarting the compositor was out of scope. Glyph rendering was instead
verified by rendering the exact TTF that the profile names, at the profile's size, with
the profile's colours — powerline separators, dev icons, box drawing, blocks, arrows and
the `❯` prompt character all rasterise correctly. Combined with the cmap coverage above
and the profile read-back, this is strong evidence, but it is not a photo of Konsole.

One diagnostic worth recording: `zsh -i -c` prints
`(eval):1: can't change option: zle` because `-c` never starts the line editor. In a real
terminal, where ZLE is active, stderr is empty. It is a test-harness artifact, not a
config bug — worth knowing before "fixing" it.
