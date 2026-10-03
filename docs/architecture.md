# Architecture

Status: playable on Linux desktop. Lifecycle, stepping, sprite enumeration,
GRP decode, palette/player-color, terrain (VX4/VR4/CV5 megatile decode),
selection, move/attack/gather ("right-click smart command"), stop, and
training are all implemented and verified end to end against the user's
real StarCraft: Brood War install, including real mouse-driven play
(click-select, drag-box-select, right-click move with observed pathing,
Train SCV with correct mineral/supply deduction) in a live
`flutter run -d linux` window.

Still missing: fog-of-war, a real command card/build menu (only a single
hardcoded "Train SCV" button exists), minimap, camera zoom/clamping, sound,
and the web/Android targets. Updated as each phase lands.

## Layers

1. **Simulation core** — vendored OpenBW C++ (`engine/vendor/openbw`), unmodified.
   Deterministic, bit-exact game logic: units, orders, pathing, combat, fog.
2. **Bridge** (`engine/bridge`) — a small `extern "C"` API (`bw_bridge.h`) wrapping
   the simulation core. This is the only layer this project writes new C++ for.
   Compiled per target:
   - Linux desktop: native `.so` via CMake + system toolchain.
   - Android: native `.so` via CMake + NDK (same `CMakeLists.txt`, cross-compiled).
   - Web: `.wasm` via Emscripten.
3. **Dart bindings** (`lib/engine`) — `dart:ffi` on Linux/Android, `dart:js_interop`
   on web, unified behind a platform-conditional facade (`bw_engine.dart`) so the
   rest of the app never branches on platform.
4. **Rendering** (`lib/rendering`) — a structured per-frame draw-list from the
   bridge, rasterized by a Flutter `CustomPainter` using a pre-decoded sprite
   atlas. Chosen over C++-side framebuffer streaming so Flutter's own GPU
   pipeline does compositing and HUD/scene layering stays native. See the plan
   file for the full tradeoff writeup.
5. **Input & UI** (`lib/input`, `lib/ui`) — plain Flutter widgets; touch/mouse/
   keyboard translated into BWAPI-style commands sent through the bridge.

## Platform sequencing

Linux desktop first (no NDK/emsdk required, fastest iteration loop), then web
(stated priority), then Android. See the approved plan for phase details:
`~/.claude/plans/there-is-a-very-wondrous-pancake.md`.

## Policy

See `docs/third_party_licensing.md` — no bundled Blizzard assets, ever; OpenBW's
own licensing gap means no public redistribution of this project yet either.
