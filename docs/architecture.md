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

In-game alliances (engine/bridge/src/bw_alliances.h, lib/ui/alliance_panel.dart,
F9 or the top bar button): players invite each other and accept or decline;
an alliance shares a treasury among the members whose "Share resources"
switch is on (each frame their spending and income is folded into one
pool; computers start with it on, the human off, so allies can't spend
your money until you choose to), researched techs and upgrade levels, and
mining points, and the human may command allies' units: bridge commands
split the selection by owner and give each part in its owner's name
(OpenBW only lets a player order its own units); the computer then leaves
those units alone for a minute. Computers never command the human's units.
An alliance can never hold every player still in the game. Leaving, or
switching sharing off, takes an equal share of the treasury. Setup teams
start as alliances. "Defensive mode" is a human member's switch (logged, on
from the start of every new game):
while it is on, the alliance's computer players send no attack waves, keep
their armies home, fortify every base against ground and air (bw_ai.h
fortify: bunkers and turrets, cannons, sunken and spore colonies, with
the buildings these need), and when an ally's base is attacked they send
about half their army to clear the threat, which then stays by that ally
(help_allies); bridge_smoke_test checks they never reach enemy town halls.
Saves from before the switch replay with the human
sharing, as they were played (GameSetup.legacyRules).

Surrender: a player offers to surrender to another, who accepts or refuses.
A vassal joins its lord's alliance for good (no leaving, inviting or being
invited), keeps half of its mining and destroy points and pays the other
half to its lord; when the lord surrenders or is destroyed, its vassals pass
to the conqueror. Alliances get two-word names drawn by the bridge (word
lists in lib/game/alliance_names.dart). The bridge also measures each
player's army value, workers and mining rate per minute, and who is
fighting whom (recent kills either way, or an army at the other's
buildings); fighting groups are listed first with red borders. The panel can
be docked left or right (remembered in settings).

Score per player: mining (shared with allies while allied), Brood War's own
production score (unit_score + building_score) and destroy score (credited
to the unit's last attacker through OpenBW's on_kill_unit hook).

Computer diplomacy weighs the situation: losses and enemy armies at its
base (it asks the attacker for peace or a strong neighbour for help when it
can't hold), proximity (neighbours make useful allies), a common stronger
enemy, how much the partner mines (shared points), its own dominance and a
personality (trust). Refused while losing (or after a long hopeless
defence) it offers to surrender to the attacker; offered a surrender it
weighs the vassal's tribute against the score for destroying what is left.
Every free player aims at the best score: once no meaningful enemy is left,
one clearly stronger than an ally leaves the alliance and goes after it.

Auto-play (lib/ui/autoplay_panel.dart, F8): the computer player of bw_ai.h
runs for the human too, limited to chosen modes: resources (workers on
minerals and gas, balanced across bases), building (the build order and
upgrades), attacking (army and attack waves), colonizing (new bases with
workers and defences) or auto (all of them, at a normal computer's pace).
It leaves alone units the human commanded in the last minute or keeps in a
control group, restores the human's selection after deciding, and doesn't
negotiate alliances. Survival comes first in every mode: an army approaching
or at the base turns on production and defence (workers fight too when
there is no army) until the threat is over. Logged for saved games
(bw_bridge_set_autoplay). Computer players reserve money for buildings
whose worker is still walking to the site.

Fog of war: bw_bridge_set_viewer filters the draw list, unit list and
picking to what the player sees (neutral resources stay on explored
ground); bw_bridge_get_fog gives per-tile state, drawn as a one-texel-per-
tile image stretched over the map and minimap. Switched off for now
(GameController.fogOfWar = false): the whole map is shown.

Saved games ($XDG_DATA_HOME/brood/saves/, lib/game/saved_games.dart) are
kept in sessions: one folder per continuous stretch of play, holding points
in time. A point is the bridge's command log (every command entering the
API, with its frame); the session holds the map and resolved setup.
Auto-save (on by default) adds a point every game minute, every ten minutes
after the first hour and every hour after ten; leaving or quitting saves
too. A manual save, or carrying on from a loaded point, starts a new
session, so earlier timelines are never overwritten. Loading starts the
same game and replays the log on a background isolate; bridge_smoke_test
checks the replayed state hash matches. Saves from before sessions are
turned into one-point sessions. The game menu (top-left button or F10)
pauses, saves, exits and quits; the start screen has a quit button too.

Browser version (tool/build_web.sh, output build/web): the bridge is
compiled to WebAssembly with Emscripten (engine/web/build_wasm.sh into
web/bwbridge.js/.wasm, EMSDK default ~/temp/emsdk), and Flutter is built
with --no-web-resources-cdn, a bundled font (assets/fonts, web only) and a
bootstrap that never fetches fallback fonts, so the folder runs from any
static server with no internet. Dart reaches the engine through
lib/engine/bridge_raw.dart, one method per C function, generated with its
dart:ffi and WebAssembly implementations by tool/gen_bridge_raw.py from
bw_bridge.h; lib/engine/bw_engine.dart is the shared engine API on top,
reading structs at explicit offsets checked by test/engine_layout_test.dart.
Platform pieces: lib/platform/storage*.dart (files on desktop, IndexedDB in
the browser) for settings, stats and saves; lib/game/game_files_*.dart for
the game data (a folder on desktop; in the browser the player picks the
game folder once, the files are kept in IndexedDB and written into the
engine's in-memory file system at start). Saved games replay on a
background isolate on desktop and directly in the browser. Audio starts
from the click that starts a game (browsers require it) and stays up
between games.

Android version (tool/build_android.sh, output
build/app/outputs/flutter-apk/app-release.apk, arm64): the bridge is built
with the NDK (tool/build_android_bridge.sh into
android/app/src/main/jniLibs, not committed) and loaded through the same
dart:ffi layer. The game files are never in the APK: the first screen asks
for the player's StarCraft folder (storage access framework; MainActivity's
"brood/files" channel copies the three archives and the melee maps into
Android/data/dev.x1watt.brood/files/BROOD), or they can be copied there
over USB. Settings, stats and saves live in the app's private files. The
app runs in landscape, full screen, with the screen kept on.

Phones (shortest side under 500 dp) get a compact HUD over a full-screen
map: thin top bar, small minimap bottom-left, a fixed five-by-two command
card bottom-right (buttons never move under the finger), a selection card
only as big as what's selected, and messages as a toast under the bar.
Touch (lib/ui/game_viewport.dart, tested in test/touch_input_test.dart):
two fingers move the map; one finger on the ground draws a selection box;
a drag starting on the selected units draws an arrow colored by what
releasing would do (attack an enemy, gather from minerals or gas, follow a
friend, move) and does it; holding a finger still gives that command in
place; a tap selects, a double tap selects all of that type. Fingers are
imprecise, so taps and targets take the closest unit within a few pixels
(GameController.pickNear). A mouse (USB or Bluetooth) works as on desktop.

Phone GPUs are the bottleneck: sprites are packed into a few large
textures per image (lib/rendering/sprite_atlas.dart) instead of one per
frame, and the alliance panel's background blur is off on phones and the
panel isn't built while closed.
--dart-define=BROOD_PERF_LOG=true prints frame timings and
--dart-define=BROOD_TOUCH_LOG=true prints touch handling, for testing over
adb.

The app icon (a slit-pupil eye in a gold hive cell, original artwork, not
the game's) is drawn in code by tool/icons/make_icons_test.dart, which
writes the Android (legacy, adaptive and themed), web and Linux window
icons: run it with flutter test after changing the design.

Zerg creep (lib/rendering/creep_layer.dart) is drawn over the terrain from
the bridge's per-tile codes (bw_bridge_get_creep), creep megatiles plus the
tileset's edge frames as OpenBW draws them, refreshed a few times a second.
Without fog of war the map counts as explored for the human (logged
bw_bridge_explore_map): OpenBW refuses buildings on unexplored ground, which
made every Hatchery ghost red away from home. The placement preview checks
creep and blockers on every tile.

The browser's own right-click menu is disabled (web/index.html and
BrowserContextMenu), so right click gives orders.

The start screen wears the original's menu look with art read from the
player's own files at startup (lib/ui/menu_art.dart, bw_bridge_load_pcx_rgba
and bw_bridge_read_file): the title screen for three seconds at startup, the room of the
chosen race behind the menu (glue\\PalRz/Rt/Rp\\Backgnd.pcx, the planet of
glue\\Palmm for Random and saved games), the menus' green, and their button
sounds (sound\\glue). Nothing from the game is bundled. The menu music was
on the CD, not in the archives, so there is none.

Still missing: lift off/land and nukes.

## Layers

1. **Simulation core** — vendored OpenBW C++ (`engine/vendor/openbw`), unmodified.
   Deterministic, bit-exact game logic: units, orders, pathing, combat, fog.
2. **Bridge** (`engine/bridge`) — a small `extern "C"` API (`bw_bridge.h`) wrapping
   the simulation core. This is the only layer this project writes new C++ for.
   Compiled per target:
   - Linux desktop: native `.so` via CMake + system toolchain.
   - Android: native `.so` cross-compiled with the NDK (tool/build_android_bridge.sh).
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
