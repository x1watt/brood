// engine/bridge/include/bw_bridge.h
//
// extern "C" contract between the vendored OpenBW simulation core
// (engine/vendor/openbw) and every host runtime: dart:ffi on Linux desktop
// and Android, dart:js_interop (via Emscripten) on web. No C++ types cross
// this boundary, only plain integers, pointers and fixed-width buffers.
//
// This header is also what `ffigen` runs against to generate the Dart
// bindings (lib/engine/bw_bridge_gen.dart). Keep it C, not C++, and keep
// every struct layout explicit and stable: a change here is a breaking
// change for every binding generated from it.

#ifndef BW_BRIDGE_H
#define BW_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Bumped whenever a function signature or struct layout below changes.
#define BW_BRIDGE_ABI_VERSION 10

typedef struct bw_bridge bw_bridge_t; // opaque

// Never a C++ exception crosses this boundary: every throwing OpenBW call is
// caught internally and mapped to one of these.
typedef enum bw_status {
	BW_OK = 0,
	BW_ERR_ALREADY_LOADED = -1,
	BW_ERR_NOT_LOADED = -2,
	BW_ERR_ASSET_LOAD_FAILED = -3,
	BW_ERR_MAP_LOAD_FAILED = -4,
	BW_ERR_NO_GAME = -5,
	BW_ERR_INVALID_ARGUMENT = -6,
	BW_ERR_REJECTED = -7, // the engine refused the command (requirements, placement, resources...)
	BW_ERR_UNKNOWN = -99,
} bw_status;

int bw_bridge_abi_version(void);

// --- Lifecycle -------------------------------------------------------------

bw_bridge_t* bw_bridge_create(void);
void bw_bridge_destroy(bw_bridge_t* bridge);

// Loads StarDat.mpq/BrooDat.mpq/Patch_rt.mpq from data_dir. data_dir must be
// a user-supplied location (their own copy), never a path inside the app
// bundle. See docs/third_party_licensing.md.
bw_status bw_bridge_load_assets(bw_bridge_t* bridge, const char* data_dir);

// Starts a melee game on map_file with the local player in my_player_slot
// (0-11) as my_race (0=zerg, 1=terran, 2=protoss). Other slots are inactive.
bw_status bw_bridge_new_melee_game(bw_bridge_t* bridge, const char* map_file,
                                    int my_player_slot, int my_race);

// Advances the simulation by n_frames (synchronous).
bw_status bw_bridge_step(bw_bridge_t* bridge, int n_frames);

// --- Scalar queries --------------------------------------------------------

int bw_bridge_current_frame(bw_bridge_t* bridge);
int bw_bridge_unit_count(bw_bridge_t* bridge, int player_slot);
int bw_bridge_minerals(bw_bridge_t* bridge, int player_slot);
int bw_bridge_gas(bw_bridge_t* bridge, int player_slot);

// Supply in BW's half-unit fixed point (divide by 2 for display).
bw_status bw_bridge_supply(bw_bridge_t* bridge, int player_slot, int race, int* out_used_raw, int* out_available_raw);

// --- Rendering: the ordered "parts list" ------------------------------------
//
// Not a composited picture: every visible image is described by what it is
// (image_type_id + frame_index + flipped) and where its top-left corner is,
// so the host decides what pixels to draw for each one (which is what lets
// textures be swapped later). The list is already in OpenBW's exact draw
// order (sprite_depth_order, images back to front) and positions already
// include each frame's offset inside its GRP, so the host must draw items in
// order and must not re-sort or re-center them.

#define BW_DRAW_IMAGE 0
#define BW_DRAW_SELECTION_CIRCLE 1

// Image modifiers (image_t::modifier) a host needs to treat differently:
#define BW_MOD_NORMAL 0
#define BW_MOD_PLAYER_COLOR 1
#define BW_MOD_SHADOW 10 // darken whatever is underneath, don't draw colors
#define BW_MOD_GLOW 9    // additive light effect; pixel values index the light table given by color_shift

typedef struct bw_draw_item {
	int32_t kind;          // BW_DRAW_IMAGE or BW_DRAW_SELECTION_CIRCLE
	int32_t x;             // top-left of the frame, map pixels
	int32_t y;
	int32_t image_type_id;
	int32_t frame_index;
	int32_t flipped;       // 0 or 1
	int32_t color_index;   // player color (st.players[owner].color), row in bw_bridge_get_player_colors
	int32_t owner;         // player slot 0-11 (11 is neutral: minerals, geysers, critters)
	int32_t modifier;      // see BW_MOD_*; unknown values can be drawn as normal
	int32_t color_shift;   // for BW_MOD_GLOW: 1-based light table index
	int32_t unit_id;       // owning unit, 0 if the sprite isn't a unit (effects, bullets...)
	int32_t hp_permille;   // selection circles only: hit points as 0-1000, -1 if not applicable
	int32_t shield_permille; // selection circles only: shields as 0-1000, -1 if none
} bw_draw_item;

// Fills out_items with everything visible inside the map-pixel rectangle
// (view_x, view_y, view_w, view_h), in draw order, with selection circles
// for selected_owner's current selection inserted where OpenBW draws them.
// Returns the number written, or -1 on error.
int bw_bridge_get_draw_list(bw_bridge_t* bridge, int selected_owner,
                            int view_x, int view_y, int view_w, int view_h,
                            bw_draw_item* out_items, int max_count);

int bw_bridge_get_tileset_index(bw_bridge_t* bridge);

// 256 RGBA8888 entries (1024 bytes).
bw_status bw_bridge_get_palette(bw_bridge_t* bridge, uint8_t* out_rgba, int out_cap);

// 16 colors x 8 shades (128 bytes): palette indices 8..15 in a decoded frame
// are remapped through row color_index before the palette lookup.
bw_status bw_bridge_get_player_colors(bw_bridge_t* bridge, uint8_t* out_colors, int out_cap);

// Light (glow) table light_index (1-based, as in bw_draw_item.color_shift):
// rows x 256 palette indices. A glow pixel with value v drawn over palette
// color d becomes palette color table[(v - 1) * 256 + d]. out_cap must be
// >= rows * 256; pass out_table NULL to just query *out_rows.
bw_status bw_bridge_get_light_table(bw_bridge_t* bridge, int light_index, uint8_t* out_table, int out_cap, int* out_rows);

bw_status bw_bridge_get_image_frame_size(bw_bridge_t* bridge, int image_type_id, int frame_index, int* out_width, int* out_height);
bw_status bw_bridge_get_image_frame_count(bw_bridge_t* bridge, int image_type_id, int* out_count);

// width*height palette-index bytes, 0 = transparent. No player recoloring.
bw_status bw_bridge_decode_image_frame(bw_bridge_t* bridge, int image_type_id, int frame_index, int flipped, uint8_t* out_pixels, int out_cap);

// --- Terrain ---------------------------------------------------------------

bw_status bw_bridge_get_map_tile_size(bw_bridge_t* bridge, int* out_width, int* out_height);
bw_status bw_bridge_get_tile_grid(bw_bridge_t* bridge, uint16_t* out_megatiles, int out_cap);
bw_status bw_bridge_decode_megatile(bw_bridge_t* bridge, int megatile_index, uint8_t* out_pixels, int out_cap);

// --- Units -------------------------------------------------------------------
//
// Unit handles are opaque, stable 32-bit values (0 = none). They go stale
// when the unit dies; functions taking one then do nothing.

#define BW_UNIT_FLAG_BUILDING  1
#define BW_UNIT_FLAG_RESOURCE  2 // mineral field or vespene geyser (including refinery-covered ones)
#define BW_UNIT_FLAG_WORKER    4
#define BW_UNIT_FLAG_COMPLETED 8
#define BW_UNIT_FLAG_FLYER     16
#define BW_UNIT_FLAG_CAN_MOVE  32
#define BW_UNIT_FLAG_CLOAKED   64
#define BW_UNIT_FLAG_BURROWED  128
#define BW_UNIT_FLAG_STIMMED   256

typedef struct bw_unit_info {
	int32_t unit_id;
	int32_t unit_type_id;
	int32_t owner;
	int32_t x;             // sprite center, map pixels
	int32_t y;
	int32_t flags;         // BW_UNIT_FLAG_*
	int32_t hp;            // whole hit points
	int32_t max_hp;
	int32_t shields;
	int32_t max_shields;
	int32_t energy;
	int32_t resources;     // remaining minerals/gas for resource units
	int32_t width;         // unit_type dimensions (for selection boxes / minimap)
	int32_t height;
	int32_t queue_count;   // build/train queue length (0-5)
	int32_t queue[5];      // unit type ids in the queue
	int32_t progress_permille; // progress of the current build/train (or own construction), -1 if none
	int32_t max_energy;
	int32_t researching_tech;      // tech id being researched, -1 if none
	int32_t upgrading;             // upgrade id being upgraded, -1 if none
	int32_t research_progress_permille; // for researching_tech / upgrading, -1 if none
	int32_t has_rally;             // production buildings: 1 if a rally point is set
	int32_t rally_x;               // rally point, map pixels
	int32_t rally_y;
	int32_t rally_unit_id;         // unit the rally point follows, 0 if a position
} bw_unit_info;

// All live units of every player. Returns count written, -1 on error.
int bw_bridge_get_units(bw_bridge_t* bridge, bw_unit_info* out_units, int max_count);

bw_status bw_bridge_get_unit(bw_bridge_t* bridge, int32_t unit_id, bw_unit_info* out_unit);

// Finds the unit whose sprite covers map position (x, y), 0 if none.
int32_t bw_bridge_pick_unit_at(bw_bridge_t* bridge, int x, int y);

typedef struct bw_unit_type_info {
	int32_t mineral_cost;
	int32_t gas_cost;
	int32_t supply_required_raw; // half units, like bw_bridge_supply
	int32_t build_time;          // frames
	int32_t placement_width;     // pixels (multiple of 32 for buildings)
	int32_t placement_height;
	int32_t is_building;
	int32_t is_addon;
	int32_t race;                // 0 zerg, 1 terran, 2 protoss, 3 other
	char name[48];               // from rez/stat_txt.tbl, UTF-8-safe ASCII
	// Voice lines (sound ids, inclusive ranges; first > last means none),
	// played by the host on selection (what), command (yes), repeated
	// clicking (pissed) and completion (ready).
	int32_t ready_sound;
	int32_t what_first, what_last;
	int32_t pissed_first, pissed_last;
	int32_t yes_first, yes_last;
} bw_unit_type_info;

bw_status bw_bridge_get_unit_type_info(bw_bridge_t* bridge, int unit_type_id, bw_unit_type_info* out_info);

// --- Selection and commands -------------------------------------------------

// Replaces the selection (max 12, as in the original game).
bw_status bw_bridge_select_units(bw_bridge_t* bridge, int owner, const int32_t* unit_ids, int count);
int bw_bridge_get_selected_units(bw_bridge_t* bridge, int owner, int32_t* out_unit_ids, int max_count);

#define BW_ORDER_DEFAULT 0 // right click: OpenBW's own action_default_order (move/attack/gather/repair/rally...)
#define BW_ORDER_MOVE    1
#define BW_ORDER_ATTACK  2 // attack target unit, or attack-move to (x, y)
#define BW_ORDER_STOP    3
#define BW_ORDER_HOLD    4
#define BW_ORDER_PATROL  5
#define BW_ORDER_RETURN_CARGO 6
#define BW_ORDER_REPAIR  7 // target_unit_id required

// Issues an order to the current selection.
bw_status bw_bridge_order(bw_bridge_t* bridge, int owner, int order, int x, int y, int32_t target_unit_id, int queue);

// Unit types the single selected unit can build or train right now
// (OpenBW's unit_can_build: tech requirements met; cost is not checked).
int bw_bridge_get_buildable(bw_bridge_t* bridge, int owner, int32_t* out_unit_type_ids, int max_count);

// Trains (units) or builds (addons) unit_type_id from the selected unit.
bw_status bw_bridge_train(bw_bridge_t* bridge, int owner, int unit_type_id);

// Whether the selected builder could place building unit_type_id with its
// top-left corner on tile (tile_x, tile_y).
int bw_bridge_can_place(bw_bridge_t* bridge, int owner, int unit_type_id, int tile_x, int tile_y);

// Orders the selected builder to construct unit_type_id at tile (tile_x, tile_y).
bw_status bw_bridge_build(bw_bridge_t* bridge, int owner, int unit_type_id, int tile_x, int tile_y);

// Cancels the last item of the selected building's queue (refunds it).
bw_status bw_bridge_cancel_last(bw_bridge_t* bridge, int owner);

// Cancels queue slot `slot` (0 = the one in production) of the selected
// building, as clicking a queued unit does in the original.
bw_status bw_bridge_cancel_queue_slot(bw_bridge_t* bridge, int owner, int slot);

// Control groups 0-9 (OpenBW's action_control_group): BW_GROUP_ASSIGN
// stores the current selection (Ctrl+N), BW_GROUP_RECALL selects the group's
// surviving units (N), BW_GROUP_ADD adds the selection to it (Shift+N).
#define BW_GROUP_ASSIGN 0
#define BW_GROUP_RECALL 1
#define BW_GROUP_ADD    2
bw_status bw_bridge_control_group(bw_bridge_t* bridge, int owner, int group, int action);

// --- Research, upgrades and abilities ------------------------------------------

typedef struct bw_tech_info {
	int32_t mineral_cost;
	int32_t gas_cost;
	int32_t research_time; // frames
	int32_t energy_cost;
	int32_t icon;          // frame in unit\cmdbtns\cmdicons.grp
	int32_t race;
	int32_t researched;    // for the owner passed in (or available without research)
	char name[64];
} bw_tech_info;

typedef struct bw_upgrade_info {
	int32_t mineral_cost;  // for the next level
	int32_t gas_cost;
	int32_t time;          // frames, next level
	int32_t icon;
	int32_t race;
	int32_t level;         // owner's current level
	int32_t max_level;
	char name[64];
} bw_upgrade_info;

bw_status bw_bridge_get_tech_info(bw_bridge_t* bridge, int owner, int tech_id, bw_tech_info* out_info);
bw_status bw_bridge_get_upgrade_info(bw_bridge_t* bridge, int owner, int upgrade_id, bw_upgrade_info* out_info);

// What the single selected building can research / upgrade right now
// (OpenBW's unit_can_research / unit_can_upgrade).
int bw_bridge_get_researchable(bw_bridge_t* bridge, int owner, int32_t* out_tech_ids, int max_count);
int bw_bridge_get_upgradable(bw_bridge_t* bridge, int owner, int32_t* out_upgrade_ids, int max_count);
bw_status bw_bridge_research(bw_bridge_t* bridge, int owner, int tech_id);
bw_status bw_bridge_upgrade(bw_bridge_t* bridge, int owner, int upgrade_id);

// Whether the first selected unit can use tech_id now (researched, completed,
// not disabled; energy not checked).
int bw_bridge_can_use_tech(bw_bridge_t* bridge, int owner, int tech_id);

// Casts a targeted ability (storm, lockdown, scanner sweep, ...) with the
// selection: issues the order whose tech is tech_id at (x, y) / target.
bw_status bw_bridge_cast(bw_bridge_t* bridge, int owner, int tech_id, int x, int y, int32_t target_unit_id, int queue);

// Instant abilities and toggles for the selection.
#define BW_ACT_STIM 0
#define BW_ACT_SIEGE 1
#define BW_ACT_UNSIEGE 2
#define BW_ACT_CLOAK 3
#define BW_ACT_DECLOAK 4
#define BW_ACT_BURROW 5
#define BW_ACT_UNBURROW 6
#define BW_ACT_TRAIN_FIGHTER 7 // interceptor / scarab
#define BW_ACT_ARCHON_WARP 8
#define BW_ACT_DARK_ARCHON_MELD 9
#define BW_ACT_UNLOAD_ALL 10
#define BW_ACT_CANCEL_RESEARCH 11
#define BW_ACT_CANCEL_UPGRADE 12
bw_status bw_bridge_action(bw_bridge_t* bridge, int owner, int action);

// Sets the selected building's rally point to a position or a unit.
bw_status bw_bridge_set_rally(bw_bridge_t* bridge, int owner, int x, int y, int32_t target_unit_id);

// --- Arbitrary game graphics (command icons, resource icons) --------------------

// Loads a GRP from the MPQs (e.g. "unit\cmdbtns\cmdicons.grp"); returns a
// handle >= 0, or -1. Handles stay valid until the bridge is destroyed.
int bw_bridge_grp_load(bw_bridge_t* bridge, const char* path);
int bw_bridge_grp_frame_count(bw_bridge_t* bridge, int handle);
bw_status bw_bridge_grp_frame_size(bw_bridge_t* bridge, int handle, int frame, int* out_width, int* out_height);
// width*height palette indices, 0 = transparent.
bw_status bw_bridge_grp_decode(bw_bridge_t* bridge, int handle, int frame, uint8_t* out_pixels, int out_cap);

// An 8-bit PCX image's pixels (palette indices). Pass out_pixels NULL to get
// the size only.
bw_status bw_bridge_load_pcx(bw_bridge_t* bridge, const char* path, uint8_t* out_pixels, int out_cap, int* out_width, int* out_height);

// --- Feedback visuals -------------------------------------------------------

// Image type of the original's right-click target marker.
int bw_bridge_cursor_marker_image(void);

// Selection circle image and its top-left map position for unit_id (for
// flashing a command target the way the original does).
bw_status bw_bridge_get_selection_circle(bw_bridge_t* bridge, int32_t unit_id, int* out_image_type_id, int* out_x, int* out_y);

// --- Sound -------------------------------------------------------------------
//
// The simulation reports sounds (weapons, deaths, construction...) through
// OpenBW's play_sound hook; they queue up here until polled. The host plays
// them, using bw_sound_info and the reference UI's rules: volume from
// min_volume and distance to the screen, priority-based channel stealing,
// flags 0x10 = don't restart while playing, 0x02 = one at a time per unit type.

typedef struct bw_sound_event {
	int32_t sound_id;
	int32_t has_position; // 0 = not positional (play at min_volume)
	int32_t x;
	int32_t y;
	int32_t unit_type_id; // source unit type, -1 if none
} bw_sound_event;

typedef struct bw_sound_info {
	int32_t priority;
	int32_t flags;
	int32_t min_volume; // 0-100
	char filename[80];  // relative to sound/ in the MPQs
} bw_sound_info;

int bw_bridge_sound_count(bw_bridge_t* bridge);
bw_status bw_bridge_get_sound_info(bw_bridge_t* bridge, int sound_id, bw_sound_info* out_info);

// Copies the sound's WAV file into out_data. Pass out_data NULL to just get
// *out_len.
bw_status bw_bridge_load_sound(bw_bridge_t* bridge, int sound_id, uint8_t* out_data, int out_cap, int* out_len);

// Drains queued sound events (oldest first). Returns the count written.
int bw_bridge_poll_sounds(bw_bridge_t* bridge, bw_sound_event* out_events, int max_count);

#ifdef __cplusplus
}
#endif

#endif // BW_BRIDGE_H
