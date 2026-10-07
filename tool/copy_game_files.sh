#!/bin/bash
# tool/copy_game_files.sh DEST
#
# Copies the game files the browser build carries into DEST (build/web/
# gamedata): StarDat.mpq, BrooDat.mpq, Patch_rt.mpq and the melee maps under
# maps/, from BROOD_DATA (default ~/box/media/games/BROOD), with the
# manifest.json the page imports them by (lib/game/game_files_web.dart).
# Without the game files nothing is copied and the page asks for them.

set -euo pipefail
dest="$(realpath -m "$1")"
src="${BROOD_DATA:-$HOME/box/media/games/BROOD}"
if [ ! -f "$src/StarDat.mpq" ]; then
	echo "No game files in $src: the build will not include them." >&2
	exit 0
fi
rm -rf "$dest"
mkdir -p "$dest"
cd "$src"
{
	printf '%s\n' StarDat.mpq BrooDat.mpq Patch_rt.mpq
	find maps -type f \( -iname '*.scm' -o -iname '*.scx' \) \
		-not -path '*/campaign/*' -not -path '*/scenario/*' -not -path '*/save/*' | sort
} | while IFS= read -r f; do
	mkdir -p "$dest/$(dirname "$f")"
	cp "$f" "$dest/$f"
	printf '%s\n' "$f"
done | python3 -c 'import json, sys; print(json.dumps([l.rstrip("\n") for l in sys.stdin]))' > "$dest/manifest.json"
echo "Game files copied into $dest"
