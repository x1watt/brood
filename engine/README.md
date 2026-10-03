# engine/

Native code for the Brood War bridge: vendored OpenBW simulation core plus the
bridge layer this project adds on top. See `docs/architecture.md` and the
approved plan (`~/.claude/plans/there-is-a-very-wondrous-pancake.md`) for the
full design.

## Layout

- `vendor/openbw` — OpenBW, as a pinned git submodule. Not yet added (Phase 1).
- `bridge/` — the `extern "C"` bridge API and its implementation. Builds with
  CMake for Linux desktop and Android (NDK); see `web/` for the WASM build.
  **v0 proven working** (lifecycle + stepping + scalar queries only — no
  frame-state draw-list or command submission yet, those land once the
  sprite/asset decode work is further along). Build:
  `cd engine/bridge && mkdir -p build && cd build && cmake .. && make`, then
  `LD_LIBRARY_PATH=. ./bridge_smoke_test` (a plain `.c` test, deliberately not
  C++, proving the ABI really is C-callable — what `dart:ffi` will bind
  against). Confirmed against the real install: `bridge_smoke_test: OK`.

  The bridge now also exposes the "parts list" rendering API (sprite
  enumeration + per-frame GRP decode + palette + player-color tables — see
  `bw_bridge.h`), deliberately not a pre-composited picture, so individual
  sprites can later be swapped for custom/HD textures on the Flutter side.
  The decode path (`bw_render_util.h`, adapted from OpenBW's own
  `ui/ui.h` RLE unpacker and PCX loader, without pulling in its SDL-coupled
  UI layer) is visually confirmed correct: `bridge_smoke_test` decodes a
  real visible sprite from the running game and dumps it to
  `sprite_decode_test.ppm` — opened and inspected, it's a clean, correctly
  colored Brood War sprite, not noise.
- `web/` — Emscripten build script for the WASM target. Not yet added (Phase 3b).
- `tools/sim_smoke_test/` — Phase 1 gate. No bundled `.rep` replay file exists
  in OpenBW's own repos, so this loads a real melee map (`(4)Lost Temple.scm`)
  from the user's own game data and steps the sim 500 frames, checking the
  result is sane (units exist, frame counter advanced). **Confirmed working**
  against `~/box/media/games/BROOD`: `sim_smoke_test: OK`. Build:
  `cd engine/tools/sim_smoke_test && mkdir -p build && cd build && cmake .. && make`,
  then run `./sim_smoke_test` (defaults to the user's real install path) or
  `./sim_smoke_test <data_dir> <map_file>` to point elsewhere. A true
  replay-based bit-exactness check can be added later if a `.rep` file turns up.

## Build commands (filled in as each phase lands)

**Linux desktop** (Phase 3a): plain CMake, system toolchain, no extra install.

**Android** (Phase 3c): NDK cross-compile.
Reminder (from the user's global CLAUDE.md): this machine hard-freezes on
concurrent heavy builds. Every `gradlew`/`flutter build`/`flutter run` must be
wrapped with `~/bin/android-build-locked` — **that path does not currently
exist on this machine** (only `~/temp/bin/android-build-locked` does); resolve
that before running any Android build. Raw `cmake`/`ninja` builds of this
bridge are not covered by that lock either — never run them concurrently with
a locked Flutter/Android build by hand.

**Web** (Phase 3b): requires installing `emsdk` first (not present on this
machine yet), then `web/build_wasm.sh`.
