#!/bin/bash
# tool/build_web.sh
#
# Builds the browser version into build/web: the engine to WebAssembly
# (engine/web/build_wasm.sh), then Flutter for the web with every resource
# bundled (no CDN), so the folder can be served by any static file server
# and runs without an internet connection. The player's game files are not
# part of it: the page asks for them once and keeps them in the browser.
#
# Serve it with any static server, e.g.:  python3 -m http.server -d build/web 8080

set -euo pipefail
cd "$(dirname "$0")/.."
engine/web/build_wasm.sh
# The machine-wide build lock (see ~/.claude/CLAUDE.md).
LOCK="${BUILD_LOCK:-$HOME/temp/bin/android-build-locked}"
"$LOCK" flutter build web --release --no-web-resources-cdn
echo "Built build/web"
