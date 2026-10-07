#!/bin/bash
# launch-linux.sh
#
# Builds the browser version (tool/build_web.sh, bundled for sharing the game
# on the network), then the Linux desktop app (the engine bridge is compiled
# with it, see linux/CMakeLists.txt) and starts it. The game files are read from
# BROOD_DATA (default ~/box/media/games/BROOD).
#
#   ./launch-linux.sh            release build
#   MODE=debug ./launch-linux.sh debug build

set -euo pipefail
cd "$(dirname "$0")"

MODE="${MODE:-release}"
# Heavy builds go through the machine-wide build lock when there is one.
LOCK="${BUILD_LOCK:-$HOME/temp/bin/android-build-locked}"
run_build() { if [ -x "$LOCK" ]; then "$LOCK" "$@"; else "$@"; fi; }

tool/build_web.sh
run_build flutter build linux "--$MODE"
exec "build/linux/x64/$MODE/bundle/brood" "$@"
