#!/usr/bin/env bash
# Launcher, search, notifications and file management.
#
# The desktop parts you touch a hundred times a day: what Ctrl+Space searches,
# what the application menu offers first, what is allowed to interrupt you, and
# what Dolphin does when it opens. Everything here is converged at every login,
# so it is written as "set these keys", never "overwrite this file" -- four other
# scripts share the same config files.
#
# Constraints this script is written against:
#   * No GPU. llvmpipe draws every pixel on the CPU, so anything that runs per
#     keystroke or per frame has to earn its place.
#   * /mnt/mac is the whole macOS home over virtiofs. Anything that walks it
#     (a file indexer, a thumbnailer, a recursive size count) is a trap.
#   * The clipboard is bridged to macOS by a vsock agent driving wl-clipboard.
#     Klipper sits in the same clipboard, so its settings are chosen to stay out
#     of the bridge's way rather than to be clever.
#   * keyd maps Cmd/Meta to Control below the display server, so Meta is not
#     available to applications. Shortcuts are owned by another script; the ones
#     this work needs are listed at the end of the run instead of being bound.
set -euo pipefail

MODE=apply
[ "${1:-}" = "--verify" ] && MODE=verify

B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$B" "$1" "$N"; }
ok()   { printf '  %s+%s %s\n' "$G" "$N" "$1"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$1"; }
note() { printf '    %-46s %s\n' "$1" "$2"; }

FAILS=0
chk() { # chk <label> <actual> <expected>
    if [ "$2" = "$3" ]; then printf '  %s+%s %-44s %s\n' "$G" "$N" "$1" "$2"
    else printf '  %s-%s %-44s %s (want %s)\n' "$R" "$N" "$1" "${2:-<unset>}" "$3"; FAILS=$((FAILS+1)); fi
}

kw() { kwriteconfig6 "$@" 2>/dev/null || true; }
kr() { kreadconfig6 "$@" 2>/dev/null; }

MAC=/mnt/mac
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

# The favourites, in the order a developer reaches for them. Only applications
# that are actually installed -- a favourite that resolves to nothing is worse
# than no favourite, and the Plasma default list ships two of those (Kontact is
# not installed here, Discover is a software centre for a VM whose packages are
# installed by these very scripts).
FAVOURITES="org.kde.konsole.desktop
org.kde.kate.desktop
firefox-esr.desktop
org.kde.dolphin.desktop
org.kde.plasma-systemmonitor.desktop
org.kde.spectacle.desktop
org.kde.ark.desktop
systemsettings.desktop"

# Legacy entries Plasma seeded into the activity database on first run.
FAV_JUNK="preferred://browser
org.kde.kontact.desktop
applications:org.kde.discover.desktop
applications:org.kde.kontact.desktop"

# KRunner plugin ids are the plugin filenames under kf6/krunner minus ".so":
# none of these plugins declare KPlugin/Id, so KPluginMetaData falls back to the
# basename, and RunnerManager reads "<pluginId>Enabled" from [Plugins].
RUNNERS_ON="calculator
krunner_services
krunner_shell
locations
krunner_placesrunner
krunner_recentdocuments
krunner_kwin
krunner_kill
krunner_sessions
krunner_systemsettings
krunner_webshortcuts
helprunner"

RUNNERS_OFF="krunner_appstream
krunner_bookmarksrunner
krunner_plasma-desktop
krunner_powerdevil"

# kded modules with nothing to do on this machine. Each one is a plugin loaded
# into a long-lived daemon, and several of them poll or touch the network.
KDED_OFF="bluedevil
kded_bolt
smart
donationmessage
browserintegrationreminder
browserintegrationflatpakintegrator
smbwatcher
wpad-detector
kwrited
kded_plasma-welcome"

AUTOSTART_OFF="org.kde.discover.notifier.desktop
org.kde.kdeconnect.daemon.desktop
kup-daemon.desktop
konqy_preload.desktop
baloo_file.desktop"

# Notification sources that only ever have bad news about hardware this machine
# does not have, or that exist to advertise something.
NOTIFY_MUTE="donationmessage
discoverabstractnotifier
kupdaemon
bluedevil
kded_bolt
org.kde.kded.smart
powerdevil
kdeconnect
networkmanagement"

if [ "$MODE" = "apply" ]; then

# ---------------------------------------------------------------------------
# 1. KRunner
#
# Ctrl+Space is the single most-used surface on this desktop, and every enabled
# runner is queried on every keystroke. The default set includes four runners
# that either cost real work or answer with things you did not ask for, so the
# useful ones are enabled explicitly and those four are turned off by name.
# ---------------------------------------------------------------------------
step "KRunner"

# FreeFloating puts the box in the middle of the screen instead of welding it to
# the top edge -- the Spotlight shape, which is the reflex being served here.
kw --file krunnerrc --group General --key FreeFloating true
# CompletionSuggestion offers the previous query inline without committing to
# it; ImmediateCompletion would type ahead of you, which is wrong for a box that
# also runs shell commands.
kw --file krunnerrc --group General --key historyBehavior CompletionSuggestion
# Open empty every time. Re-showing the last search means the first keystroke
# lands in the middle of stale text.
kw --file krunnerrc --group General --key RetainPriorSearch false
# Typing on the desktop should not summon a search box; the desktop is a folder
# view here and stray keystrokes belong to it.
kw --file krunnerrc --group General --key ActivateWhenTypingOnDesktop false

for p in $RUNNERS_ON;  do kw --file krunnerrc --group Plugins --key "${p}Enabled" true;  done
for p in $RUNNERS_OFF; do kw --file krunnerrc --group Plugins --key "${p}Enabled" false; done

ok "on:  applications, command line, calculator, locations, places,"
ok "     recent files, windows, kill, sessions, settings, web keywords"
ok "off: appstream (queries the software catalogue for things that are not"
ok "     installed), bookmarks (opens the Firefox sqlite on every keystroke"
ok "     to return stock bookmarks), plasma-desktop (widget/activity actions"
ok "     that duplicate real hits), powerdevil (put 'Suspend' one keystroke"
ok "     away inside a guest whose suspend is the host's job)"

# The calculator runner here is linked against libqalculate, so "=" already does
# units, currency and bases -- "=5 ft in cm", "=100 usd in eur", "=0xff in dec".
# That is why plasma-runners-addons is deliberately not installed: its converter
# would duplicate this while adding five more runners to every keystroke.
if ldd /usr/lib/aarch64-linux-gnu/qt6/plugins/kf6/krunner/calculator.so 2>/dev/null | grep -q qalculate; then
    ok "calculator is qalculate-backed: units, currency and base conversion"
else
    warn "calculator is not qalculate-backed -- '=5 ft in cm' will not work"
fi

# KRunner caches its plugin list at startup and is respawned on demand.
pkill -x krunner 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Web search keywords
#
# "npm:react" in KRunner is faster than a browser tab. Debian already ships
# github/npm/pypi/mdn/docker/rust/qt6/cppreference providers; these are the
# gaps for this particular stack. Keys are checked against the shipped set so
# nothing collides.
# ---------------------------------------------------------------------------
step "Web search keywords"
SP="$HOME/.local/share/kf6/searchproviders"
mkdir -p "$SP"
# The literal \\{@} is desktop-file escaping: KURISearchFilter receives \{@}.
provider() { # provider <file> <name> <keys> <query>
    cat > "$SP/$1.desktop" <<PROV
[Desktop Entry]
Type=Service
Name=$2
Keys=$3
Query=$4
Charset=utf8
PROV
}
provider linuxonmac-pub  "pub.dev"        "pub,flutter" 'https://pub.dev/packages?q=\\{@}'
provider linuxonmac-so   "Stack Overflow" "so"          'https://stackoverflow.com/search?q=\\{@}'
provider linuxonmac-mvn  "Maven Central"  "mvn,maven"   'https://central.sonatype.com/search?q=\\{@}'
provider linuxonmac-dart "Dart API"       "dart"        'https://api.dart.dev/search.html?q=\\{@}'
provider linuxonmac-node "Node.js docs"   "node"        'https://nodejs.org/api/all.html#\\{@}'
provider linuxonmac-next "Next.js docs"   "next"        'https://nextjs.org/docs?q=\\{@}'

kw --file kuriikwsfilterrc --group General --key EnableWebShortcuts true
kw --file kuriikwsfilterrc --group General --key KeywordDelimiter ":"
kw --file kuriikwsfilterrc --group General --key DefaultWebShortcut ddg
kw --file kuriikwsfilterrc --group General --key PreferredWebShortcuts \
   "ddg,gh,npm,pub,py,mdn,so,mvn,dart,node,next,docker,cppreference,rust,qt6"
ok "added pub, so, mvn, dart, node, next; preferred set trimmed to the stack"

# ---------------------------------------------------------------------------
# 3. File indexing stays off
#
# Baloo is currently disabled, and it has to stay that way: /etc/xdg/autostart
# starts baloo_file at every login, and the only interesting files on this
# machine live under /mnt/mac -- the entire macOS home, over virtiofs. Letting
# an indexer walk that would spend hours of a CPU that also has to draw the
# screen. Pinned by config *and* by autostart, and /mnt/mac is excluded so that
# turning indexing back on by hand is survivable.
# ---------------------------------------------------------------------------
step "File indexing"
kw --file baloofilerc --group "Basic Settings" --key "Indexing-Enabled" false
kw --file baloofilerc --group General --key "only basic indexing" true
kw --file baloofilerc --group General --key "exclude folders[\$e]" "$MAC/,$HOME/.cache/,$HOME/node_modules/"
ok "baloo pinned off; $MAC excluded even if it is re-enabled"
ok "use 'fd'/'rg' in a terminal, or KRunner's locations runner, to find files"

# ---------------------------------------------------------------------------
# 4. Application launcher
#
# Kickoff's favourites do not live in the applet's config: they are links in
# kactivitymanagerd's database under the fixed agent
# "org.kde.plasma.favorites.applications". That matters here, because the panel
# is torn down and rebuilt from scratch at every login by 20-desktop-theme.sh,
# so the applet id changes every time and anything keyed to it would be lost.
# The links are not, which is why they are set over D-Bus rather than written
# into plasma-org.kde.plasma.desktop-appletsrc.
# ---------------------------------------------------------------------------
step "Application launcher favourites"
AM_DEST=org.kde.ActivityManager
AM_PATH=/ActivityManager/Resources/Linking
AM_IFACE=org.kde.ActivityManager.ResourcesLinking
FAV_AGENT=org.kde.plasma.favorites.applications

am() { timeout 10 gdbus call --session --dest "$AM_DEST" --object-path "$AM_PATH" \
         --method "$AM_IFACE.$1" "$FAV_AGENT" "$2" ":global" >/dev/null 2>&1; }

if timeout 10 gdbus introspect --session --dest "$AM_DEST" --object-path "$AM_PATH" >/dev/null 2>&1; then
    for j in $FAV_JUNK; do am UnlinkResourceFromActivity "$j" || true; done
    for f in $FAVOURITES; do am LinkResourceToActivity "applications:$f" || true; done
    ok "favourites: konsole, kate, firefox, dolphin, system monitor,"
    ok "            spectacle, ark, system settings"
    ok "dropped Kontact (not installed) and Discover (packages come from apt here)"
else
    warn "kactivitymanagerd is not up yet -- favourites unchanged this run"
fi

# The display order is per-applet-instance, and the instance number churns with
# the panel rebuild. Kickoff falls back to another instance's ordering when its
# own is missing ("No ordering for this applet found, trying others"), so every
# ordering group that exists is refreshed with the same list.
ORDER=$(printf '%s\n' $FAVOURITES | paste -sd,)
STATS="$HOME/.config/kactivitymanagerd-statsrc"
KICKOFF_ID=$(timeout 30 gdbus call --session --dest org.kde.plasmashell \
    --object-path /PlasmaShell --method org.kde.PlasmaShell.evaluateScript --timeout 25 '
var out=[];
for (var i=0;i<panelIds.length;i++){var p=panelById(panelIds[i]);
 for (var j=0;j<p.widgetIds.length;j++){var w=p.widgetById(p.widgetIds[j]);
   if (w.type=="org.kde.plasma.kickoff") out.push(w.id);}}
print(out.join(","));' 2>/dev/null | tr -dc '0-9,' | cut -d, -f1)

# Ordering is cosmetic; never let it take the rest of the script (or the login)
# down with it, so the whole block runs detached from set -e.
set +e
GROUPS=""
[ -f "$STATS" ] && GROUPS=$(grep -oE '^\[Favorites-[^]]+\]' "$STATS" | tr -d '[]')
if [ -n "${KICKOFF_ID:-}" ]; then
    ACT=$(timeout 10 gdbus call --session --dest "$AM_DEST" --object-path /ActivityManager/Activities \
            --method org.kde.ActivityManager.Activities.CurrentActivity 2>/dev/null)
    ACT=$(printf '%s' "$ACT" | tr -dc 'a-f0-9-')
    GROUPS="$GROUPS
Favorites-org.kde.plasma.kickoff.favorites.instance-${KICKOFF_ID}-global"
    [ -n "$ACT" ] && GROUPS="$GROUPS
Favorites-org.kde.plasma.kickoff.favorites.instance-${KICKOFF_ID}-${ACT}"
fi
for g in $GROUPS; do kw --file kactivitymanagerd-statsrc --group "$g" --key ordering "$ORDER"; done
set -e
ok "ordering written for kickoff instance ${KICKOFF_ID:-?} and every stale group"

# Applet-level settings still have to be pushed through plasmashell, because the
# shell holds appletsrc open and rewrites it from memory. This runs after
# 20-desktop-theme.sh has rebuilt the panel, so the widget it finds is the live
# one. Guarded the same way that script guards its own rebuild: if the shell is
# not answering, skip rather than half-apply.
if timeout 20 gdbus call --session --dest org.kde.plasmashell --object-path /PlasmaShell \
     --method org.kde.PlasmaShell.evaluateScript --timeout 15 'print("ok")' >/dev/null 2>&1; then
  KICK_OUT=$(timeout 60 gdbus call --session --dest org.kde.plasmashell --object-path /PlasmaShell \
    --method org.kde.PlasmaShell.evaluateScript --timeout 50 "
var done=0;
for (var i=0;i<panelIds.length;i++){var p=panelById(panelIds[i]);
 for (var j=0;j<p.widgetIds.length;j++){var w=p.widgetById(p.widgetIds[j]);
  if (w.type=='org.kde.plasma.kickoff'){
    w.currentConfigGroup=['General'];
    w.writeConfig('favorites', '$(printf '%s\n' $FAVOURITES | paste -sd,)');
    // Suspend and Hibernate inside the guest fight the host's own suspend and
    // have wedged this VM before. Lock and log out are the useful two.
    w.writeConfig('systemFavorites', 'lock-screen,logout,reboot,shutdown');
    // Lists rather than grids: fewer QML delegates to rasterise, and the
    // application names stay readable.
    w.writeConfig('favoritesDisplay', 1);
    w.writeConfig('applicationsDisplay', 1);
    w.writeConfig('alphaSort', false);           // keep the category order
    w.writeConfig('showActionButtonCaptions', false);
    done++;
  }}}
print('kickoff-configured='+done);" 2>&1 | tr -dc 'a-z0-9=-')
  ok "applet config pushed (${KICK_OUT:-none})"
else
  warn "plasmashell is not answering -- kickoff applet settings skipped this run"
fi

# ---------------------------------------------------------------------------
# 5. Notifications
#
# 71-visual-polish.sh owns placement and timeout (top right, 5 s) and verifies
# them, so those keys are left alone. What is left is the part that actually
# stops the interruptions: the behaviour of do-not-disturb, and silencing the
# sources that only ever report on hardware this machine does not have.
# ---------------------------------------------------------------------------
step "Notifications"
kw --file plasmanotifyrc --group Notifications --key NormalAlwaysOnTop false
# Critical notifications ignore do-not-disturb. That is the whole reason DND is
# safe to turn on: nothing that matters gets swallowed.
kw --file plasmanotifyrc --group Notifications --key CriticalPopupsInDoNotDisturbMode true
# File operations belong in the task manager, not as a popup per copy.
kw --file plasmanotifyrc --group Jobs --key PermanentPopups false
kw --file plasmanotifyrc --group Jobs --key InTaskManager true
kw --file plasmanotifyrc --group Jobs --key InNotifications true
# This guest has one virtual output. Plasma's "mirrored screens" heuristic can
# read that as a presentation and silently enter DND; screen *sharing* is a real
# signal and is kept.
kw --file plasmanotifyrc --group DoNotDisturb --key WhenScreensMirrored false
kw --file plasmanotifyrc --group DoNotDisturb --key WhenScreenSharing true
kw --file plasmanotifyrc --group DoNotDisturb --key NotificationSoundsMuted true

for s in $NOTIFY_MUTE; do
    kw --file plasmanotifyrc --group Services --group "$s" --key ShowPopups false
    kw --file plasmanotifyrc --group Services --group "$s" --key Seen true
done
# The KDE fundraiser popup and the update nagger have no history value either.
for s in donationmessage discoverabstractnotifier; do
    kw --file plasmanotifyrc --group Services --group "$s" --key ShowInHistory false
done
for a in org.kde.discover.notifier org.kde.discover; do
    kw --file plasmanotifyrc --group Applications --group "$a" --key ShowPopups false
    kw --file plasmanotifyrc --group Applications --group "$a" --key Seen true
done
ok "DND off by default, sounds muted when it is on, criticals always through"
ok "popups silenced: updates, donations, backup, bluetooth, thunderbolt,"
ok "                 S.M.A.R.T., battery, kdeconnect, network state changes"
ok "kept loud: out-of-memory, low disk space, kwin, konsole, spectacle"

# ---------------------------------------------------------------------------
# 6. Dolphin
# ---------------------------------------------------------------------------
step "Dolphin"
dol() { kw --file dolphinrc --group General --key "$1" "$2"; }
# A path you can type and select is worth more than a breadcrumb when the paths
# you care about are /mnt/mac/Developer/something and ~/.config/something.
dol EditableUrl true
dol ShowFullPath true
dol ShowFullPathInTitlebar true
# Split view by default: half the file work on this machine is moving things
# between the guest and /mnt/mac, and Tab switches panes.
dol SplitView true
dol UseTabForSwitchingSplitView true
# Reopening yesterday's tabs means stat'ing several virtiofs paths before the
# window draws. Starting at home is instant.
dol RememberOpenedTabs false
dol OpenNewTabAfterLastTab true
dol OpenExternallyCalledFolderInNewTab true
# One set of view settings everywhere rather than per-directory surprises.
dol GlobalViewProps true
# Step into .zip/.tar.gz like folders -- node_modules tarballs, release archives.
dol BrowseThroughArchives true
# The hover selection markers repaint on every mouse move, which on llvmpipe is
# real CPU, and they get in the way of drag and drop.
dol ShowSelectionToggle false
dol ShowPasteBarAfterCopying false
dol ShowToolTips false
dol AutoExpandFolders false
dol ShowZoomSlider false
dol ConfirmClosingMultipleTabs false
# Closing a tab with something still running in its terminal panel stays a
# question worth asking.
dol ConfirmClosingTerminalRunningProgram true
# Counting entries, not summing bytes: a recursive size of a /mnt/mac folder
# would walk the macOS home over virtiofs to render one column.
kw --file dolphinrc --group ContentDisplay --key DirectorySizeMode ContentCount
kw --file dolphinrc --group ContentDisplay --key UseShortRelativeDates true
ok "editable path, split view, Tab between panes, archives browsable"
ok "no hover selection markers, no recursive directory sizes"

# Places. /mnt/mac itself is added by 10-dev-environment.sh, so this is strictly
# additive: anything already present, whoever put it there, is left alone.
python3 - "$HOME/.local/share/user-places.xbel" "$MAC" <<'PY' && ok "places sidebar updated" || warn "places sidebar unchanged"
import os, sys, time
path, mac = sys.argv[1], sys.argv[2]
if not os.path.isfile(path):
    sys.exit(1)
src = open(path, encoding="utf-8").read()
if "</xbel>" not in src:
    sys.exit(1)
wanted = [(mac + "/Developer", "Mac Developer", "folder-development"),
          (mac + "/Desktop",   "Mac Desktop",   "user-desktop"),
          (mac + "/Downloads", "Mac Downloads", "folder-download"),
          ("/",                "Root",          "folder-root")]
added, stamp, n = [], int(time.time()), 0
for p, title, icon in wanted:
    href = "file://" + p
    if not os.path.isdir(p) or ('href="%s"' % href) in src:
        continue
    n += 1
    added.append(
        ' <bookmark href="%s">\n  <title>%s</title>\n  <info>\n'
        '   <metadata owner="http://freedesktop.org"><bookmark:icon name="%s"/></metadata>\n'
        '   <metadata owner="http://www.kde.org"><ID>%d/%d</ID></metadata>\n'
        '  </info>\n </bookmark>\n' % (href, title, icon, stamp, n))
if added:
    open(path, "w", encoding="utf-8").write(src.replace("</xbel>", "".join(added) + "</xbel>", 1))
print("  added %d place(s)" % len(added))
PY

# Terminal panel. Panel visibility is a QMainWindow state blob in
# ~/.local/state/dolphinstaterc, not a config key, so it is set once by driving
# Dolphin's own action over D-Bus and then left to the user -- converge forcing
# it back every login would mean you could never close it. The marker below is
# what makes it once rather than every time.
if [ "$(kr --file dolphinrc --group LinuxOnMac --key TerminalPanel)" != "done" ]; then
  if ! pgrep -x dolphin >/dev/null 2>&1; then
    SEEN=$(python3 - <<'PY'
import base64, configparser, os
p = os.path.expanduser("~/.local/state/dolphinstaterc")
cp = configparser.RawConfigParser(strict=False); cp.optionxform = str
try: cp.read(p)
except Exception: pass
s = cp.get("State", "State", fallback="")
if s:
    b = base64.b64decode(s); u = "terminalDock".encode("utf-16-be"); i = b.find(u)
    print("on" if i >= 0 and b[i + len(u)] & 1 else "off")
else:
    print("none")
PY
)
    if [ "$SEEN" != "on" ]; then
      nice -n 19 dolphin "$HOME" >/dev/null 2>&1 &
      DBN=""
      for _ in $(seq 1 25); do
        sleep 1
        DBN=$(timeout 5 gdbus call --session --dest org.freedesktop.DBus \
                --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.ListNames 2>/dev/null \
              | tr ',' '\n' | grep -o 'org.kde.dolphin-[0-9]*' | head -1) || true
        [ -n "$DBN" ] && break
      done
      if [ -n "$DBN" ]; then
        timeout 10 gdbus call --session --dest "$DBN" --object-path /dolphin/Dolphin_1 \
          --method org.kde.KMainWindow.activateAction show_terminal_panel >/dev/null 2>&1 || true
        sleep 2
        timeout 10 gdbus call --session --dest "$DBN" --object-path /dolphin/Dolphin_1 \
          --method org.kde.dolphin.MainWindow.quit >/dev/null 2>&1 || true
        sleep 2
        ok "terminal panel enabled once (View > Panels to change it, and it stays changed)"
      else
        warn "could not reach Dolphin over D-Bus -- terminal panel not set"
      fi
    else
      ok "terminal panel already on"
    fi
    kw --file dolphinrc --group LinuxOnMac --key TerminalPanel done
  else
    warn "Dolphin is running -- terminal panel bootstrap deferred to the next login"
  fi
fi

# Hidden files and thumbnails are the one thing here that cannot be set from a
# script: Dolphin 25.04 deletes ~/.local/share/dolphin/view_properties/global/
# .directory at startup ("cleaning .directory" in its own debug log) and writes
# no replacement, so global view properties only exist in the running process.
# Ctrl+. toggles hidden files and it sticks for the session.
warn "hidden files / previews: not settable from config in Dolphin 25.04 -- use Ctrl+."

# ---------------------------------------------------------------------------
# 7. File types
#
# shared-mime-info gets two of this stack's file types actively wrong: .ts is
# claimed by Qt Linguist translation sources (and MPEG transport streams), and
# .tsx by the Tiled map editor's tilesets. A TypeScript file that opens in
# neither of those is the bar being cleared here. Higher glob weights win, and
# the types are declared as subclasses of text/plain so anything that handles
# text handles them.
# ---------------------------------------------------------------------------
step "File types and default applications"
# The package has to go in the system mime directory, not ~/.local/share/mime:
# xdgmime resolves a filename glob against the first cache that matches it, so a
# user-level "*.ts" at weight 80 never gets compared against the system's
# weight-50 one -- it is simply never reached. Same directory, same comparison.
MIMEDIR=/usr/share/mime
MIMESRC=$(mktemp)
cat > "$MIMESRC" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="text/typescript">
    <comment>TypeScript source</comment>
    <sub-class-of type="text/plain"/>
    <glob pattern="*.ts" weight="80"/>
    <glob pattern="*.mts" weight="80"/>
    <glob pattern="*.cts" weight="80"/>
  </mime-type>
  <mime-type type="text/tsx">
    <comment>TypeScript JSX source</comment>
    <sub-class-of type="text/plain"/>
    <glob pattern="*.tsx" weight="80"/>
  </mime-type>
  <mime-type type="text/jsx">
    <comment>JavaScript JSX source</comment>
    <sub-class-of type="text/plain"/>
    <glob pattern="*.jsx" weight="80"/>
  </mime-type>
  <mime-type type="text/javascript">
    <glob pattern="*.cjs" weight="60"/>
  </mime-type>
  <mime-type type="text/x-vue">
    <comment>Vue single-file component</comment>
    <sub-class-of type="text/plain"/>
    <glob pattern="*.vue" weight="60"/>
  </mime-type>
  <mime-type type="text/x-svelte">
    <comment>Svelte component</comment>
    <sub-class-of type="text/plain"/>
    <glob pattern="*.svelte" weight="60"/>
  </mime-type>
  <mime-type type="text/x-dotenv">
    <comment>Environment file</comment>
    <sub-class-of type="text/plain"/>
    <glob pattern=".env" weight="60"/>
    <glob pattern=".env.*" weight="60"/>
  </mime-type>
  <mime-type type="text/x-dockerfile">
    <comment>Dockerfile</comment>
    <sub-class-of type="text/plain"/>
    <glob pattern="Dockerfile" weight="60"/>
    <glob pattern="Dockerfile.*" weight="60"/>
    <glob pattern="*.Dockerfile" weight="60"/>
  </mime-type>
</mime-info>
XML
# update-mime-database is a few seconds of CPU; only pay it when the source
# actually changed.
rm -rf "$HOME/.local/share/mime/packages/linuxonmac-dev.xml"
if ! cmp -s "$MIMESRC" "$MIMEDIR/packages/linuxonmac-dev.xml" 2>/dev/null; then
    sudo install -m 0644 "$MIMESRC" "$MIMEDIR/packages/linuxonmac-dev.xml"
    sudo nice -n 19 update-mime-database "$MIMEDIR" >/dev/null 2>&1 || true
    ok "mime database rebuilt (.ts and .tsx reclaimed from Qt Linguist and Tiled)"
else
    ok "mime database already current"
fi
rm -f "$MIMESRC"

EDITOR_DESKTOP=org.kde.kate.desktop
BROWSER_DESKTOP=firefox-esr.desktop
CODE_TYPES="text/plain text/typescript text/tsx text/jsx text/javascript
text/x-vue text/x-svelte text/x-dotenv text/x-dockerfile
text/x-csrc text/x-chdr text/x-c++src text/x-c++hdr text/x-java text/x-python
text/x-go text/x-kotlin text/x-gradle text/x-makefile text/x-scss text/css
text/markdown text/rust application/json application/yaml application/toml
application/sql application/xml application/xslt+xml application/x-shellscript
application/vnd.dart application/x-perl application/x-ruby application/x-php"

for t in $CODE_TYPES; do
    kw --file mimeapps.list --group "Default Applications" --key "$t" "$EDITOR_DESKTOP"
    kw --file mimeapps.list --group "Added Associations" --key "$t" "$EDITOR_DESKTOP;org.kde.kwrite.desktop;"
done
# Double-clicking a shell script should open it, not run it.
kw --file mimeapps.list --group "Default Applications" --key "application/x-shellscript" "$EDITOR_DESKTOP"
kw --file mimeapps.list --group "Default Applications" --key "inode/directory" "org.kde.dolphin.desktop"
# No image viewer or PDF reader is installed, and installing one would cost a
# software renderer more than it is worth. Firefox already does both well.
for t in text/html application/xhtml+xml application/pdf image/png image/jpeg \
         image/gif image/webp image/svg+xml; do
    kw --file mimeapps.list --group "Default Applications" --key "$t" "$BROWSER_DESKTOP"
done
for t in application/zip application/gzip application/x-tar \
         application/x-compressed-tar application/x-7z-compressed; do
    kw --file mimeapps.list --group "Default Applications" --key "$t" "org.kde.ark.desktop"
done
for s in http https; do
    kw --file mimeapps.list --group "Default Applications" --key "x-scheme-handler/$s" "$BROWSER_DESKTOP"
done
nice -n 19 update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
ok "code -> Kate, folders -> Dolphin, archives -> Ark, web/pdf/images -> Firefox"

# ---------------------------------------------------------------------------
# 8. Klipper
#
# The clipboard is shared with macOS by a vsock agent driving wl-clipboard, and
# Klipper is sitting in the same selection. Every setting here is chosen to keep
# Klipper a passive history rather than an active participant.
# ---------------------------------------------------------------------------
step "Klipper"
klip() { kw --file klipperrc --group General --key "$1" "$2"; }
# History is stored in a sqlite file, so depth is cheap.
klip MaxClipItems 100
klip KeepClipboardContents true
# StripWhiteSpace defaults to true, which trims copied text. Copy an indented
# block of code in the guest and paste it on the Mac and the indentation would
# be gone -- the bridge would be blamed for something Klipper did.
klip StripWhiteSpace false
# Do not touch the primary (mouse-highlight) selection, and never sync it to the
# clipboard: every drag over a word would otherwise be pushed to macOS.
klip IgnoreSelection true
klip SyncClipboards false
klip SelectionTextOnly true
# Images through the bridge are expensive on both ends and rarely wanted.
klip IgnoreImages true
# The URL "actions" popup is the one Klipper feature that opens a menu on top of
# whatever you are doing whenever you copy something that looks like a URL.
klip URLGrabberEnabled false
klip EnableMagicMimeActions false
klip ReplayActionInHistory false
klip TimeoutForActionPopups 0
ok "100 items, no whitespace trimming, no primary-selection tracking,"
ok "no actions popup -- nothing that writes to the clipboard on its own"

# ---------------------------------------------------------------------------
# 9. Things this machine does not have
#
# Every entry below is a daemon or plugin that exists to manage hardware
# Virtualization.framework does not expose, or to advertise something. None of
# them are removed as packages -- apt would drag half of plasma-desktop with
# them -- they are just not started.
# ---------------------------------------------------------------------------
step "Removing what this VM has no hardware for"
for m in $KDED_OFF; do kw --file kded6rc --group "Module-$m" --key autoload false; done
note "bluedevil"          "no Bluetooth controller is exposed to the guest"
note "kded_bolt"          "no Thunderbolt"
note "smart"              "virtio-blk reports no S.M.A.R.T. data"
note "donationmessage"    "KDE fundraiser popup"
note "browserintegration" "nags to install a browser extension; no flatpaks here"
note "smbwatcher"         "the Mac share is virtiofs, not SMB -- this scans the LAN"
note "wpad-detector"      "proxy autodiscovery; DNS/DHCP lookups for nothing"
note "kwrited"            "delivers wall(1) messages; single-user desktop"
note "kded_plasma-welcome" "first-run tour"

AUTODIR="$HOME/.config/autostart"
mkdir -p "$AUTODIR"
for d in $AUTOSTART_OFF; do
    [ -f "/etc/xdg/autostart/$d" ] || continue
    printf '[Desktop Entry]\nType=Application\nName=%s\nHidden=true\n' "${d%.desktop}" > "$AUTODIR/$d"
done
note "discover.notifier"  "polls for package updates; apt is driven from a terminal"
note "kdeconnect.daemon"  "pairs with phones on the LAN; the guest is behind NAT"
note "kup-daemon"         "backups of a disposable guest whose data lives on the Mac"
note "konqy_preload"      "preloads Konqueror into RAM at every login"
note "baloo_file"         "see the file indexing section"

# Left alone deliberately: powerdevil (it still owns screen blanking and DPMS),
# plasmavault (cryfs is installed, so vaults actually work), freespacenotifier
# and oom-notifier (a small VM disk and a small VM RAM are worth warning about),
# device_automounter and soliduiserver (a disk image can still be attached),
# appmenu (20-desktop-theme.sh has its own analysis of that module).
if [ "$(systemctl is-enabled bluetooth 2>/dev/null)" = "enabled" ]; then
    sudo systemctl disable bluetooth >/dev/null 2>&1 \
      && ok "bluetooth.service disabled (it was enabled and idle)" \
      || warn "could not disable bluetooth.service"
fi
command -v cupsd >/dev/null 2>&1 \
    && warn "cups is installed -- nothing to print to from a VM" \
    || ok "no print stack installed; nothing to remove"
# No feedback level means no periodic telemetry POST from Plasma applications.
kw --file PlasmaUserFeedback --group Global --key FeedbackLevel 0
ok "Plasma telemetry off"

step "Shortcuts this needs from the shortcuts agent (kglobalshortcutsrc)"
warn "keyd maps Cmd to Control, so every Meta+ default below is unreachable:"
note "klipper show-on-mouse-pos"  "default Meta+V   -> suggest Ctrl+Alt+V"
note "plasmashell 'Show Notifications'" "default Meta+N -> suggest Ctrl+Alt+N"
note "kwin/plasma 'Open File Manager'"  "default Meta+E -> suggest Ctrl+Alt+E"
note "Ctrl+Space (KRunner)" "already bound by 50-mac-keyboard.sh -- no change needed"

printf '\n%sApplied. Re-login needed for: kded modules, autostart, Klipper.%s\n' "$B" "$N"
printf '%sLive now: KRunner, favourites, notifications, Dolphin, file types.%s\n' "$B" "$N"

fi  # apply

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
if [ "$MODE" = "verify" ]; then
step "KRunner"
chk "FreeFloating"        "$(kr --file krunnerrc --group General --key FreeFloating)" "true"
chk "RetainPriorSearch"   "$(kr --file krunnerrc --group General --key RetainPriorSearch)" "false"
chk "historyBehavior"     "$(kr --file krunnerrc --group General --key historyBehavior)" "CompletionSuggestion"
for p in $RUNNERS_ON;  do chk "runner $p" "$(kr --file krunnerrc --group Plugins --key "${p}Enabled")" "true";  done
for p in $RUNNERS_OFF; do chk "runner $p" "$(kr --file krunnerrc --group Plugins --key "${p}Enabled")" "false"; done

step "Launcher favourites"
AM_OK=0
for f in $FAVOURITES; do
    r=$(timeout 10 gdbus call --session --dest org.kde.ActivityManager \
          --object-path /ActivityManager/Resources/Linking \
          --method org.kde.ActivityManager.ResourcesLinking.IsResourceLinkedToActivity \
          org.kde.plasma.favorites.applications "applications:$f" ":global" 2>/dev/null | tr -dc 'a-z')
    chk "favourite $f" "${r:-unknown}" "true"; AM_OK=1
done
[ "$AM_OK" = 1 ] || warn "kactivitymanagerd unreachable"
chk "kontact unlinked" "$(timeout 10 gdbus call --session --dest org.kde.ActivityManager \
      --object-path /ActivityManager/Resources/Linking \
      --method org.kde.ActivityManager.ResourcesLinking.IsResourceLinkedToActivity \
      org.kde.plasma.favorites.applications org.kde.kontact.desktop ':global' 2>/dev/null | tr -dc 'a-z')" "false"

step "Notifications"
chk "CriticalPopupsInDND" "$(kr --file plasmanotifyrc --group Notifications --key CriticalPopupsInDoNotDisturbMode)" "true"
chk "DND WhenScreensMirrored" "$(kr --file plasmanotifyrc --group DoNotDisturb --key WhenScreensMirrored)" "false"
chk "DND sounds muted"    "$(kr --file plasmanotifyrc --group DoNotDisturb --key NotificationSoundsMuted)" "true"
for s in donationmessage discoverabstractnotifier bluedevil powerdevil; do
    chk "muted $s" "$(kr --file plasmanotifyrc --group Services --group "$s" --key ShowPopups)" "false"
done

step "Dolphin"
for kv in "EditableUrl true" "ShowFullPath true" "SplitView true" \
          "UseTabForSwitchingSplitView true" "BrowseThroughArchives true" \
          "ShowSelectionToggle false" "GlobalViewProps true" "RememberOpenedTabs false"; do
    chk "dolphinrc ${kv%% *}" "$(kr --file dolphinrc --group General --key "${kv%% *}")" "${kv##* }"
done
chk "DirectorySizeMode" "$(kr --file dolphinrc --group ContentDisplay --key DirectorySizeMode)" "ContentCount"
for p in "$MAC/Developer" "$MAC/Downloads"; do
    if [ -d "$p" ]; then
        grep -qF "file://$p" "$HOME/.local/share/user-places.xbel" 2>/dev/null \
            && ok "place $p" || { printf '  %s-%s place %s missing\n' "$R" "$N" "$p"; FAILS=$((FAILS+1)); }
    fi
done
TP=$(python3 - <<'PY'
import base64, configparser, os
p = os.path.expanduser("~/.local/state/dolphinstaterc")
cp = configparser.RawConfigParser(strict=False); cp.optionxform = str
try: cp.read(p)
except Exception: pass
s = cp.get("State", "State", fallback="")
if s:
    b = base64.b64decode(s); u = "terminalDock".encode("utf-16-be"); i = b.find(u)
    print("on" if i >= 0 and b[i + len(u)] & 1 else "off")
else:
    print("none")
PY
)
chk "dolphin terminal panel" "$TP" "on"

step "File types"
cd /tmp
for e in ts tsx jsx dart py java c go rs json yaml toml md sh; do echo "x" > "lm-verify.$e"; done
for e in ts tsx jsx dart py java c go rs json yaml toml md sh; do
    T=$(xdg-mime query filetype "lm-verify.$e" 2>/dev/null)
    A=$(xdg-mime query default "$T" 2>/dev/null)
    printf '    %-6s %-28s %s\n' ".$e" "$T" "${A:-<none>}"
    [ -n "$A" ] || FAILS=$((FAILS+1))
done
rm -f /tmp/lm-verify.*
printf 'const x: number = 1;\n' > /tmp/lm-verify.ts
printf 'export const A = () => <div/>;\n' > /tmp/lm-verify.tsx
chk ".ts not Qt Linguist"  "$(xdg-mime query filetype /tmp/lm-verify.ts)"  "text/typescript"
chk ".tsx not Tiled"       "$(xdg-mime query filetype /tmp/lm-verify.tsx)" "text/tsx"
rm -f /tmp/lm-verify.ts /tmp/lm-verify.tsx

step "Klipper"
for kv in "MaxClipItems 100" "StripWhiteSpace false" "IgnoreSelection true" \
          "SyncClipboards false" "URLGrabberEnabled false" "IgnoreImages true"; do
    chk "klipperrc ${kv%% *}" "$(kr --file klipperrc --group General --key "${kv%% *}")" "${kv##* }"
done
if command -v wl-copy >/dev/null 2>&1 && command -v wl-paste >/dev/null 2>&1; then
    MARK="linuxonmac-clip-$$-$(date +%s)"
    printf '%s' "$MARK" | wl-copy 2>/dev/null || true
    sleep 1
    chk "clipboard round trip" "$(wl-paste -n 2>/dev/null)" "$MARK"
fi

step "Indexing and cruft"
chk "baloo indexing" "$(kr --file baloofilerc --group 'Basic Settings' --key Indexing-Enabled)" "false"
for m in bluedevil smart donationmessage wpad-detector; do
    chk "kded $m" "$(kr --file kded6rc --group "Module-$m" --key autoload)" "false"
done
for d in $AUTOSTART_OFF; do
    [ -f "/etc/xdg/autostart/$d" ] || continue
    chk "autostart $d" "$(kr --file "autostart/$d" --group 'Desktop Entry' --key Hidden)" "true"
done
BT=$(systemctl is-enabled bluetooth 2>/dev/null || true)
case "$BT" in disabled|masked|not-found) BT=off ;; esac
chk "bluetooth.service" "$BT" "off"

printf '\n'
if [ "$FAILS" -eq 0 ]; then printf '%s%sALL CHECKS PASSED%s\n' "$B" "$G" "$N"
else printf '%s%s%d CHECK(S) FAILED%s\n' "$B" "$R" "$FAILS" "$N"; exit 1; fi
fi
