# Architecture

Status: playable on Linux desktop. Lifecycle, stepping, sprite enumeration,
GRP decode, palette/player-color, terrain (VX4/VR4/CV5 megatile decode),
selection, move/attack/gather ("right-click smart command"), stop, and
training are all implemented and verified end to end against the user's
real StarCraft: Brood War install, including real mouse-driven play
(click-select, drag-box-select, right-click move with observed pathing,
Train SCV with correct mineral/supply deduction) in a live
`flutter run -d linux` window.

Rendering mirrors OpenBW's reference renderer (ui/ui.h): the bridge returns
the draw list already in `sprite_depth_order` with images back to front and
positions from `get_image_map_position`; shadows, glows and cloaked images
get their own treatment. Commands go through OpenBW's own action functions
(`action_default_order` for right click, `action_build`/`can_place_building`
for placement, `unit_can_build` for the build menu).

The Linux app has a resource bar, minimap, selection panel and command card
(build menu, training queue, cancel), building placement, box/shift/double
click selection, attack/move/patrol/hold/stop, and edge/arrow/middle-drag/
minimap scrolling. engine/bridge/tests/bridge_smoke_test.c plays an opening
(mine, train, depot, refinery + gas, barracks + marine) as a regression test.

Sound: the bridge overrides OpenBW's virtual play_sound hook (sim and
command code) to queue sound events and serves WAVs from the MPQs;
lib/audio/sound_system.dart plays them with flutter_soloud using the
reference UI's rules (distance volume, 8 prioritized channels, no-restart
flags). Unit voice lines (what/yes/pissed/ready) and advisor errors are
triggered UI-side, as in the original.

Controls follow the original: command cards and hotkeys per unit type
(lib/game/command_cards.dart; workers' B/V build menus), control groups
through OpenBW's action_control_group, right-click markers (Cursor_Marker
image on ground, flashing selection circle on targets), edge scrolling along
the whole window border, fullscreen through a GTK method channel
("brood/window" in linux/runner/my_application.cc), race and map choice on a
start screen. bridge_smoke_test also covers sound, control groups and
Protoss/Zerg openings.

Still missing: an AI opponent (OpenBW has none), fog-of-war, creep,
research/upgrades and unit abilities on the command card, command button
icons, and the web/Android targets.

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
