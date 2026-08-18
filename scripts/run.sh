#!/usr/bin/env bash
# Runs the app in the foreground so guest boot logs land in this terminal.
# Use scripts/launch.sh instead when you want it detached from the shell.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -x build/linuxonmac.app/Contents/MacOS/linuxonmac ] || ./scripts/build.sh
exec build/linuxonmac.app/Contents/MacOS/linuxonmac "$@"
