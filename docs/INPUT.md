# Input

How the keyboard behaves in the guest, and why.

## The model

`scripts/guest/50-mac-keyboard.sh` made the Command key emit Control at the
evdev layer, below the display server, so that Cmd+C/V/A work in Firefox, VS
Code and every GTK app — places KDE's own shortcut system cannot reach. The
cost was that **Meta stopped existing**: Plasma's defaults live on Meta (Meta
alone, Meta+Space, Meta+arrows, Meta+D, Meta+PgDown) and all of them became
unreachable at once.

`scripts/guest/73-shortcuts.sh` resolves that with one observation: keyd can
still *emit* Meta even though no physical key produces it any more. Meta
therefore becomes a private namespace that only keyd can reach, and the layer
splits cleanly in three:

| You press | keyd emits | Who consumes it |
|---|---|---|
| `Cmd`+*most keys* | `Ctrl`+key | the focused application |
| `Cmd`+*a few keys* | `Meta`+key | the compositor, as a global shortcut |
| `Ctrl`+key | `Ctrl`+key | unchanged — **Ctrl+C still sends SIGINT** |

Putting every global shortcut on Meta is the point. A global shortcut is grabbed
by the compositor and never reaches the focused window, so a compositor action
sitting on `Ctrl+Tab` or `Ctrl+Space` would silently eat that key from every
application. Nothing can type Meta, so nothing collides.

`73-shortcuts.sh` owns `/etc/keyd/default.conf`. `50-mac-keyboard.sh` rewrites
that file at every login and runs first, so 73 rewrites it afterwards with a
strict superset of the same behaviour.

## Bindings

### Editing and navigation — handled by keyd, live immediately

| Key | Effect |
|---|---|
| `Cmd+C` / `Cmd+V` | copy / paste — **including in the terminal** (see below) |
| `Cmd+Shift+C` / `Cmd+Shift+V` | `Ctrl+Shift+C/V` — Konsole copy/paste, paste-as-plain-text |
| `Cmd+A` `Cmd+Z` `Cmd+X` `Cmd+S` `Cmd+F` `Cmd+N` `Cmd+T` `Cmd+W` `Cmd+Q` `Cmd+1…9` | the `Ctrl+` equivalent, i.e. what the application already binds |
| `Cmd+←` / `Cmd+→` | start / end of line |
| `Cmd+↑` / `Cmd+↓` | start / end of document |
| `Cmd+[` / `Cmd+]` | back / forward |
| `Ctrl+←` / `Ctrl+→` | previous / next word (unchanged Linux behaviour) |
| `Option+←` / `Option+→` | back / forward (unchanged; not remapped, so `Alt+`-chords stay free) |

### Windows and desktop — needs a re-login (see below)

| Key | Effect |
|---|---|
| `Cmd+Space` | KRunner / Spotlight |
| `Cmd+Tab` / `Cmd+Shift+Tab` | switch windows — hold Cmd, tap Tab, release to commit |
| ``Cmd+` `` | cycle windows of the current application |
| `Cmd+M`, `Cmd+H` | minimise |
| `Cmd+Shift+M` | maximise |
| `Ctrl+↑` | Overview (Mission Control) |
| `Ctrl+↓` | windows of the current application (App Exposé) |
| `Ctrl+Shift+↑` | Grid View, all desktops |
| `Ctrl+Cmd+F` | fullscreen |
| `Ctrl+Cmd+Q` | lock the screen |
| `Ctrl+Cmd+Space` | emoji picker |
| `Ctrl+Cmd+←` / `→` | previous / next virtual desktop |
| `Cmd+Option+Esc` | force-quit the window under the cursor |
| `Ctrl+Option+←↑→↓` | tile the window left / top / right / bottom |
| `Ctrl+Option+D` | show desktop |
| `Ctrl+Option+V` | clipboard history |
| `Ctrl+Option+Space` | application launcher |
| `Ctrl+Option+Del` | log out |
| `Cmd+Shift+3` / `4` / `5` | screenshot: whole screen / region / Spectacle |
| `Cmd+Shift+6` | screenshot the active window |
| `Ctrl+Option+T` | new Konsole |

`Ctrl+Space`, `Ctrl+Tab`, `Ctrl+M`, `Ctrl+H` and `Ctrl+F9/F10` are deliberately
**not** grabbed, so editor autocompletion, browser tab cycling and terminal
control characters still reach the application.

## Applying changes

The keyd half is live the moment `73-shortcuts.sh` runs. The global-shortcut
half is not:

> On Plasma 6 Wayland, `kwin_wayland` owns the `org.kde.kglobalaccel` D-Bus name
> and reads `kglobalshortcutsrc` **only at startup** — `kglobalacceld` is X11
> only and exits immediately. Changes to global shortcuts take effect at the
> next graphical login. There is no supported way to reload them in place;
> calling `org.kde.KGlobalAccel.setForeignShortcutKeys` kills the compositor.

`bash scripts/guest/73-shortcuts.sh --verify` reports every binding, scans
`kglobalshortcutsrc` for chords claimed by two actions, and says whether the
running session has picked the bindings up yet.

## Cmd+C in the terminal

The complaint was being forced onto `Ctrl+Shift+C` to copy. keyd cannot see
which application has focus, so `Cmd+C` cannot mean SIGINT in Konsole and copy
everywhere else — but it does not have to. `Cmd+C` and `Cmd+V` are mapped to
**`Ctrl+Insert` and `Shift+Insert`**, the other clipboard chords that every
toolkit already understands: `QKeySequence::Copy`/`Paste` include them, GTK's
text bindings include them, Firefox and VS Code bind them, and Konsole binds
them too (`edit_copy = Ctrl+Shift+C; Ctrl+Ins`, `edit_paste = Ctrl+Shift+V;
Shift+Ins`) precisely because `Ctrl+C` is reserved for SIGINT there.

So `Cmd+C` copies in the terminal and everywhere else, and `Ctrl+C` still sends
SIGINT, because physical Control is never remapped.

`Cmd+X` is deliberately left as `Ctrl+X` rather than `Shift+Delete`: in Dolphin
`Shift+Delete` means *delete permanently, bypassing the trash*, and cutting has
no meaning in a terminal anyway.

**Rejected: xremap.** xremap can do per-application rules on KDE via a KWin
script, which would allow `Cmd+C` to become `Ctrl+Shift+C` in Konsole
specifically. It was not adopted: it is not packaged for Debian, it would have
to chain a second exclusive evdev grab behind keyd's (a class of failure that
leaves the machine with no keyboard), and keyd would have to stop remapping
Command so xremap could still see it — which `50-mac-keyboard.sh` undoes at
every login. The `Ctrl+Insert` route solves the reported problem with none of
that risk.

## Known gaps

- **Terminal control characters.** `Cmd+S`, `Cmd+Z`, `Cmd+D` and `Cmd+Q` in
  Konsole are `Ctrl+S/Z/D/Q`, so they suspend flow control, suspend the job,
  send EOF, and resume flow control. `Cmd+S` freezing the terminal is the
  unpleasant one; disabling *Flow control* in the Konsole profile, or
  `stty -ixon`, removes it. Not fixable from the input layer.
- **`Cmd+W` / `Cmd+T` / `Cmd+N` in Konsole** do nothing useful: Konsole binds
  tab and window management to `Ctrl+Shift+W/T/N`. Konsole's shortcut file is
  owned by `30-input.sh`.
- **Konsole *Select All* and *Clear Scrollback* are unreachable.**
  `30-input.sh` rewrote them to `Meta+A` and `Meta+K`, replacing rather than
  extending the defaults, and Meta no longer exists. They need to go back to
  `Ctrl+Shift+A` / `Ctrl+Shift+K` in that script.
- **`Meta+` alternates in `kdeglobals`** written by `30-input.sh` are now inert.
  Harmless, but they no longer do anything.
- **`Cmd+Shift+Tab`, `Cmd+Space` and the window bindings are verified on disk
  only** until the next login, for the kwin_wayland reason above.
