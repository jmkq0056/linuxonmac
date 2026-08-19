#!/usr/bin/env bash
# 10-dev-environment.sh — turn the Debian 13 (trixie) arm64 guest into a
# development machine for Flutter / Next.js / Node / MongoDB / Java / Python / C,
# and a comfortable host for Claude Code.
#
# Run it inside the guest, as the normal user (it calls sudo itself):
#
#     bash scripts/guest/10-dev-environment.sh
#
# Idempotent: re-running it is a no-op for anything already in place, and safe
# to run after a distro upgrade to re-assert every setting.
#
# Stages can be run individually:
#
#     bash 10-dev-environment.sh packages node python java containers \
#          claude-code git-setup mac-share shell mongodb flutter verify
#
# Environment knobs:
#     SKIP_FLUTTER=1     don't clone/precache the Flutter SDK (it is ~3 GB)
#     NODE_VERSION=lts   version passed to `fnm install` (default: --lts)

set -euo pipefail

# ---------------------------------------------------------------------------
# Preamble
# ---------------------------------------------------------------------------

if [[ ${EUID} -eq 0 ]]; then
  echo "Run this as your normal user, not root — it uses sudo where it needs to." >&2
  exit 1
fi

USER_NAME="$(id -un)"
export HOME="${HOME:-/home/${USER_NAME}}"

GIT_USER_NAME="${GIT_USER_NAME:-Whosegonnacarrytheboatsnthelogs}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-saimibrahim679@gmail.com}"

FNM_DIR="${HOME}/.local/share/fnm"
FLUTTER_DIR="${HOME}/.local/share/flutter"
LOCAL_BIN="${HOME}/.local/bin"
ENV_SH="${HOME}/.config/devenv/env.sh"
INTERACTIVE_SH="${HOME}/.config/devenv/interactive.sh"
MAC_MOUNT=/mnt/mac

# `apt-get` is shared with other people/agents on this box, so always wait for
# the dpkg lock rather than failing.
APT=(sudo apt-get -o DPkg::Lock::Timeout=900 -y)
export DEBIAN_FRONTEND=noninteractive

log()  { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    !! %s\033[0m\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

# Append $2 to file $1 exactly once, keyed on the marker $3.
append_once() {
  local file="$1" block="$2" marker="$3"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  grep -qF "$marker" "$file" || printf '%s\n' "$block" >>"$file"
}

# Insert $2 at the *top* of file $1 exactly once, keyed on the marker $3.
# Needed for ~/.bashrc: Debian's stock version opens with
#     case $- in *i*) ;; *) return;; esac
# so anything appended at the end is never reached by a non-interactive shell —
# which is exactly what `ssh guest 'npm run build'` and systemd units get.
prepend_once() {
  local file="$1" block="$2" marker="$3" tmp
  mkdir -p "$(dirname "$file")"
  touch "$file"
  grep -qF "$marker" "$file" && return 0
  tmp="$(mktemp)"
  printf '%s\n' "$block" >"$tmp"
  cat "$file" >>"$tmp"
  cat "$tmp" >"$file"          # preserve the original inode/permissions
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Stage: packages
# ---------------------------------------------------------------------------

APT_PACKAGES=(
  # requested baseline
  build-essential git curl wget jq ripgrep fd-find bat tree htop unzip
  ca-certificates
  # archives / transport
  zip xz-utils gnupg lsb-release apt-transport-https rsync openssh-client
  # python
  python3-pip python3-venv python3-dev python3-setuptools pipx
  # java
  default-jdk maven
  # containers (see docs/DEV-ENVIRONMENT.md for why podman and not docker)
  podman podman-compose podman-docker buildah skopeo uidmap slirp4netns
  fuse-overlayfs passt
  # C / native toolchain beyond build-essential
  cmake ninja-build pkg-config clang clangd lldb gdb universal-ctags
  libssl-dev zlib1g-dev libffi-dev libsqlite3-dev libbz2-dev libreadline-dev
  # Flutter's Linux desktop target needs these
  libgtk-3-dev liblzma-dev libglu1-mesa fontconfig
  # shell / everyday
  sqlite3 tmux vim less man-db bash-completion fzf direnv shellcheck ncdu
  iproute2 dnsutils net-tools
)

stage_packages() {
  log "Installing base packages from Debian trixie"
  "${APT[@]}" update
  "${APT[@]}" install --no-install-recommends "${APT_PACKAGES[@]}"

  # `gh` is not in every trixie mirror; treat it as best-effort.
  if ! have gh; then
    "${APT[@]}" install gh || warn "GitHub CLI (gh) is not available from apt — skipped"
  fi

  # Debian renames two of these binaries to dodge name clashes with other
  # packages. Put the conventional names on PATH so scripts and muscle memory
  # both work.
  mkdir -p "$LOCAL_BIN"
  [[ -x /usr/bin/batcat ]] && ln -sfn /usr/bin/batcat "$LOCAL_BIN/bat"
  [[ -x /usr/bin/fdfind ]] && ln -sfn /usr/bin/fdfind "$LOCAL_BIN/fd"
  return 0
}

# ---------------------------------------------------------------------------
# Stage: node  (fnm + Node LTS + npm + pnpm)
# ---------------------------------------------------------------------------

stage_node() {
  log "Installing fnm and Node.js LTS"

  if [[ ! -x "$FNM_DIR/fnm" ]]; then
    info "fetching fnm"
    curl -fsSL https://fnm.vercel.app/install \
      | bash -s -- --install-dir "$FNM_DIR" --skip-shell
  else
    info "fnm already present at $FNM_DIR"
  fi

  export PATH="$FNM_DIR:$PATH"
  export FNM_DIR
  have fnm || { warn "fnm did not install"; return 1; }

  local want="${NODE_VERSION:---lts}"
  # `fnm install` exits non-zero when the version is already there, so swallow
  # that rather than let `set -e` treat a no-op as a failure.
  fnm install "$want" || true
  fnm default "$want" >/dev/null 2>&1 || fnm default lts-latest >/dev/null 2>&1 || true

  # $FNM_DIR/aliases/default/bin is a stable path that follows the default
  # alias, so node/npm/claude resolve in *any* shell — login, non-login, and
  # `ssh host somecommand` — not just ones that ran `fnm env`.
  export PATH="$FNM_DIR/aliases/default/bin:$PATH"
  hash -r

  have node || { warn "node not on PATH after fnm install"; return 1; }
  info "node $(node --version), npm $(npm --version)"

  # pnpm is installed as a plain global npm package, NOT through corepack's
  # shims. corepack's shim re-reads package.json's "packageManager" field and
  # hard-errors on anything that is not an exact version — and `pnpm init`
  # itself writes a caret range ("pnpm@^11.22.0"), so a corepack-shimmed pnpm
  # cannot install into a project it just created. corepack stays available for
  # projects that pin an exact version deliberately (`corepack use pnpm@x.y.z`).
  if have corepack; then
    corepack disable pnpm yarn 2>/dev/null || true
  fi
  npm install -g pnpm

  npm config set fund false --location=user 2>/dev/null || true
  npm config set update-notifier false --location=user 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------------------
# Stage: python
# ---------------------------------------------------------------------------

stage_python() {
  log "Configuring Python"
  # Debian 13 marks the system Python PEP 668 "externally managed": pip refuses
  # to install into it. That is the correct default — pipx for applications,
  # venv for projects — so we do not override it, we just make both convenient.
  mkdir -p "$LOCAL_BIN"
  if have pipx; then
    pipx ensurepath >/dev/null 2>&1 || true
    info "pipx $(pipx --version 2>/dev/null)"
  else
    warn "pipx missing — run the packages stage first"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Stage: java
# ---------------------------------------------------------------------------

stage_java() {
  log "Configuring Java"
  have javac || { warn "javac missing — run the packages stage first"; return 0; }
  local home
  home="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
  info "JAVA_HOME=$home"
  return 0
}

java_home_path() {
  if have javac; then
    dirname "$(dirname "$(readlink -f "$(command -v javac)")")"
  fi
}

# ---------------------------------------------------------------------------
# Stage: containers  (rootless podman)
# ---------------------------------------------------------------------------

stage_containers() {
  log "Configuring rootless Podman"
  have podman || { warn "podman missing — run the packages stage first"; return 0; }

  # Rootless containers need a subuid/subgid range for the user namespace.
  if ! grep -q "^${USER_NAME}:" /etc/subuid 2>/dev/null; then
    info "allocating subuid/subgid range for ${USER_NAME}"
    sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER_NAME"
    podman system migrate || true
  fi

  # Default to Docker Hub so `podman run node:22` resolves without a registry
  # prefix, the way docker does.
  mkdir -p "${HOME}/.config/containers"
  if [[ ! -f "${HOME}/.config/containers/registries.conf" ]]; then
    cat >"${HOME}/.config/containers/registries.conf" <<'CONF'
unqualified-search-registries = ["docker.io", "quay.io", "ghcr.io"]
CONF
  fi

  # The Docker-compatible API socket, for tools that speak the Docker API
  # (testcontainers, `docker compose`, IDE plugins).
  systemctl --user enable --now podman.socket 2>/dev/null \
    || warn "could not enable podman.socket (no user systemd session? it will start on next login)"

  # Keep the user's containers alive after the ssh session or desktop logout
  # ends, which is what you want for a long-running mongod.
  sudo loginctl enable-linger "$USER_NAME" 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------------------
# Stage: claude-code
# ---------------------------------------------------------------------------

stage_claude_code() {
  log "Installing Claude Code"
  export PATH="$FNM_DIR/aliases/default/bin:$LOCAL_BIN:$PATH"
  have npm || { warn "npm missing — run the node stage first"; return 1; }

  # Package name per Anthropic's install docs.
  # npm 11 refuses to run install scripts unless the package is allow-listed,
  # and Claude Code's postinstall is what unpacks its native launcher — without
  # this the package installs but is only half set up.
  npm config set allow-scripts=@anthropic-ai/claude-code --location=user 2>/dev/null || true
  npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code \
    || npm install -g @anthropic-ai/claude-code
  hash -r
  if have claude; then
    info "claude $(claude --version 2>&1 | head -1)"
  else
    warn "claude did not land on PATH"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Stage: git-setup
# ---------------------------------------------------------------------------

stage_git_setup() {
  log "Configuring git"

  git config --global user.name  "$GIT_USER_NAME"
  git config --global user.email "$GIT_USER_EMAIL"

  git config --global init.defaultBranch main
  git config --global pull.rebase true          # linear history, no merge bubbles
  git config --global push.default simple
  git config --global push.autoSetupRemote true # `git push` on a new branch just works
  git config --global fetch.prune true
  git config --global rebase.autoStash true
  git config --global rerere.enabled true       # remember conflict resolutions
  git config --global diff.algorithm histogram
  git config --global diff.colorMoved zebra
  git config --global merge.conflictstyle zdiff3
  git config --global log.date iso
  git config --global column.ui auto
  git config --global branch.sort -committerdate
  git config --global core.editor vim
  git config --global core.pager 'less -FRX'
  git config --global help.autocorrect prompt

  # Credential caching: remember a password/token for 8h in memory only.
  # Nothing is written to disk, so it is safe on a shared-ish VM.
  git config --global credential.helper 'cache --timeout=28800'

  # Treat the virtiofs-mounted macOS home as a safe place to hold repos even
  # though ownership can look odd across the 9p/virtiofs boundary.
  git config --global --replace-all safe.directory "${MAC_MOUNT}/*" || true

  # ---- global gitignore -------------------------------------------------
  local ignore="${HOME}/.config/git/ignore"
  mkdir -p "$(dirname "$ignore")"
  cat >"$ignore" <<'IGNORE'
# Global gitignore — machine, editor and OS noise only.
# Project build output belongs in the project's own .gitignore.

# macOS (this VM shares a home with a Mac over virtiofs)
.DS_Store
.AppleDouble
._*
.Spotlight-V100
.Trashes

# Linux / Windows
*~
.fuse_hidden*
.directory
.nfs*
Thumbs.db
Desktop.ini

# Editors & IDEs
.vscode/
.idea/
*.swp
*.swo
*.sublime-workspace
.\#*
\#*\#

# Local-only tooling state
.direnv/
.envrc.local
.claude/settings.local.json
.history/

# Local env files (the committed ones are .env / .env.example, never *.local)
.env.local
.env.*.local

# Python
__pycache__/
*.py[cod]
.venv/
.mypy_cache/
.pytest_cache/
.ruff_cache/

# Node
.npm-debug.log*
.pnpm-debug.log*
.yarn/cache/

# Ad-hoc scratch
*.orig
*.rej
scratch/
tmp/
IGNORE
  git config --global core.excludesfile "$ignore"
  info "global gitignore at $ignore"
  return 0
}

# ---------------------------------------------------------------------------
# Stage: mac-share  (/mnt/mac discoverability)
# ---------------------------------------------------------------------------

stage_mac_share() {
  log "Wiring up the macOS home share"

  # The mount itself is set up in docs/GUEST-SETUP.md; re-assert the fstab line
  # so a re-run of this script never leaves it half-configured.
  if ! grep -qs "[[:space:]]${MAC_MOUNT}[[:space:]]" /etc/fstab; then
    info "adding virtiofs entry to /etc/fstab"
    echo "home ${MAC_MOUNT} virtiofs defaults,nofail 0 0" | sudo tee -a /etc/fstab >/dev/null
    sudo mount -a || warn "mount -a failed — is the runner sharing the 'home' tag?"
  fi

  ln -sfn "$MAC_MOUNT" "${HOME}/mac"
  info "${HOME}/mac -> ${MAC_MOUNT}"

  # Show up in the file manager sidebar. GTK apps read `bookmarks`; Dolphin
  # (KDE Plasma is the desktop here) reads user-places.xbel.
  local gtkbm="${HOME}/.config/gtk-3.0/bookmarks"
  append_once "$gtkbm" "file://${MAC_MOUNT} macOS Home" "file://${MAC_MOUNT}"

  local xbel="${HOME}/.local/share/user-places.xbel"
  if [[ -f "$xbel" ]] && ! grep -qF "file://${MAC_MOUNT}" "$xbel"; then
    info "adding macOS Home to the Dolphin sidebar"
    python3 - "$xbel" "$MAC_MOUNT" <<'PY'
import sys, re
path, mount = sys.argv[1], sys.argv[2]
entry = (
    ' <bookmark href="file://%s">\n'
    '  <title>macOS Home</title>\n'
    '  <info><metadata owner="http://freedesktop.org">'
    '<bookmark:icon name="folder-mac"/></metadata></info>\n'
    ' </bookmark>\n' % mount
)
src = open(path, encoding="utf-8").read()
if "</xbel>" in src:
    open(path, "w", encoding="utf-8").write(src.replace("</xbel>", entry + "</xbel>", 1))
PY
  fi

  # A README on the Linux side explaining what the folder is.
  cat >"${HOME}/mac-share.txt" <<TXT
~/mac  ->  ${MAC_MOUNT}  ->  your macOS home directory (/Users/${USER_NAME})

Shared read-write over virtiofs; there is no copying and no sync delay — it is
the same bytes the Mac sees.

  cd ~/mac/Documents/some-project    # edit a Mac checkout from Linux
  cp build/app ~/mac/Desktop/        # hand a file back to macOS

Caveats
  * virtiofs is slower than the guest's own disk on metadata-heavy work. Keep
    node_modules, .venv, build/ and .git-heavy operations on the Linux disk;
    reach into ~/mac for source and for handing files across.
  * The first access after boot can take a few seconds while the share warms up.
  * macOS is case-insensitive, Linux is not. Two files differing only in case
    cannot both exist under ~/mac.
  * Clipboard is *not* shared (Virtualization.framework offers it for macOS
    guests only) — ~/mac is the way to move things between the two systems.
TXT
  return 0
}

# ---------------------------------------------------------------------------
# Stage: shell
# ---------------------------------------------------------------------------

stage_shell() {
  log "Writing shell configuration"
  mkdir -p "${HOME}/.config/devenv" "$LOCAL_BIN"

  local jhome
  jhome="$(java_home_path || true)"

  # -------------------------------------------------------------------------
  # env.sh — environment only, strict POSIX sh, safe to source from anything.
  #
  # This has to work under bash AND zsh AND dash, because which login shell
  # this account uses is not ours to decide (it has already changed once), and
  # because the file is sourced from ~/.zshenv, which zsh reads for *every*
  # invocation including `ssh guest 'npm run build'`.
  # -------------------------------------------------------------------------
  cat >"$ENV_SH" <<ENVSH
# Generated by scripts/guest/10-dev-environment.sh — edit that, not this.
# Strict POSIX sh: sourced by bash, zsh and dash alike. Environment only,
# nothing interactive, no shell-specific syntax.

_devenv_add() {
  case ":\$PATH:" in
    *":\$1:"*) ;;
    *) PATH="\$1:\$PATH" ;;
  esac
}

_devenv_add "\$HOME/.local/bin"
_devenv_add "$FNM_DIR"
# A stable path that follows fnm's "default" alias, so node/npm/npx/pnpm/claude
# resolve without any shell ever having to evaluate \`fnm env\`.
_devenv_add "$FNM_DIR/aliases/default/bin"
[ -d "$FLUTTER_DIR/bin" ] && _devenv_add "$FLUTTER_DIR/bin"
[ -d "\$HOME/.pub-cache/bin" ] && _devenv_add "\$HOME/.pub-cache/bin"
[ -d "\$HOME/.local/share/pnpm" ] && _devenv_add "\$HOME/.local/share/pnpm"
export PATH
unset -f _devenv_add

export FNM_DIR="$FNM_DIR"
export PNPM_HOME="\$HOME/.local/share/pnpm"
${jhome:+export JAVA_HOME="$jhome"}

export EDITOR=vim
export VISUAL=vim
export PAGER=less
export LESS=-FRX

# Podman's Docker-compatible API socket, for testcontainers / compose / IDEs.
_devenv_rt="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
[ -S "\$_devenv_rt/podman/podman.sock" ] && \\
  export DOCKER_HOST="unix://\$_devenv_rt/podman/podman.sock"
unset _devenv_rt
ENVSH

  # -------------------------------------------------------------------------
  # interactive.sh — aliases, helpers, completions. Branches on the shell,
  # because fnm/direnv/fzf all need a different incantation per shell.
  # -------------------------------------------------------------------------
  cat >"$INTERACTIVE_SH" <<'INTSH'
# Generated by scripts/guest/10-dev-environment.sh — edit that, not this.
# Interactive conveniences. Sourced from ~/.bashrc and ~/.zshrc.

case $- in *i*) ;; *) return 0 2>/dev/null || exit 0 ;; esac

# ---- shell-specific wiring ----------------------------------------------
if [ -n "${BASH_VERSION:-}" ]; then
  HISTSIZE=100000
  HISTFILESIZE=200000
  HISTCONTROL=ignoreboth:erasedups
  HISTTIMEFORMAT='%F %T  '
  shopt -s histappend checkwinsize cmdhist
  shopt -s globstar 2>/dev/null

  command -v fnm    >/dev/null 2>&1 && eval "$(fnm env --use-on-cd --shell bash)"
  command -v direnv >/dev/null 2>&1 && eval "$(direnv hook bash)"
  [ -f /usr/share/doc/fzf/examples/key-bindings.bash ] && \
    . /usr/share/doc/fzf/examples/key-bindings.bash
  [ -f /usr/share/doc/fzf/examples/completion.bash ] && \
    . /usr/share/doc/fzf/examples/completion.bash

  # Prompt: user@host, cwd, git branch. Only set for bash — the zsh prompt
  # belongs to whatever theme setup owns ~/.config/shell/zsh.sh.
  _devenv_git_branch() {
    local b
    b=$(git symbolic-ref --short HEAD 2>/dev/null) || return
    printf ' (%s)' "$b"
  }
  PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0;33m\]$(_devenv_git_branch)\[\e[0m\]$ '

elif [ -n "${ZSH_VERSION:-}" ]; then
  HISTSIZE=100000
  SAVEHIST=100000
  [ -n "${HISTFILE:-}" ] || HISTFILE="$HOME/.zsh_history"
  setopt APPEND_HISTORY INC_APPEND_HISTORY SHARE_HISTORY \
         HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS \
         EXTENDED_HISTORY 2>/dev/null

  command -v fnm    >/dev/null 2>&1 && eval "$(fnm env --use-on-cd --shell zsh)"
  command -v direnv >/dev/null 2>&1 && eval "$(direnv hook zsh)"
  [ -f /usr/share/doc/fzf/examples/key-bindings.zsh ] && \
    . /usr/share/doc/fzf/examples/key-bindings.zsh
  [ -f /usr/share/doc/fzf/examples/completion.zsh ] && \
    . /usr/share/doc/fzf/examples/completion.zsh
  # No PROMPT/PS1 here on purpose.
fi

if command -v fdfind >/dev/null 2>&1; then
  export FZF_DEFAULT_COMMAND='fdfind --type f --hidden --follow --exclude .git'
  export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
fi

# ---- aliases (identical in both shells) ----------------------------------
alias ll='ls -alFh --group-directories-first'
alias la='ls -A'
alias l='ls -CF'
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias df='df -h'
alias du='du -h'
alias ports='ss -tulpn'
alias serve='python3 -m http.server'

alias gs='git status -sb'
alias gd='git diff'
alias gl='git log --oneline --graph --decorate -20'
alias gp='git push'
alias gco='git checkout'

# podman also answers to `docker` via podman-docker; these are the shapes
# people actually type.
alias dps='podman ps -a'
alias dcu='podman-compose up -d'
alias dcd='podman-compose down'

alias mac='cd ~/mac'
alias macd='cd ~/mac/Documents'

# ---- helpers -------------------------------------------------------------
# A throwaway MongoDB 8 on localhost:27017. Data lives in a named volume, so
# it survives `stop` and only `rm` throws it away.
mongo-dev() {
  name=mongo-dev
  case "${1:-start}" in
    start)
      if podman container exists "$name"; then
        podman start "$name"
      else
        podman run -d --name "$name" -p 27017:27017 \
          -v mongo-dev-data:/data/db docker.io/library/mongo:8
      fi ;;
    stop)  podman stop "$name" ;;
    rm)    podman rm -f "$name"; podman volume rm -f mongo-dev-data ;;
    logs)  podman logs -f "$name" ;;
    shell)
      if command -v mongosh >/dev/null 2>&1; then
        mongosh "mongodb://localhost:27017"
      else
        podman exec -it "$name" mongosh
      fi ;;
    *) echo "usage: mongo-dev [start|stop|rm|logs|shell]" >&2 ;;
  esac
}

mkcd() { mkdir -p "$1" && cd "$1"; }
INTSH

  # -------------------------------------------------------------------------
  # Hook both files into every shell that might start on this box.
  #
  # The environment half has to reach non-interactive shells — `ssh guest
  # 'npm ci'`, systemd units, anything shelling out — and each shell finds it
  # by a different route:
  #
  #   zsh   ~/.zshenv   read on EVERY invocation, interactive or not
  #   bash  ~/.bashrc   read for `ssh guest cmd`, but only above the stock
  #                     `case $- in *i*) ;; *) return;; esac` guard
  #   sh    ~/.profile  login shells
  #
  # Getting this wrong is invisible from an interactive session and breaks
  # everything scripted, so all three are wired up.
  # -------------------------------------------------------------------------
  local env_hook int_hook
  env_hook='# devenv (scripts/guest/10-dev-environment.sh) — environment for every shell.
# Must stay above any "return if not interactive" guard below.
[ -f "$HOME/.config/devenv/env.sh" ] && . "$HOME/.config/devenv/env.sh"
'
  int_hook='
# devenv (scripts/guest/10-dev-environment.sh) — interactive conveniences.
[ -f "$HOME/.config/devenv/interactive.sh" ] && . "$HOME/.config/devenv/interactive.sh"
'

  # zsh: .zshenv for env (every invocation), .zshrc for the interactive half.
  prepend_once "${HOME}/.zshenv" "$env_hook" '.config/devenv/env.sh'
  append_once  "${HOME}/.zshrc"  "$int_hook" '.config/devenv/interactive.sh'

  # bash: both at the top of .bashrc, ahead of Debian's non-interactive
  # early-return; interactive.sh guards itself.
  prepend_once "${HOME}/.bashrc" "${env_hook}${int_hook}" '.config/devenv/env.sh'

  # sh/bash login shells.
  append_once "${HOME}/.profile" "$env_hook" '.config/devenv/env.sh'

  # An earlier revision of this script wrote a single combined shell.sh and
  # hooked that. Clean it up so a re-run does not leave two competing configs.
  if [[ -f "${HOME}/.config/devenv/shell.sh" ]]; then
    rm -f "${HOME}/.config/devenv/shell.sh"
    local f
    for f in "${HOME}/.bashrc" "${HOME}/.profile" "${HOME}/.zshrc" "${HOME}/.zshenv"; do
      [[ -f "$f" ]] && sed -i '/devenv\/shell\.sh/d' "$f"
    done
    info "removed the superseded ~/.config/devenv/shell.sh and its hooks"
  fi

  info "env: $ENV_SH"
  info "interactive: $INTERACTIVE_SH"
  return 0
}


# ---------------------------------------------------------------------------
# Stage: mongodb  (client only — the server runs as a container)
# ---------------------------------------------------------------------------

stage_mongodb() {
  log "Installing mongosh (MongoDB shell)"
  # MongoDB publishes no apt repo for Debian 13 arm64, and Debian dropped the
  # server from its archive over the SSPL licence. The server therefore runs as
  # a container (`mongo-dev start`); only the shell is installed natively, from
  # MongoDB's own linux-arm64 tarball.
  if have mongosh; then
    info "mongosh already installed: $(mongosh --version 2>/dev/null)"
    return 0
  fi

  local ver url tmp
  ver="$(curl -fsSL https://api.github.com/repos/mongodb-js/mongosh/releases/latest \
          | jq -r '.tag_name' | sed 's/^v//')" || ver=""
  [[ -n "$ver" && "$ver" != null ]] || { warn "could not determine latest mongosh version"; return 0; }

  url="https://downloads.mongodb.com/compass/mongosh-${ver}-linux-arm64.tgz"
  tmp="$(mktemp -d)"
  if curl -fsSL "$url" -o "$tmp/mongosh.tgz"; then
    tar -xzf "$tmp/mongosh.tgz" -C "$tmp"
    mkdir -p "$LOCAL_BIN" "${HOME}/.local/lib"
    cp -f "$tmp"/mongosh-*/bin/mongosh "$LOCAL_BIN/" 2>/dev/null || true
    cp -f "$tmp"/mongosh-*/bin/mongosh_crypt_v1.so "${HOME}/.local/lib/" 2>/dev/null || true
    chmod +x "$LOCAL_BIN/mongosh" 2>/dev/null || true
    info "mongosh ${ver} -> $LOCAL_BIN/mongosh"
  else
    warn "mongosh ${ver} linux-arm64 tarball not downloadable — use \`mongo-dev shell\` (mongosh inside the container) instead"
  fi
  rm -rf "$tmp"
  return 0
}

# ---------------------------------------------------------------------------
# Stage: flutter
# ---------------------------------------------------------------------------

stage_flutter() {
  if [[ "${SKIP_FLUTTER:-0}" == "1" ]]; then
    log "Skipping Flutter (SKIP_FLUTTER=1)"
    return 0
  fi
  log "Installing the Flutter SDK"
  # Google publishes prebuilt Flutter SDK tarballs for linux-x64 only, so on
  # arm64 the supported route is a git clone of the stable channel; the tool
  # then downloads linux-arm64 engine artifacts on first run.
  if [[ ! -d "$FLUTTER_DIR/.git" ]]; then
    git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$FLUTTER_DIR"
  else
    info "updating existing clone"
    git -C "$FLUTTER_DIR" fetch --depth 1 origin stable && \
      git -C "$FLUTTER_DIR" reset --hard origin/stable
  fi

  export PATH="$FLUTTER_DIR/bin:$PATH"
  git config --global --add safe.directory "$FLUTTER_DIR" || true
  flutter config --no-analytics >/dev/null 2>&1 || true
  flutter config --enable-linux-desktop >/dev/null 2>&1 || true

  if flutter --version; then
    info "flutter ready"
  else
    warn "the Flutter tool failed to run on arm64 — see docs/DEV-ENVIRONMENT.md"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Stage: verify
# ---------------------------------------------------------------------------

stage_verify() {
  log "Verifying the toolchain"
  export PATH="$LOCAL_BIN:$FNM_DIR:$FNM_DIR/aliases/default/bin:$FLUTTER_DIR/bin:$PATH"
  hash -r

  local rows=(
    "gcc|gcc --version"
    "make|make --version"
    "git|git --version"
    "curl|curl --version"
    "jq|jq --version"
    "rg|rg --version"
    "fd|fd --version"
    "bat|bat --version"
    "tree|tree --version"
    "htop|htop --version"
    "unzip|unzip -v"
    "fnm|fnm --version"
    "node|node --version"
    "npm|npm --version"
    "pnpm|pnpm --version"
    "npx|npx --version"
    "python3|python3 --version"
    "pip3|pip3 --version"
    "pipx|pipx --version"
    "java|java -version"
    "javac|javac -version"
    "mvn|mvn -v"
    "podman|podman --version"
    "podman-compose|podman-compose --version"
    "docker|docker --version"
    "mongosh|mongosh --version"
    "claude|claude --version"
    "flutter|flutter --version"
    "dart|dart --version"
    "cmake|cmake --version"
    "clang|clang --version"
    "gdb|gdb --version"
    "tmux|tmux -V"
    "fzf|fzf --version"
    "direnv|direnv version"
  )
  local ok=0 missing=0
  for row in "${rows[@]}"; do
    local name="${row%%|*}" cmd="${row#*|}"
    if have "$name"; then
      printf '  \033[32m✓\033[0m %-15s %s\n' "$name" \
        "$(eval "$cmd" 2>&1 | head -1)"
      ok=$((ok + 1))
    else
      printf '  \033[31m✗\033[0m %-15s not installed\n' "$name"
      missing=$((missing + 1))
    fi
  done
  printf '\n  %d present, %d missing\n' "$ok" "$missing"

  printf '\n  ~/mac -> %s\n' "$(readlink -f "${HOME}/mac" 2>/dev/null || echo 'MISSING')"
  printf '  git identity: %s <%s>\n' \
    "$(git config --global user.name)" "$(git config --global user.email)"
  return 0
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

ALL_STAGES=(packages node python java containers claude-code git-setup
            mac-share shell mongodb flutter verify)

run_stage() {
  case "$1" in
    packages)     stage_packages ;;
    node)         stage_node ;;
    python)       stage_python ;;
    java)         stage_java ;;
    containers)   stage_containers ;;
    claude-code)  stage_claude_code ;;
    git-setup)    stage_git_setup ;;
    mac-share)    stage_mac_share ;;
    shell)        stage_shell ;;
    mongodb)      stage_mongodb ;;
    flutter)      stage_flutter ;;
    verify)       stage_verify ;;
    *) echo "unknown stage: $1" >&2; echo "stages: ${ALL_STAGES[*]}" >&2; return 2 ;;
  esac
}

main() {
  local stages=("$@")
  [[ ${#stages[@]} -eq 0 ]] && stages=("${ALL_STAGES[@]}")

  local failed=()
  for s in "${stages[@]}"; do
    # A failing stage should not abort the rest — report at the end instead.
    run_stage "$s" || failed+=("$s")
  done

  if [[ ${#failed[@]} -gt 0 ]]; then
    warn "stages that reported a problem: ${failed[*]}"
    exit 1
  fi
  log "Done. Open a new shell (or: . ~/.bashrc) to pick up the environment."
}

main "$@"
