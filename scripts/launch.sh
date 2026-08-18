#!/usr/bin/env bash
# Hands the app to LaunchServices so it outlives this shell. Logs are written to
# ~/Library/Application Support/linuxonmac/linuxonmac.log
set -euo pipefail
cd "$(dirname "$0")/.."
[ -x build/linuxonmac.app/Contents/MacOS/linuxonmac ] || ./scripts/build.sh
open build/linuxonmac.app --args "$@"
echo "Launched. Logs: ~/Library/Application Support/linuxonmac/linuxonmac.log"
