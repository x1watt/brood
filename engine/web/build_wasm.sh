#!/bin/bash
# engine/web/build_wasm.sh
#
# Compiles the bridge (and the vendored OpenBW headers) to WebAssembly:
# web/bwbridge.js + web/bwbridge.wasm, which Flutter copies into the web
# build. The module is created with createBwBridge() (see web/index.html and
# lib/engine/bridge_raw_web.dart); its exports come from
# engine/web/exported_functions.txt (written by tool/gen_bridge_raw.py).
#
# Needs Emscripten: EMSDK pointing at an emsdk checkout (default
# ~/temp/emsdk). No Blizzard data is compiled in: the game files are given
# by the player at run time.

set -euo pipefail
cd "$(dirname "$0")/../.."

EMSDK="${EMSDK:-$HOME/temp/emsdk}"
# shellcheck disable=SC1091
source "$EMSDK/emsdk_env.sh" > /dev/null 2>&1

exports="$(cat engine/web/exported_functions.txt)"

em++ -O2 -std=c++14 \
	-I engine/bridge/include -I engine/vendor/openbw \
	engine/bridge/src/bw_bridge.cpp \
	-o web/bwbridge.js \
	-fexceptions -sDISABLE_EXCEPTION_CATCHING=0 \
	-sMODULARIZE=1 -sEXPORT_NAME=createBwBridge -sENVIRONMENT=web \
	-sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=128MB -sMAXIMUM_MEMORY=2GB -sSTACK_SIZE=8MB \
	-sFORCE_FILESYSTEM=1 \
	-sEXPORTED_FUNCTIONS="$exports" \
	-sEXPORTED_RUNTIME_METHODS=FS,HEAPU8

ls -la web/bwbridge.js web/bwbridge.wasm
