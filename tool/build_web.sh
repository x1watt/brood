#!/bin/bash
# tool/build_web.sh
#
# Builds the browser version into build/web: the engine to WebAssembly
# (engine/web/build_wasm.sh), then Flutter for the web with every resource
# bundled (no CDN), so the folder can be served by any static file server
# and runs without an internet connection. The game files go into
# build/web/gamedata (tool/copy_game_files.sh); the page imports them once
# and keeps them in the browser.
#
# Serve it with any static server, e.g.:  python3 -m http.server -d build/web 8080

set -euo pipefail
cd "$(dirname "$0")/.."
engine/web/build_wasm.sh
# The machine-wide build lock (see ~/.claude/CLAUDE.md).
LOCK="${BUILD_LOCK:-$HOME/temp/bin/android-build-locked}"
"$LOCK" flutter build web --release --no-web-resources-cdn
tool/copy_game_files.sh build/web/gamedata
echo "Built build/web"
