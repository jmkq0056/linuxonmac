# Development environment — Debian 13 (trixie) arm64 guest

Everything below is installed and configured by
[`scripts/guest/10-dev-environment.sh`](../scripts/guest/10-dev-environment.sh).
That script is the source of truth: it is idempotent, so re-running it repairs
drift rather than duplicating work, and individual stages can be re-run on their
own.

```sh
# everything
bash scripts/guest/10-dev-environment.sh

# just one part
bash scripts/guest/10-dev-environment.sh node claude-code verify

# skip the ~3 GB Flutter SDK
SKIP_FLUTTER=1 bash scripts/guest/10-dev-environment.sh
```

Stages: `packages node python java containers claude-code git-setup mac-share
shell mongodb flutter verify`.

Run it as `jmkq`, not root — it calls `sudo` itself where it needs to. Every
`apt-get` invocation carries `-o DPkg::Lock::Timeout=900` because more than one
person or agent may be touching this box at a time; waiting for the dpkg lock is
always better than failing on it.

Because the macOS home is mounted at `~/mac`, the repo checkout is reachable
from inside the guest without copying anything:

```sh
bash ~/mac/Documents/linuxonmac/scripts/guest/10-dev-environment.sh
```

---

## What is installed

Versions are what was actually running on the guest after the script finished,
not what the package descriptions promise.

### Toolchain and shell utilities

| | version | notes |
|---|---|---|
| gcc | 14.2.0 | via `build-essential`, with `make` 4.4.1 |
| clang / clangd / lldb | Debian trixie | second C/C++ toolchain, and the LSP server editors want |
| gdb | 16.3 | |
| cmake / ninja / pkg-config | 3.31.x / 1.12 | |
| git | 2.47.3 | |
| gh | 2.46.0 | GitHub CLI, from Debian main |
| curl | 8.14.1 | |
| wget, unzip, zip, xz-utils, rsync | | |
| jq | 1.7 | |
| ripgrep | 14.1.1 | |
| fd | 10.2.0 | Debian ships it as `fdfind`; see *Renamed binaries* below |
| bat | 0.25.0 | Debian ships it as `batcat`; same |
| tree | 2.2.1 | |
| htop | 3.4.1 | |
| ncdu, tmux, vim, sqlite3, shellcheck | | |
| fzf | 0.60.x | wired into bash (`Ctrl-T`, `Ctrl-R`, `Alt-C`) |
| direnv | 2.35.x | hooked into bash |

### Node.js

| | version |
|---|---|
| fnm | 1.39.0 |
| node | **v24.19.0** (current LTS) |
| npm | 11.17.0 |
| pnpm | 11.22.0 |
| npx | 11.17.0 |

Node is managed by **fnm**, not the `nodejs` Debian package — trixie's is far
behind and there is no way to hold two versions side by side with it. fnm was
chosen over nvm because nvm is a ~4000-line shell function that adds noticeable
latency to every shell start, whereas fnm is a single static binary; both
understand `.nvmrc`, so no project needs to care which one is installed.

`fnm env --use-on-cd` is in the shell config, so `cd`-ing into a project with a
`.nvmrc` or `.node-version` switches Node automatically.

The important subtlety: `~/.local/share/fnm/aliases/default/bin` is also placed
on `PATH` directly. That path is a symlink that follows fnm's `default` alias, so
`node`, `npm`, `npx` and `claude` resolve in **any** shell — including
non-interactive ones like `ssh guest 'npm run build'` and systemd units — not
only in shells that have evaluated `fnm env`. Without it, anything scripted
against this machine would find no Node at all.

**pnpm is installed as a plain global npm package, not through corepack's
shims** — and that was not the first attempt. corepack's `pnpm` shim re-reads
`package.json`'s `packageManager` field and hard-errors on anything that is not
an exact version; `pnpm init` itself writes a caret range
(`"version": "^11.22.0"`), so a corepack-shimmed pnpm refuses to install into a
project it created seconds earlier:

```
Invalid package manager specification in package.json (pnpm@^11.22.0);
expected a semver version
```

The script therefore runs `corepack disable pnpm yarn` and installs pnpm with
npm. corepack is still there for projects that pin an exact version on purpose
(`corepack use pnpm@x.y.z`).

### Claude Code

```
$ claude --version
2.1.235 (Claude Code)
```

Installed with `npm install -g @anthropic-ai/claude-code` — package name
verified against the actual registry install, not assumed.

**One wrinkle worth recording.** npm 11 no longer runs a package's install
scripts unless the package is explicitly allow-listed, and Claude Code's
`postinstall` (`node install.cjs`) is what finishes setting it up. A plain
`npm install -g @anthropic-ai/claude-code` therefore succeeds, prints a warning
that is easy to scroll past, and leaves you with a half-installed package. The
script pins this down:

```sh
npm config set allow-scripts=@anthropic-ai/claude-code --location=user
npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code
```

Claude Code is unauthenticated on a fresh install — run `claude` once
interactively to log in.

The rest of the environment is deliberately friendly to it: `ripgrep`, `fd`,
`jq`, `gh` and `git` are all present, which are the tools it reaches for most,
and `gh` gives it a working GitHub path once you `gh auth login`.

### Python

| | version |
|---|---|
| python3 | 3.13.5 |
| pip | 25.1.1 |
| pipx | 1.7.1 |
| venv | stdlib (`python3-venv`) |

Debian 13's system Python is marked
[PEP 668](https://peps.python.org/pep-0668/) *externally managed*: `pip install`
into it is refused. **This is not overridden**, because the failure mode it
prevents — pip and apt fighting over the same `site-packages` until something in
the desktop session breaks — is genuinely bad. Use:

- `pipx install <tool>` for command-line applications (ruff, poetry, httpie…),
  which get their own venv and land on `PATH`;
- `python3 -m venv .venv && . .venv/bin/activate` for project work.

Headers for the usual native wheels (`libssl-dev`, `zlib1g-dev`, `libffi-dev`,
`libsqlite3-dev`, `libbz2-dev`, `libreadline-dev`, `python3-dev`) are installed,
so packages without an arm64 wheel can still build from source.

### Java

| | version |
|---|---|
| java / javac | OpenJDK 21.0.12 |
| maven | 3.9.9 |

`default-jdk` on trixie is OpenJDK 21 (LTS). `JAVA_HOME` is exported as
`/usr/lib/jvm/java-21-openjdk-arm64`, derived at setup time by resolving
`javac` rather than hardcoded, so it survives a JDK upgrade.

### Containers — Podman, not Docker

**Podman 5.4.2**, plus `podman-compose`, `buildah`, `skopeo`, and
`podman-docker` (which provides a `docker` command that forwards to podman).

Verified working rootless:

```
$ podman info --format '{{.Host.Security.Rootless}} / {{.Store.GraphDriverName}} / {{.Host.Arch}}'
true / overlay / arm64

$ podman run --rm docker.io/library/alpine:latest uname -m
aarch64
```

#### Why podman here

The usual argument for Docker on macOS — that Docker Desktop's VM is heavy — is
irrelevant on this box, because **the guest is already the VM**. Docker Engine
would run natively here just as podman does. So the choice came down to the
things that actually differ:

- **No daemon, no root.** Podman is rootless by default: containers run as
  `jmkq` inside a user namespace, with no privileged long-lived daemon whose
  socket is effectively root access to the machine. On a single-developer box
  that several agents also have shell on, that is worth having.
- **It is in Debian main.** No third-party apt repository, no GPG key to
  install and later have expire, no risk of a vendor repo breaking a
  `dist-upgrade`. It updates with the rest of the system. Docker CE would mean
  adding and maintaining `download.docker.com`, and Docker's own repo has no
  trixie suite yet — you would be pinning it to `bookworm`.
- **Container restart survives logout.** `loginctl enable-linger jmkq` is set,
  so a rootless `mongod` keeps running after the SSH session or desktop session
  ends. Without linger, rootless containers die with your last login session,
  which is a nasty surprise the first time it happens.
- **Docker compatibility is kept anyway.** `podman-docker` supplies the `docker`
  CLI, and the user socket at
  `/run/user/1000/podman/podman.sock` speaks the Docker API. `DOCKER_HOST` is
  exported to point at it, so Testcontainers, `docker compose`, and IDE Docker
  plugins work unmodified.

The honest trade-offs, so you can reverse the decision knowingly:

- `podman-compose` is a re-implementation, not Compose v2. Most `compose.yaml`
  files work; exotic ones (complex `depends_on` conditions, some networking
  modes, `profiles`) can differ. If you hit one, install Compose v2 as a plugin
  and point it at the podman socket — it will work, because the socket is
  Docker-API compatible.
- Rootless containers cannot bind ports below 1024 without
  `net.ipv4.ip_unprivileged_port_start`. Map `8080:80` instead of `80:80`.
- Filesystem performance is best on the guest's own disk. Do not bind-mount a
  project out of `/mnt/mac` into a container for anything write-heavy.

Switching to Docker later is a `sudo apt remove podman-docker` plus adding
Docker's repo — nothing in this setup locks you in.

### MongoDB

**`mongosh` 2.10.0** is installed natively at `~/.local/bin/mongosh`.

The **server runs as a container**, not as a package, and this is forced rather
than chosen:

- Debian removed MongoDB from its archive over the SSPL licence change, so there
  is no `mongodb-server` in trixie.
- MongoDB's own apt repository has **no `trixie` suite and no Debian arm64
  builds** — their arm64 Linux packages target Ubuntu. Wiring the `bookworm`
  suite into a trixie box would drag in mismatched OpenSSL and is not worth it.
- The official `mongo` container image *is* published for `linux/arm64`, and
  runs natively here at full speed. That is the supported path.

A helper is defined in the shell config:

```sh
mongo-dev start     # MongoDB 8 on localhost:27017, data in a named volume
mongo-dev shell     # mongosh against it
mongo-dev logs
mongo-dev stop      # data survives
mongo-dev rm        # container and volume both gone
```

`mongosh` itself is installed from MongoDB's own `linux-arm64` tarball (their
GitHub releases feed is queried for the current version), because there is no
apt route to it here either.

### Flutter

```
$ flutter --version
Flutter 3.47.0 • channel stable • https://github.com/flutter/flutter.git
Framework • revision 4cf2416426 (2026-08-11)
Engine   • hash 59d54a2b2896a6bbf356c94b7fac7b9e235bdacd (revision 5f77625673)
Tools    • Dart 3.13.0 • DevTools 2.60.0

$ dart --version
Dart SDK version: 3.13.0 (stable) on "linux_arm64"
```

Note `linux_arm64` — the toolchain is running natively, not under Rosetta.

The SDK is cloned to `~/.local/share/flutter` and put on `PATH`.

Google publishes prebuilt Flutter SDK archives for **linux-x64 only** — there is
no `flutter_linux_*-stable.tar.xz` for arm64. On arm64 the supported route is a
git clone of the `stable` channel, after which the tool downloads `linux-arm64`
engine artifacts on first invocation. That is what the `flutter` stage does. It
also enables the Linux desktop target and installs its build dependencies
(`libgtk-3-dev`, `liblzma-dev`, `ninja-build`, `clang`, `pkg-config`,
`libglu1-mesa`).

`flutter doctor` on this guest, verbatim:

```
[✓] Flutter (Channel stable, 3.47.0, on Debian GNU/Linux 13 (trixie) 6.12.101+deb13-arm64)
[✗] Android toolchain — Unable to locate Android SDK
[✗] Chrome — Cannot find Chrome executable at google-chrome
[✓] Linux toolchain — develop for Linux desktop
[✓] Connected device (1 available)
[✓] Network resources
```

And an actual build, not just a version string:

```
$ flutter create demo_app && cd demo_app && flutter build linux --debug
[1/1] Linux SDK
  ├─ [1/3] linux-arm64-debug/linux-arm64-flutter-gtk     4.4s
  ├─ [2/3] linux-arm64-profile/linux-arm64-flutter-gtk   1,416ms
  └─ [3/3] linux-arm64-release/linux-arm64-flutter-gtk   1,327ms
✓ Built build/linux/arm64/debug/bundle/demo_app
```

What you can and cannot build from this guest:

- **Linux desktop** — yes, natively, verified above. The `[✓] Linux toolchain`
  line is what the `libgtk-3-dev` / `ninja-build` / `clang` / `pkg-config`
  packages are there for.
- **Web** — the compiler works, but `flutter doctor` reports no Chrome because
  none is installed. Either `sudo apt install chromium` and
  `export CHROME_EXECUTABLE=/usr/bin/chromium`, or skip the browser entirely
  with `flutter run -d web-server` and open the printed URL from Safari on
  macOS. The second option is lighter and is the recommended one here.
- **Android** — the toolchain is intentionally *not* installed. It needs the
  Android SDK command-line tools plus an emulator, and a nested emulator inside
  a Virtualization.framework guest gets no hardware acceleration, so it would be
  a trap. Attach a physical device over USB, or build the APK here and install
  it from macOS.
- **iOS/macOS** — impossible from Linux at all; those targets require Xcode.
  Since `~/mac` is your real macOS home, the natural split is to keep the
  project under `~/mac/…`, edit and run Linux/web builds from the guest, and do
  iOS builds on the macOS side against the very same checkout.

The stage is skippable with `SKIP_FLUTTER=1` because the clone plus engine
artifacts run to a few GB.

**A warning learned the hard way.** An unconstrained
`flutter build linux --release` took this guest down. It saturated every vCPU
for long enough that `systemd-logind` missed its three-minute watchdog and was
killed; `plasmashell` then died repeatedly and `sshd` stopped completing
logins. The VM had to be cold-booted. (It has since been given 8 vCPUs and
15 GB, up from 6 and 9.7 GB, which helps but does not make the problem go away.)

From the outside this is indistinguishable from a crash: the guest stops
answering SSH *and* ICMP while the host still shows the VM process pinned near
100% of every core.

So cap heavy builds. A debug build finishes in seconds and verifies the same
toolchain:

```sh
flutter build linux --debug                  # seconds, and proves the toolchain

nice -n 19 flutter build linux --release     # when you really need release
nice -n 19 make -j4                          # not -j$(nproc)
```

Better still, put the build in a cgroup that cannot starve the desktop:

```sh
systemd-run --user --scope -p CPUQuota=400% -p MemoryMax=6G --nice=19 \
  flutter build linux --release
```

The same applies to `pnpm install` on a large monorepo, `cargo build`, and any
`ninja`/`make` invocation that defaults to `-j$(nproc)`. It is not a fault in
the setup — it is a shared VM being asked for everything at once, with a
desktop session and a watchdog that both need a slice.

---

## Git configuration

Identity (name taken from the existing macOS `~/.gitconfig`, email as
specified):

```
user.name   Whosegonnacarrytheboatsnthelogs
user.email  saimibrahim679@gmail.com
```

Note this is deliberately a **different email** from the macOS config
(`jawa0056@gmail.com`) — commits made in the guest are attributable to it.

Behaviour worth knowing about:

| setting | value | why |
|---|---|---|
| `init.defaultBranch` | `main` | matches every host you push to |
| `pull.rebase` | `true` | no accidental merge bubbles from `git pull` |
| `push.autoSetupRemote` | `true` | `git push` on a fresh branch just works, no `-u` |
| `fetch.prune` | `true` | deleted remote branches stop haunting `git branch -a` |
| `rebase.autoStash` | `true` | rebase with a dirty tree instead of being told off |
| `rerere.enabled` | `true` | conflict resolutions are remembered and replayed |
| `diff.algorithm` | `histogram` | markedly better diffs on refactors than `myers` |
| `diff.colorMoved` | `zebra` | moved code shown as moved, not as delete+add |
| `merge.conflictstyle` | `zdiff3` | conflict markers include the common ancestor |
| `branch.sort` | `-committerdate` | `git branch` lists most-recent first |
| `help.autocorrect` | `prompt` | asks before running what it thinks you meant |

### Credential caching

```
credential.helper = cache --timeout=28800
```

An 8-hour in-memory cache: enter a token once in the morning, not once per push.
**Nothing is written to disk** — deliberately, `store` was not used, since that
would leave a plaintext token in `~/.git-credentials` on a VM whose home
directory sits next to a shared virtiofs mount.

For GitHub specifically, prefer `gh auth login` and then
`gh auth setup-git`, which is what the macOS side already does.

### Global gitignore

At `~/.config/git/ignore` (the XDG location git reads, also set explicitly as
`core.excludesfile`). It covers **machine noise only** — OS droppings
(`.DS_Store` and friends, which matter here because a Mac writes into the same
filesystem you work in), editor directories, `.direnv/`, `__pycache__/`,
`.venv/`, `*.orig`/`*.rej`, and `*.local` env files.

It deliberately does **not** contain `node_modules/`, `build/`, `dist/` or
`.env`. Those belong in each project's own `.gitignore`, where collaborators can
see them; hiding them globally means your repo looks clean on your machine and
broken on everyone else's. `.env.local` and `.env.*.local` *are* included,
because those names are Next.js's convention for never-committed files and no
project ever wants them tracked.

---

## The macOS home directory at `~/mac`

`/mnt/mac` is your macOS home over virtiofs, read-write, no copying and no sync
delay — it is the same bytes. It is made discoverable in four ways:

1. **`~/mac`** — symlink, re-created on every run of the script.
2. **`~/mac-share.txt`** — a short plain-text explainer sitting in the home
   directory, so someone who has never seen this machine can find out what the
   folder is without reading this repo.
3. **File manager sidebar** — added to `~/.local/share/user-places.xbel`
   (Dolphin, which is what KDE Plasma uses here) and to
   `~/.config/gtk-3.0/bookmarks` (GTK apps).
4. **Shell aliases** — `mac` (`cd ~/mac`) and `macd` (`cd ~/mac/Documents`).

The `/etc/fstab` entry is re-asserted idempotently by the `mac-share` stage, so
the mount cannot silently go missing after a re-run.

Things that will bite you, documented in `~/mac-share.txt` too:

- **virtiofs is slow on metadata-heavy work.** A first access after boot can
  take several seconds to warm up, and `npm install`, `.git` operations on large
  repos, and anything that stats thousands of files are all noticeably slower
  than on the guest's own disk. Keep source under `~/mac` if you want to share
  it with macOS, but keep `node_modules`, `.venv` and build output on the Linux
  disk.
- **macOS is case-insensitive, Linux is not.** Two files differing only in case
  cannot coexist under `~/mac`.
- **No clipboard sharing.** Virtualization.framework offers it for macOS guests
  only. `~/mac` is the channel for moving things across.

`safe.directory` is set for `/mnt/mac/*` so git does not refuse to operate on
repos there over ownership mismatches across the virtiofs boundary.

---

## Shell

The config is split into two generated files, and the split is the important
part:

| file | contents | sourced from |
|---|---|---|
| `~/.config/devenv/env.sh` | **environment only** — `PATH`, `JAVA_HOME`, `FNM_DIR`, `PNPM_HOME`, `DOCKER_HOST`, `EDITOR`. Strict POSIX `sh`, no bash-isms, no zsh-isms. | `~/.zshenv`, top of `~/.bashrc`, `~/.profile` |
| `~/.config/devenv/interactive.sh` | aliases, `mongo-dev`, `mkcd`, history settings, fnm/direnv/fzf wiring, bash prompt | `~/.bashrc`, `~/.zshrc` |

Regenerating both is safe; each hook line is added exactly once, keyed on a
marker, so the script can be re-run any number of times.

### Why environment and interactive are separate files

Because **which shell this account uses is not fixed**, and the environment has
to survive that. Halfway through setting this machine up, the login shell was
changed from `/bin/bash` to `/usr/bin/zsh` by other work happening on the same
box. Everything still looked fine from an interactive terminal — and
`ssh guest 'node --version'` started answering `command not found`, because
the config was hooked into `.bashrc` only.

Each shell finds the environment by a different route, so all three are wired:

| shell | file | when it is read |
|---|---|---|
| zsh | `~/.zshenv` | **every** invocation — interactive, login, and `ssh guest cmd` |
| bash | `~/.bashrc` | `ssh guest cmd` too, but *only* above the stock `case $- in *i*) ;; *) return;; esac` guard, so the hook is prepended, not appended |
| sh / bash | `~/.profile` | login shells, and the Plasma session's environment |

`interactive.sh` guards itself with the same `case $- in *i*)` test and branches
on `$BASH_VERSION` / `$ZSH_VERSION`, because `fnm env`, `direnv hook` and fzf's
key bindings each need a different incantation per shell. It deliberately sets
a prompt **only for bash** — the zsh prompt belongs to whatever theme
configuration owns `~/.config/shell/zsh.sh`, and clobbering it would be rude.

The failure this prevents is invisible from a terminal and breaks everything
scripted, which is exactly the kind of bug that survives a casual "looks fine to
me" check. Verify it the way it actually fails:

```sh
ssh guest 'node --version'     # not: ssh guest, then node --version
```

The interactive half gives you:

- **History that is actually useful**: 100k entries, deduplicated
  (`erasedups`), timestamped, appended rather than overwritten so parallel
  terminals do not clobber each other's history.
- **fzf** key bindings (`Ctrl-R` history search, `Ctrl-T` file picker,
  `Alt-C` directory jump), backed by `fdfind` so it respects `.gitignore` and
  skips `.git`.
- **direnv** hook, for per-project env vars via `.envrc`.
- A prompt showing user@host, cwd, and the current git branch (bash only).
- Aliases for the everyday shapes (`ll`, `gs`, `gd`, `gl`, `dps`, `ports`,
  `serve`, `mkcd`, `mac`) and the `mongo-dev` helper.

### Renamed binaries

Debian ships ripgrep's siblings under different names to avoid clashing with
other packages: `fd` is `fdfind`, `bat` is `batcat`. The script symlinks the
conventional names into `~/.local/bin`, rather than aliasing them, so that
**scripts** — including anything Claude Code writes — find them too. Aliases
only exist in interactive shells and would not have helped there.

---

## What is deliberately absent

- **Docker Engine** — see the podman rationale above.
- **MongoDB server as a package** — not available for this distribution and
  architecture; runs as a container instead.
- **Android SDK / emulator** — a nested emulator gets no hardware acceleration
  inside a Virtualization.framework guest, so it would be a trap rather than a
  feature. Add the command-line tools if you want to build APKs for a physical
  device.
- **A `pip install` that works against the system Python** — PEP 668 is left
  switched on for the reasons above.
- **`nvm`** — fnm covers the same ground with the same `.nvmrc` files and does
  not add shell-startup latency.

---

## Verifying

```sh
bash scripts/guest/10-dev-environment.sh verify
```

prints every tool with the version it actually reports, marks anything missing,
and ends with the resolved `~/mac` target and the configured git identity.

### End-to-end smoke test, actually run on this guest

Not "the binary exists" — each of these compiled, started, or round-tripped:

| | result |
|---|---|
| C | `gcc -O2 -Wall` compiled and ran a binary |
| Java | `javac` + `java` compiled and ran a class |
| Python | `venv` created, `pip install requests` → `requests 2.34.2` imported |
| pipx | `pipx install httpie` → `http 3.2.4` on `PATH` |
| Node + npm | `npm install express`, listened on :3737 |
| **REST API** | `curl … \| jq .` → `{"ok": true, "node": "v24.19.0"}` |
| pnpm | `pnpm init` + `pnpm add lodash` → `lodash 4.18.1` required at runtime |
| Podman | `podman run --rm alpine uname -m` → `aarch64`, rootless, overlay driver |
| **MongoDB** | `mongo:8` container up, `mongosh` inserted a doc, `countDocuments()` → 1 |
| **Flutter** | `flutter create` + `flutter build linux --debug` → `✓ Built build/linux/arm64/debug/bundle/demo_app` |
| git | commit authored as `Whosegonnacarrytheboatsnthelogs <saimibrahim679@gmail.com>` |
| global gitignore | `.DS_Store`, `.venv/`, `__pycache__/`, `.env.local` ignored; `.env` and `node_modules` correctly *not* ignored globally |
| non-interactive shell | `ssh guest 'node --version'` → `v24.19.0` on a fresh, unmultiplexed connection (see below) |

Podman, MongoDB and the Express round-trip were re-run after the guest was cold
booted, so they are confirmed to survive a restart rather than merely having
worked once during setup.

### The non-interactive PATH trap, twice

This bit me in two different ways, and both are worth writing down because both
were invisible from an interactive terminal.

**First:** Debian's stock `~/.bashrc` opens with

```sh
case $- in *i*) ;; *) return;; esac
```

so anything *appended* to it is never reached by a non-interactive shell — which
is exactly what `ssh guest 'npm run build'`, a systemd unit, or a tool shelling
out gets. The hook now goes at the **top** of `.bashrc`, above that guard.

**Second:** the account's login shell was later changed from bash to zsh by
other work on the same machine, and zsh never reads `.bashrc` at all. Node
silently vanished from every scripted invocation again. The fix is
`~/.zshenv` — the one zsh startup file read on *every* invocation, non-login and
non-interactive included.

Verified after both fixes, on a fresh unmultiplexed connection:

```
$ ssh guest 'node --version'
v24.19.0
$ ssh guest 'npm --version; pnpm --version; claude --version'
11.17.0
11.22.0
2.1.235 (Claude Code)
$ ssh guest 'echo $JAVA_HOME; echo $DOCKER_HOST'
/usr/lib/jvm/java-21-openjdk-arm64
unix:///run/user/1000/podman/podman.sock
```

### Re-running the script

Verified idempotent: the full script was re-run end to end on the recovered
guest after a cold boot and finished `EXIT=0` with no warnings, reinstalling
nothing and duplicating no config lines. `shellcheck -S warning` is clean.

Re-running is also the repair path — if a crash interrupts setup, or another
tool rewrites a dotfile, re-run it and the environment is put back.
