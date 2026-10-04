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

Since version 2 of the computer player (the default for new games; saves
made before replay with version 1, bw_bridge_set_ai_version,
GameSetup.legacyAi) it climbs the whole tech tree with a build plan per
race, Terran addons included (machine shops, control towers, a physics lab,
covert ops, comsats, a nuclear silo on the main command center), and picks
its army's mix from what it can build and what the enemies field (flyers
call for anti-air, cloaked units for detection, short gas for units that
cost none). Units use their abilities: tanks siege, vultures lay spider
mines, marines stim, ghosts cloak, lock down and call in nukes, battlecruisers
fire Yamato, vessels irradiate, EMP and shield, high templar storm and merge
into archons, arbiters freeze, corsairs web, defilers swarm, plague and
consume, queens ensnare and spawn broodlings, lurkers burrow, carriers and
reavers keep their interceptors and scarabs, comsats scan cloaked attackers.
It checks which enemy bases its units can walk to (OpenBW's region groups):
on island maps the plan turns to air units and anti-air at every base,
ground units go by dropship, shuttle or overlord (drops: load, fly, unload
by the target, attack), workers are ferried to expansions on other islands,
and buildings go to any base when the main one is full. Transports and
spellcasters never lead an attack. Auto-play never trains fighting units
without the attacking mode, and leaves alone units the human told to follow
one of their own units. test/probe/ai_probe.dart (run with flutter test) plays computer-only
games and prints what each side fields; BROOD_AI_LOG=<file> logs spells,
nukes, drops and expansions there.

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
start as alliances. An alliance holds at most three members (players who
surrendered don't count), and once a human is in one only humans let new
players in: computer members don't invite, and invitations to them go to
a human member. A human can put an ally out (bw_bridge_alliance_kick,
logged; not one who surrendered). Saves from before these rules replay
without them (bw_bridge_alliance_set_capped, GameSetup.legacyAlliances).
"Defensive mode" is a human member's switch (logged, on
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
API, with its frame) and the game's state itself (bw_bridge_save_snapshot,
engine/bridge/src/bw_snapshot.h, zlib-compressed: dart:io in a background
isolate, the browser's CompressionStream on the web); the session holds the
map and resolved setup. Loading starts the same game and puts the state in
place (bw_bridge_load_snapshot), which takes milliseconds however long the
game ran. The snapshot holds the pools of units, bullets, sprites, images
and orders as raw chunks, the paths and thingies, the plain part of the
state field by field, every intrusive list as the indices of its members,
and where every memory region was; loading gives the pools the same chunks,
moves each known pointer field to the same offset of the new region (as
OpenBW's state_copier remaps pointers) and rebuilds the lists in place. The
computer players, alliances, selections, control groups and the command log
come with it. Only the newest three auto-saves and the manual saves keep a
state; an older point loads the nearest earlier state and replays the log
from there. Points saved before states existed replay their whole log once,
and the state that replay arrives at is written into the point
(GameLaunch.keepState). A snapshot only loads into the build that made it
on the same kind of machine (its header records the structure sizes);
otherwise the log is replayed. bridge_smoke_test checks a loaded state
plays on identically for six minutes (4 players at 12 minutes, and with
SNAPSHOT_ONLY=1 also 8 players at 30 minutes and an island game with drops).
Auto-save (on by default) adds a point every game minute, every ten minutes
after the first hour and every hour after ten; leaving or quitting saves
too. A manual save, or carrying on from a loaded point, starts a new
session, so earlier timelines are never overwritten. Saves from before
sessions are turned into one-point sessions. The game menu
(top-left button or F10) pauses, saves, exits and quits; the start screen
has a quit button too.

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

Raised limits (engine/vendor/openbw on the local branch brood-limits, the
same change kept as engine/patches/openbw-brood-limits.patch): supply cap
2000 (the original 200), unit ids with a 16-bit index so the unit pool
holds 10000 units, and selections and control groups of 200 units (the
original 12). Saves from before name units the old way; they replay with
bw_bridge_set_legacy_unit_ids on (GameSetup.legacyIds), which maps old
unit slots onto the larger pool.

Colonizing without attacking (auto-play): colonies dig in (bw_ai.h
colony_defense): each town hall is fortified, weakest first, with up to
eight ground and three air defences (twice the ground with money piling
up): bunkers, missile turrets and sieged tanks; photon cannons by extra
pylons; sunken and spore colonies. One of each production building at
most, for a few mobile units (marines fill the bunkers).

The end of a game shows a score screen like the original's
(lib/ui/score_screen.dart): Victory or Defeat over the original's picture
for your race (glue\\Pal{Z,T,P}{v,d}\\Backgnd.pcx from the player's files),
and every player's numbers (bw_bridge_player_stats) in four tabs: units
produced, killed and lost; structures constructed, razed and lost;
minerals and gas mined and spent; and the score (units, structures,
resources, their total, and the alliance score), counting up as a tab
opens. BROOD_TEST_OUTCOME=victory:<seconds> (or defeat) ends a desktop
game that way, to check it.

Home server and multiplayer (tool/brood_server.dart, plain dart:io, run by
launch-web.sh on port 9191 on every network interface): it serves the
browser version, the player's own game files under gamedata/ (so pages
load them from there instead of asking for a folder; they are kept in the
browser too, and the page asks for persistent storage) and multiplayer on
/ws. Multiplayer is lockstep, built on the deterministic simulation and
its command log: in a multiplayer game the bridge's command functions are
deferred (bw_bridge_set_deferred: queued in an outbox, not run), the
client sends them to the server, which stamps each with a frame a few
frames ahead of its clock and sends it to every player; everyone runs it
on that frame (bw_bridge_apply_commands) and only runs up to the server's
clock (its ticks). Every game started from a page of the server is listed
in the start screen's Multiplayer tab (lib/ui/lobby_panel.dart); joining
replays the game's log (like loading a save, lib/net/multiplayer.dart
catchUp) and takes over one of the computer players with a logged
bw_bridge_set_controller, keeping its alliance; leaving hands it back to
the computer. Anyone's game menu pauses everyone ("Paused by ..."); a
pause ends when the player who paused leaves; losing the server lets the
game carry on alone. Every 240 frames the players report
bw_bridge_state_hash; the server reports a difference as out of sync
(BROOD_SERVER_DEBUG=1 prints the reports). bridge_smoke_test plays five
minutes of lockstep with a player joining at minute two and checks the
hashes match. Desktop and phones could join with BROOD_SERVER=ws://host:9191/ws
(lib/net/ws_io.dart), not tried yet.

Map editor (lib/ui/map_editor, lib/maps; the edit button next to each map on
the start screen): the map's scenario data is read from its archive with
bw_bridge_read_map_file (no game runs) and edited as CHK sections
(lib/maps/chk.dart): terrain (MTXM and TILE), start locations and resources
(UNIT), doodad sprites standing on replaced doodad tiles go (THG2, DD2),
the player slots follow the start locations (OWNR, SIDE), and the name and
description (STR, SPRP); every other section is written back as read.
Saving writes a new archive (lib/maps/mpq_writer.dart, sectors stored raw)
through GameFiles.saveMap: the game folder on desktop and Android, the
browser's IndexedDB and the engine's in-memory files on the web. Tools:
select (move, delete, a start's player, a resource's amount), terrain
brush, single tiles (alt-click picks), start locations, mineral fields and
geysers, plus every resource at once by level, undo and redo, and Save as.
The editor draws terrain from the tileset files itself (lib/maps/tileset.dart,
decoded into atlas pages by lib/rendering/megatile_atlas.dart, one
drawRawAtlas per page) and the resources from their GRPs.

Terrain blending (lib/maps/terrain_blend.dart): painted terrain gets the
right edges (shores around water, cliffs between levels, platform edges
around space) like the original editor's brushes. Terrain tiles come in
column pairs (the halves of the original editor's isometric diamonds), so
the editor works on 64x32 cells. Which cells may touch which, in all eight
directions, is learned from the player's own maps of the same tileset
(pairs seen a few times and not vanishingly rare for the rarer of the two,
which drops slips in single maps); the map being edited always counts. The
painted cells are fixed and a band around them (2 to 8 cells, widened when
the layers need room) is solved as a constraint problem: arc consistency,
then a search preferring each cell's current value and the most usual
neighbors, then every changed cell that can have its old value back gets
it. Doodads are never placed and fit anything next to the band. Learning
and solving run in a long-lived isolate on desktop and Android
(lib/maps/blend_worker_io.dart, with its own engine handle to read the
maps); the browser runs them on the page, yielding between maps.

Maps made from other maps (tool/make_island_map.py): "(8)Big Game Islands"
is Big Game Hunters with every land path cut by deep water, one island per
start location and per group of resources. The script reads the map's
tiles and their flags through engine/tools/map_tool (a small CMake program
on the vendored MPQ/tileset code: `map_tool extract` gives the scenario.chk,
`map_tool info` the tiles, starts and resources as JSON, `map_tool cat` a
file of the game's archives), grows the islands over walkable ground from
those seeds, turns the tiles where two islands meet into deep water, writes
a new .scm and then gives the channels shores and cliffs with
tool/blend_terrain.dart (the editor's blending, from the command line).
Browsers that already keep the game files fetch maps the home server got
since (game_files_web.dart compares with the server's manifest).

Transports (dropships, shuttles, overlords) and bunkers show what they
carry; clicking one unloads it (bw_bridge_unload_unit), and D unloads
everyone at a spot the transport flies to (BW_ORDER_UNLOAD). Ghosts call in
nuclear strikes (N, BW_ORDER_NUKE) once a silo has armed one.

Still missing: lift off/land.

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
