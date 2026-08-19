#!/usr/bin/env bash
#
# 40-terminal.sh — terminal + shell environment for the Debian 13 (trixie) arm64 guest.
#
# Sets up:
#   * Konsole: Nerd Font, Catppuccin Mocha scheme, big scrollback, no bell,
#     truecolor advertised, made the DEFAULT profile.
#   * zsh as the login shell (bash kept fully configured as a fallback).
#   * starship prompt, cached init scripts, sane history, modern CLI aliases
#     with graceful fallback, vivid LS_COLORS, completion.
#
# Idempotent: safe to re-run. Run as the normal desktop user (not root).
#
# Usage:  ./40-terminal.sh
#
set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run as your normal user, not root"
command -v sudo >/dev/null || die "sudo required"

APT_OPTS=(-o DPkg::Lock::Timeout=900)
FONT_DIR="$HOME/.local/share/fonts/NerdFonts"
KONSOLE_DIR="$HOME/.local/share/konsole"
SHELL_DIR="$HOME/.config/shell"
CACHE_DIR="$HOME/.cache/shell"
PROFILE_NAME="Terminal"
PROFILE_FILE="$KONSOLE_DIR/${PROFILE_NAME}.profile"
SCHEME_NAME="CatppuccinMocha"
NERD_FAMILY="JetBrainsMono Nerd Font Mono"
FONT_SIZE_PT=12
BEGIN_MARK="# >>> linuxonmac terminal setup >>>"
END_MARK="# <<< linuxonmac terminal setup <<<"

mkdir -p "$FONT_DIR" "$KONSOLE_DIR" "$SHELL_DIR" "$CACHE_DIR"

# ---------------------------------------------------------------- packages ---
log "installing packages"
sudo DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" install -y -q \
  konsole zsh zsh-autosuggestions zsh-syntax-highlighting bash-completion \
  starship bat eza ripgrep fd-find fzf zoxide vivid \
  fonts-noto-color-emoji curl unzip ca-certificates >/dev/null

# -------------------------------------------------------------- nerd font ---
# NB: no `grep -q` in a pipeline here -- it exits early, SIGPIPEs the upstream
# command, and `set -o pipefail` would then report the whole check as failed.
have_font() {
  fc-list : family 2>/dev/null | tr ',' '\n' | sed 's/^ *//; s/ *$//' \
    | grep -ixF "$1" > /dev/null 2>&1
}
if have_font "$NERD_FAMILY"; then
  log "JetBrainsMono Nerd Font already present"
else
  log "downloading JetBrainsMono Nerd Font"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/JetBrainsMono.zip" \
    https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip
  unzip -o -q "$tmp/JetBrainsMono.zip" -d "$tmp/x"
  # Regular/Bold/Italic/BoldItalic of the proportional + strictly-mono variants.
  # The "NL" (no-ligature) cuts are skipped to keep the font picker uncluttered.
  find "$tmp/x" -name 'JetBrainsMonoNerdFont*.ttf' \
    | grep -E 'NerdFont(Mono)?-(Regular|Bold|Italic|BoldItalic)\.ttf$' \
    | while read -r f; do cp -f "$f" "$FONT_DIR/"; done
  fc-cache -f "$FONT_DIR" >/dev/null
fi
have_font "$NERD_FAMILY" || die "fontconfig does not see '$NERD_FAMILY' after install"

# ------------------------------------------------- emoji fallback (fontconfig) -
# Noto Color Emoji is installed but fontconfig otherwise resolves emoji to
# DejaVu Sans' monochrome outlines first. Prefer the colour font so emoji in
# Claude Code / TUI output render properly.
log "preferring Noto Color Emoji for emoji codepoints"
mkdir -p "$HOME/.config/fontconfig/conf.d"
cat > "$HOME/.config/fontconfig/conf.d/75-emoji-fallback.conf" <<'FCEMOJI'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <!-- Emoji fallback. A bare <prefer>Noto Color Emoji</prefer> on a generic
       family makes `fc-match monospace` return the emoji font, so each chain
       names its real primary face FIRST and the colour emoji font second.
       Emoji then resolve to Noto Color Emoji instead of DejaVu Sans'
       monochrome outlines, and the generics still match correctly. -->
  <alias binding="strong">
    <family>monospace</family>
    <prefer>
      <family>JetBrainsMono Nerd Font Mono</family>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>
  <alias binding="strong">
    <family>sans-serif</family>
    <prefer>
      <family>Inter</family>
      <family>Noto Sans</family>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>
  <alias binding="strong">
    <family>serif</family>
    <prefer>
      <family>Noto Serif</family>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>
</fontconfig>
FCEMOJI
fc-cache -f >/dev/null 2>&1 || true

# ------------------------------------------------------- konsole colscheme ---
log "writing Konsole colour scheme ($SCHEME_NAME)"
cat > "$KONSOLE_DIR/${SCHEME_NAME}.colorscheme" <<'SCHEME'
[General]
Description=Catppuccin Mocha
Opacity=1
Wallpaper=
Blur=false
ColorRandomization=false

[Background]
Color=30,30,46
[BackgroundIntense]
Color=24,24,37
[BackgroundFaint]
Color=30,30,46

[Foreground]
Color=205,214,244
[ForegroundIntense]
Color=205,214,244
[ForegroundFaint]
Color=166,173,200

[Color0]
Color=69,71,90
[Color0Intense]
Color=88,91,112
[Color0Faint]
Color=49,50,68

[Color1]
Color=243,139,168
[Color1Intense]
Color=243,139,168
[Color1Faint]
Color=235,160,172

[Color2]
Color=166,227,161
[Color2Intense]
Color=166,227,161
[Color2Faint]
Color=148,226,213

[Color3]
Color=249,226,175
[Color3Intense]
Color=249,226,175
[Color3Faint]
Color=250,179,135

[Color4]
Color=137,180,250
[Color4Intense]
Color=137,180,250
[Color4Faint]
Color=116,199,236

[Color5]
Color=245,194,231
[Color5Intense]
Color=245,194,231
[Color5Faint]
Color=203,166,247

[Color6]
Color=148,226,213
[Color6Intense]
Color=148,226,213
[Color6Faint]
Color=137,220,235

[Color7]
Color=186,194,222
[Color7Intense]
Color=166,173,200
[Color7Faint]
Color=147,153,178
SCHEME

# ---------------------------------------------------------- konsole profile ---
log "writing Konsole profile ($PROFILE_NAME)"
cat > "$PROFILE_FILE" <<PROFILE
[General]
Name=${PROFILE_NAME}
Parent=FALLBACK/
Description=linuxonmac default
DimWhenInactive=false
ShowTerminalSizeHint=false
StartInCurrentSessionDir=true
TerminalCenter=false
TerminalMargin=6
# Konsole does not export COLORTERM on its own; without it Claude Code and
# other TUIs fall back to 256-colour rendering.
Environment=TERM=xterm-256color,COLORTERM=truecolor

[Appearance]
ColorScheme=${SCHEME_NAME}
Font=${NERD_FAMILY},${FONT_SIZE_PT},-1,5,400,0,0,0,0,0,0,0,0,0,0,1
AntiAliasFonts=true
BoldIntense=true
UseFontLineCharacters=false
LineSpacing=0

[Cursor Options]
CursorShape=0
UseCustomCursorColor=true
CustomCursorColor=245,224,220
CustomCursorTextColor=30,30,46

[Scrolling]
HistoryMode=1
HistorySize=200000
ScrollBarPosition=1
ScrollFullPage=0
HighlightScrolledLines=false

[Terminal Features]
BellMode=3
BlinkingCursorEnabled=false
BlinkingTextEnabled=true
FlowControlEnabled=false
UrlHintsModifiers=0
ReverseUrlHints=false
VerticalLine=false

[Interaction Options]
AutoCopySelectedText=false
CopyTextAsHTML=false
TrimLeadingSpacesInSelectedText=true
TrimTrailingSpacesInSelectedText=true
UnderlineFilesEnabled=true
OpenLinksByDirectClickEnabled=false
MiddleClickPasteMode=0
MouseWheelZoomEnabled=true
WordCharacters=:@-./_~?&=%+#
PROFILE

log "making '$PROFILE_NAME' the default Konsole profile"
kwriteconfig6 --file konsolerc --group "Desktop Entry" --key DefaultProfile "${PROFILE_NAME}.profile"
got="$(kreadconfig6 --file konsolerc --group "Desktop Entry" --key DefaultProfile || true)"
[ "$got" = "${PROFILE_NAME}.profile" ] \
  || die "DefaultProfile readback mismatch: got '$got'"

# ----------------------------------------------- generated (probed) values ---
log "generating LS_COLORS + bat theme"
GEN="$SHELL_DIR/generated.sh"
: > "$GEN"
if command -v vivid >/dev/null && vivid generate catppuccin-mocha >/dev/null 2>&1; then
  printf "export LS_COLORS=%q\n" "$(vivid generate catppuccin-mocha)" >> "$GEN"
else
  warn "vivid unavailable; falling back to dircolors defaults"
  dircolors -b | sed -n 's/^LS_COLORS=/export LS_COLORS=/p' >> "$GEN"
fi

# bat errors out on an unknown theme name, so pick one it actually has.
BATBIN="$(command -v batcat || command -v bat || true)"
if [ -n "$BATBIN" ]; then
  themes="$("$BATBIN" --list-themes 2>/dev/null || true)"
  for t in "Catppuccin Mocha" "Coldark-Dark" "Sublime Snazzy" "Monokai Extended" "ansi"; do
    if printf '%s\n' "$themes" | grep -xF "$t" >/dev/null 2>&1; then
      printf 'export BAT_THEME=%q\n' "$t" >> "$GEN"
      log "bat theme: $t"
      break
    fi
  done
fi

# ------------------------------------------------------- shared shell rc -----
log "writing $SHELL_DIR/common.sh"
cat > "$SHELL_DIR/common.sh" <<'COMMON'
# Shared bash/zsh configuration. Managed by scripts/guest/40-terminal.sh.
# Keep this POSIX-compatible: it is sourced by both bash and zsh.

# --- PATH ---------------------------------------------------------------
# Prepend without duplicating, so repeated sourcing stays clean.
__lom_path_prepend() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) [ -d "$1" ] && PATH="$1:$PATH" ;;
  esac
}
__lom_path_prepend "$HOME/.local/bin"
__lom_path_prepend "$HOME/.cargo/bin"
__lom_path_prepend "$HOME/.npm-global/bin"
__lom_path_prepend "$HOME/bin"
export PATH

# --- interop with 10-dev-environment.sh ---------------------------------
# That script hooks ~/.config/devenv/shell.sh into ~/.bashrc and ~/.profile.
# ~/.zprofile pulls ~/.profile in, so zsh already inherits its PATH/env; these
# are a belt-and-braces fallback so node/npm/claude resolve even if that chain
# is broken. Everything here is existence-guarded and safe when absent.
__lom_path_prepend "$HOME/.local/share/fnm"
__lom_path_prepend "$HOME/.local/share/fnm/aliases/default/bin"
__lom_path_prepend "$HOME/.local/share/pnpm"
__lom_path_prepend "$HOME/.local/share/flutter/bin"
__lom_path_prepend "$HOME/.pub-cache/bin"
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh" --no-use
[ -d "$HOME/.pyenv/bin" ] && __lom_path_prepend "$HOME/.pyenv/bin"
export PATH

# ~/.profile prepends ~/.local/bin unconditionally, so it can land in PATH
# twice once devenv and this file have also run. Keep first occurrence, drop
# the rest -- order-preserving and POSIX, so it behaves the same in both shells.
__lom_path_dedupe() {
  __lpd_out=""; __lpd_rest="$PATH"
  while [ -n "$__lpd_rest" ]; do
    __lpd_head="${__lpd_rest%%:*}"
    case "$__lpd_rest" in *:*) __lpd_rest="${__lpd_rest#*:}" ;; *) __lpd_rest="" ;; esac
    [ -z "$__lpd_head" ] && continue
    case ":$__lpd_out:" in *":$__lpd_head:"*) continue ;; esac
    __lpd_out="${__lpd_out:+$__lpd_out:}$__lpd_head"
  done
  PATH="$__lpd_out"; export PATH
  unset __lpd_out __lpd_rest __lpd_head
}
__lom_path_dedupe

# --- environment --------------------------------------------------------
export EDITOR="${EDITOR:-nano}"
export VISUAL="$EDITOR"
export LESS="-R -F -X -i -M"
export LESSHISTFILE="-"
export MANROFFOPT="-c"
# Truecolor: Konsole's profile sets this, but tmux/ssh/screen may drop it.
case "${TERM:-}" in
  xterm-256color|screen-256color|tmux-256color|konsole-256color|alacritty|foot|xterm-kitty)
    : "${COLORTERM:=truecolor}"; export COLORTERM ;;
esac

# --- colours ------------------------------------------------------------
# LS_COLORS + BAT_THEME, resolved at install time by 40-terminal.sh.
[ -f "$HOME/.config/shell/generated.sh" ] && . "$HOME/.config/shell/generated.sh"
export GREP_COLORS='mt=01;31:fn=35:ln=32:se=36'

# --- modern CLI tools, with graceful fallback ---------------------------
# Debian ships bat/fd under alternate names to avoid binary clashes.
if command -v batcat >/dev/null 2>&1; then
  bat() { batcat "$@"; }
  export MANPAGER="sh -c 'col -bx | batcat -l man -p'"
elif command -v bat >/dev/null 2>&1; then
  export MANPAGER="sh -c 'col -bx | bat -l man -p'"
fi
command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1 && fd() { fdfind "$@"; }

if command -v eza >/dev/null 2>&1; then
  alias ls='eza --group-directories-first --icons=auto'
  alias ll='eza -l --group-directories-first --icons=auto --git --time-style=long-iso'
  alias la='eza -la --group-directories-first --icons=auto --git --time-style=long-iso'
  alias lt='eza --tree --level=2 --group-directories-first --icons=auto'
  alias tree='eza --tree --group-directories-first --icons=auto'
else
  alias ls='ls --color=auto --group-directories-first'
  alias ll='ls -lh --color=auto --group-directories-first'
  alias la='ls -lha --color=auto --group-directories-first'
  alias lt='find . -maxdepth 2'
fi

alias grep='grep --color=auto'
alias egrep='grep -E --color=auto'
alias fgrep='grep -F --color=auto'
alias diff='diff --color=auto'
alias ip='ip -color=auto'
alias df='df -h'
alias free='free -h'
alias du='du -h'
alias mkdir='mkdir -p'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias path='echo "$PATH" | tr ":" "\n"'
alias ports='ss -tulpn'
alias reload='exec "$SHELL" -l'

command -v rg  >/dev/null 2>&1 && alias rgh='rg --hidden --glob "!.git"'
command -v git >/dev/null 2>&1 && { alias gs='git status -sb'; alias gd='git diff'; \
  alias gl='git log --oneline --graph --decorate -20'; }
command -v systemctl >/dev/null 2>&1 && alias jctl='journalctl -e -n 200'

# --- small functions ----------------------------------------------------
mkcd() { mkdir -p -- "$1" && cd -- "$1"; }
# Extract almost anything.
ex() {
  [ -f "$1" ] || { echo "ex: '$1' is not a file" >&2; return 1; }
  case "$1" in
    *.tar.bz2|*.tbz2) tar xjf "$1" ;;
    *.tar.gz|*.tgz)   tar xzf "$1" ;;
    *.tar.xz|*.txz)   tar xJf "$1" ;;
    *.tar.zst)        tar --zstd -xf "$1" ;;
    *.tar)            tar xf "$1"  ;;
    *.zip)            unzip "$1"   ;;
    *.gz)             gunzip "$1"  ;;
    *.bz2)            bunzip2 "$1" ;;
    *.7z)             7z x "$1"    ;;
    *) echo "ex: don't know how to extract '$1'" >&2; return 1 ;;
  esac
}

# Cache the output of a slow `<tool> init <shell>` and source the cache.
# Regenerated whenever the tool's binary is newer than the cache.
__lom_cached_init() {
  __lci_cache="$1"; __lci_bin="$2"; shift 2
  if [ ! -s "$__lci_cache" ] || [ "$__lci_bin" -nt "$__lci_cache" ]; then
    "$@" > "$__lci_cache.tmp" 2>/dev/null && mv -f "$__lci_cache.tmp" "$__lci_cache"
  fi
  [ -s "$__lci_cache" ] && . "$__lci_cache"
}
COMMON

# ------------------------------------------------------------- bash rc ------
log "writing $SHELL_DIR/bash.sh"
cat > "$SHELL_DIR/bash.sh" <<'BASHRC'
# bash-specific interactive configuration. Managed by 40-terminal.sh.
case $- in *i*) ;; *) return ;; esac

# --- history ------------------------------------------------------------
HISTFILE="$HOME/.bash_history"
HISTSIZE=100000
HISTFILESIZE=200000
HISTCONTROL=ignoreboth:erasedups   # no dupes, no leading-space commands
HISTTIMEFORMAT='%F %T  '
HISTIGNORE='ls:ll:la:cd:pwd:exit:clear:history'
shopt -s histappend cmdhist lithist
# Append + reload on every prompt so parallel terminals share one history.
PROMPT_COMMAND="history -a; history -n; ${PROMPT_COMMAND:-}"

shopt -s checkwinsize globstar autocd cdspell dirspell no_empty_cmd_completion
bind 'set completion-ignore-case on'
bind 'set completion-map-case on'
bind 'set show-all-if-ambiguous on'
bind 'set colored-stats on'
bind 'set colored-completion-prefix on'
bind 'set mark-symlinked-directories on'
bind 'set bell-style none'
bind '"\e[A": history-search-backward'
bind '"\e[B": history-search-forward'

[ -f /usr/share/bash-completion/bash_completion ] && . /usr/share/bash-completion/bash_completion

command -v starship >/dev/null 2>&1 && \
  __lom_cached_init "$HOME/.cache/shell/starship.bash" "$(command -v starship)" starship init bash --print-full-init
command -v zoxide   >/dev/null 2>&1 && \
  __lom_cached_init "$HOME/.cache/shell/zoxide.bash"   "$(command -v zoxide)"   zoxide init bash
command -v fzf      >/dev/null 2>&1 && \
  __lom_cached_init "$HOME/.cache/shell/fzf.bash"      "$(command -v fzf)"      fzf --bash
BASHRC

# -------------------------------------------------------------- zsh rc ------
log "writing $SHELL_DIR/zsh.sh"
cat > "$SHELL_DIR/zsh.sh" <<'ZSHRC'
# zsh-specific interactive configuration. Managed by 40-terminal.sh.
[[ -o interactive ]] || return

setopt EXTENDED_GLOB INTERACTIVE_COMMENTS NO_BEEP
setopt AUTO_CD AUTO_PUSHD PUSHD_IGNORE_DUPS PUSHD_SILENT
setopt NO_FLOW_CONTROL              # free up ^S / ^Q
setopt LONG_LIST_JOBS NOTIFY

# --- history ------------------------------------------------------------
HISTFILE="$HOME/.local/state/zsh/history"
mkdir -p "${HISTFILE:h}"
HISTSIZE=200000
SAVEHIST=200000
setopt EXTENDED_HISTORY           # timestamps
setopt SHARE_HISTORY              # live-share between running shells
setopt HIST_IGNORE_ALL_DUPS       # drop older duplicates
setopt HIST_SAVE_NO_DUPS
setopt HIST_FIND_NO_DUPS
setopt HIST_IGNORE_SPACE          # " secret" stays out of history
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY                # expand !! but let me confirm

# --- completion ---------------------------------------------------------
ZCOMPDUMP="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump"
mkdir -p "${ZCOMPDUMP:h}"
autoload -Uz compinit
# Full security check at most once a day; otherwise use the cached dump (-C).
if [[ -n ${ZCOMPDUMP}(#qNm+1) ]]; then compinit -d "$ZCOMPDUMP"
else                                    compinit -C -d "$ZCOMPDUMP"; fi

zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' group-name ''
zstyle ':completion:*' verbose true
zstyle ':completion:*:descriptions' format '%F{blue}-- %d --%f'
zstyle ':completion:*:warnings'     format '%F{red}-- no matches --%f'
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path "${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompcache"
zstyle ':completion:*' special-dirs true
zstyle ':completion:*:*:kill:*:processes' list-colors '=(#b) #([0-9]#)*=0=01;31'

# --- keys ---------------------------------------------------------------
bindkey -e                                   # emacs keys; ^R, ^A, ^E all work
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
bindkey '^[[A' up-line-or-beginning-search   # Up   = prefix history search
bindkey '^[[B' down-line-or-beginning-search # Down = prefix history search
bindkey '^[[H' beginning-of-line             # Home
bindkey '^[[F' end-of-line                   # End
bindkey '^[[3~' delete-char                  # Delete
bindkey '^[[1;5C' forward-word               # Ctrl-Right
bindkey '^[[1;5D' backward-word              # Ctrl-Left
bindkey '^H' backward-kill-word              # Ctrl-Backspace
bindkey '^[[Z' reverse-menu-complete         # Shift-Tab
# Stop ^W / word motion from eating whole paths.
WORDCHARS='*?_-.[]~&;!#$%^(){}<>'

# --- plugins ------------------------------------------------------------
if [[ -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]]; then
  ZSH_AUTOSUGGEST_STRATEGY=(history completion)
  ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=#585b70'
  ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=80
  source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
  bindkey '^ ' autosuggest-accept            # Ctrl-Space accepts the ghost text
fi

# ~/.profile (via ~/.zprofile) evaluates `fnm env --shell bash` and
# `direnv hook bash`, whose hooks are PROMPT_COMMAND-based and never fire in
# zsh. Re-install the zsh-native versions so per-directory Node and direnv
# actually work here.
command -v fnm >/dev/null && eval "$(fnm env --use-on-cd --shell zsh)"
command -v direnv >/dev/null && eval "$(direnv hook zsh)"

command -v starship >/dev/null && \
  __lom_cached_init "$HOME/.cache/shell/starship.zsh" "$(command -v starship)" starship init zsh --print-full-init
command -v zoxide   >/dev/null && \
  __lom_cached_init "$HOME/.cache/shell/zoxide.zsh"   "$(command -v zoxide)"   zoxide init zsh
command -v fzf      >/dev/null && \
  __lom_cached_init "$HOME/.cache/shell/fzf.zsh"      "$(command -v fzf)"      fzf --zsh

# Must be sourced last: it wraps every widget defined before it.
[[ -r /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && \
  source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
ZSHRC

# ------------------------------------------------------------- starship -----
log "writing ~/.config/starship.toml"
cat > "$HOME/.config/starship.toml" <<'STARSHIP'
# starship prompt — Catppuccin Mocha, Nerd Font glyphs.
# Two lines: context on top, a bare prompt char to type against underneath.
"$schema" = 'https://starship.rs/config-schema.json'

format = """
$directory$git_branch$git_status$nodejs$python$rust$golang$cmd_duration
$character"""
right_format = "$status$jobs$time"

add_newline = true
command_timeout = 800
scan_timeout = 30

[character]
success_symbol = "[❯](bold #a6e3a1)"
error_symbol   = "[❯](bold #f38ba8)"
vimcmd_symbol  = "[❮](bold #f9e2af)"

[directory]
style = "bold #89b4fa"
truncation_length = 4
truncate_to_repo = true
read_only = " 󰌾"
format = "[$path]($style)[$read_only]($read_only_style) "

[git_branch]
symbol = " "
style = "bold #f5c2e7"
format = "[$symbol$branch]($style) "

[git_status]
style = "#f9e2af"
format = "([$all_status$ahead_behind]($style)) "
conflicted = "="
ahead = "⇡${count}"
behind = "⇣${count}"
diverged = "⇕⇡${ahead_count}⇣${behind_count}"
untracked = "?${count}"
stashed = "$${count}"
modified = "!${count}"
staged = "+${count}"
renamed = "»${count}"
deleted = "✘${count}"

[cmd_duration]
min_time = 2000
style = "#a6adc8"
format = "[󰔟 $duration]($style) "

[status]
disabled = false
style = "bold #f38ba8"
symbol = "✘"
format = "[$symbol$status]($style) "

[jobs]
style = "#f9e2af"
symbol = "󰜎 "

[time]
disabled = false
style = "#585b70"
time_format = "%H:%M"
format = "[$time]($style)"

[nodejs]
symbol = " "
style = "#a6e3a1"
format = "[$symbol($version)]($style) "

[python]
symbol = " "
style = "#f9e2af"
format = "[$symbol($version)(\\($virtualenv\\))]($style) "

[rust]
symbol = " "
style = "#fab387"

[golang]
symbol = " "
style = "#94e2d5"

# Modules that cost time or add noise in this VM.
[package]
disabled = true
[docker_context]
disabled = true
[aws]
disabled = true
[gcloud]
disabled = true
[hostname]
ssh_only = true
style = "#f38ba8"
[username]
show_always = false
STARSHIP

# ------------------------------------------------- hook rc files (idempotent) -
install_block() {
  rcfile="$1"; shell="$2"
  touch "$rcfile"
  # Strip any previous managed block, then append a fresh one.
  if grep -qF "$BEGIN_MARK" "$rcfile"; then
    tmp="$(mktemp)"
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
      index($0,b){skip=1} !skip{print} index($0,e){skip=0}' "$rcfile" > "$tmp"
    cat "$tmp" > "$rcfile"; rm -f "$tmp"
  fi
  {
    printf '%s\n' "$BEGIN_MARK"
    printf '%s\n' '[ -f "$HOME/.config/shell/common.sh" ] && . "$HOME/.config/shell/common.sh"'
    printf '[ -f "$HOME/.config/shell/%s.sh" ] && . "$HOME/.config/shell/%s.sh"\n' "$shell" "$shell"
    printf '%s\n' "$END_MARK"
  } >> "$rcfile"
}

log "hooking ~/.bashrc and ~/.zshrc"
install_block "$HOME/.bashrc" bash
install_block "$HOME/.zshrc"  zsh

# zsh login shells read .zprofile, not .profile. Pull .profile in so PATH and
# anything another installer appends there still applies under zsh. Errors are
# swallowed: a bash-ism dropped into .profile must never break login.
if ! grep -qF "$BEGIN_MARK" "$HOME/.zprofile" 2>/dev/null; then
  {
    printf '%s\n' "$BEGIN_MARK"
    cat <<'ZPROF'
# `emulate sh` plus the bash-targeted evals inside .profile emit harmless
# "can't change option: zle" noise on every login; keep the env, drop the noise.
if [ -f "$HOME/.profile" ]; then
  { emulate sh -c '. "$HOME/.profile"' } 2>/dev/null || true
fi
ZPROF
    printf '%s\n' "$END_MARK"
  } >> "$HOME/.zprofile"
fi

# --------------------------------------------- verify zsh, then switch shell -
log "verifying zsh starts cleanly before touching the login shell"
zsh_out="$(zsh -i -c 'echo ZSH_INTERACTIVE_OK' 2>&1 | tail -1)"
[ "$zsh_out" = "ZSH_INTERACTIVE_OK" ] || die "interactive zsh failed: $zsh_out"
zsh_out="$(zsh -l -i -c 'echo ZSH_LOGIN_OK' 2>&1 | tail -1)"
[ "$zsh_out" = "ZSH_LOGIN_OK" ] || die "login zsh failed: $zsh_out"

want_shell="$(command -v zsh)"
grep -qxF "$want_shell" /etc/shells || echo "$want_shell" | sudo tee -a /etc/shells >/dev/null
cur_shell="$(getent passwd "$USER" | cut -d: -f7)"
if [ "$cur_shell" != "$want_shell" ]; then
  log "changing login shell: $cur_shell -> $want_shell"
  sudo chsh -s "$want_shell" "$USER"
else
  log "login shell already $want_shell"
fi

# Warm the init caches so the first real terminal is fast too.
zsh  -i -c 'true' >/dev/null 2>&1 || true
bash -i -c 'true' >/dev/null 2>&1 || true

log "done. Open a NEW Konsole window (or re-login) for everything to apply."

# Cmd+S and Cmd+Q arrive as Ctrl+S/Ctrl+Q after the keyd remap, which are XON/XOFF
# flow control — the terminal appears to freeze with no indication why. Nothing
# uses software flow control on a local terminal, so turn it off.
if ! grep -q 'stty -ixon' "$HOME/.zshrc" 2>/dev/null; then
    printf '\n# Cmd+S/Cmd+Q become Ctrl+S/Ctrl+Q; without this they freeze the terminal.\n[[ $- == *i* ]] && stty -ixon 2>/dev/null\n' >> "$HOME/.zshrc"
fi
if ! grep -q 'stty -ixon' "$HOME/.bashrc" 2>/dev/null; then
    printf '\n# Cmd+S/Cmd+Q become Ctrl+S/Ctrl+Q; without this they freeze the terminal.\n[[ $- == *i* ]] && stty -ixon 2>/dev/null\n' >> "$HOME/.bashrc"
fi
