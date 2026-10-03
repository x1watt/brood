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

Research, upgrades and abilities use OpenBW's own checks and actions
(unit_can_research/unit_can_upgrade/unit_can_use_tech, action_research,
action_upgrade, stim/siege/cloak/burrow actions; targeted spells issue the
order whose tech_type matches, from orders.dat). Command buttons show the
original icons from unit\cmdbtns\cmdicons.grp colored through ticon.pcx
(available/unavailable/active), the top bar the original game\icons.grp
(an uncompressed GRP, decoded separately from OpenBW's compressed reader).
Rally points are read from the building and drawn when it is selected.

Pylon power fields: OpenBW keeps each pylon's psi_field_sprite hidden. While
the player places a building that requires power, or has one own Pylon
selected, the controller calls bw_bridge_show_psi_fields(owner) and the draw
list includes those sprites (glow modifier through the light tables). The
bridge places the four quarter images geometrically around the pylon because
OpenBW's position for the flipped (left) quarters is off.

Preferences live in lib/game/settings.dart ($XDG_DATA_HOME/brood/
settings.json): volume (top bar slider), mute, fullscreen and the last game
setup. Windowed mode
on GNOME/X11 is always composited by mutter (only fullscreen or screen-sized
windows are unredirected), which adds latency; the runner sets
__GL_MaxFramesAllowed=1 to keep NVIDIA's frame queue short, fullscreen is
remembered, and F12 toggles a frame timing overlay (BROOD_PERF_LOG=1 logs
it to stderr).

Terrain is kept as palette indices and colored by shaders/terrain.frag
through a palette whose ranges 1-6 and 7-13 rotate every 8 game frames,
which animates water like the original's palette cycling (ranges confirmed
from the tileset data; the exact original timing isn't documented).

Icons are upscaled 4x with Scale2x on their palette indices and drawn
with smooth filtering, so the small original art isn't stretched into
uneven blocks. Production queues show the original five slots with unit
icons (click to cancel, via action_cancel_build_queue). Greyed buttons name
their missing requirement. Play time per map (game time) is kept in
$XDG_DATA_HOME/brood/play_stats.json and orders the start screen.

Games are set up on the start screen (lib/ui/start_screen.dart): 2 to 8
players (capped by the map), free for all, all against you or random
teams, a race or random per player. bw_bridge_new_game gives players the
map's start locations in a seed-shuffled order, sets alliances and shared
vision for teams, and loads OpenBW's Melee.trg so losing all buildings is a
defeat and the last side standing wins (the bridge remembers each outcome,
since OpenBW's trigger pass resets removed players' state to 0).

Computer opponents (engine/bridge/src/bw_ai.h) are a rule-based player
written for this project, since OpenBW has no AI: mining and gas, supply
ahead of use, a short build order and upgrades per race, army waves that
grow after each attack, base defense and expansions. It issues commands
through OpenBW's action functions inside bw_bridge_step and is
deterministic (no pointer ordering, its own seeded random numbers).

Fog of war: bw_bridge_set_viewer filters the draw list, unit list and
picking to what the player sees (neutral resources stay on explored
ground); bw_bridge_get_fog gives per-tile state, drawn as a one-texel-per-
tile image stretched over the map and minimap. Switched off for now
(GameController.fogOfWar = false): the whole map is shown.

Saved games ($XDG_DATA_HOME/brood/saves/, lib/game/saved_games.dart) are
the resolved setup plus the bridge's command log (every command entering
the API, with its frame). Loading starts the same game and replays the log
on a background isolate; bridge_smoke_test checks the replayed state hash
matches. The game menu (top-left button or F10) pauses, saves and exits.

Still missing: creep drawing, lift off/land and nukes, and the web/Android
targets.

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
