// engine/bridge/include/bw_bridge.h
//
// extern "C" contract between the vendored OpenBW simulation core
// (engine/vendor/openbw) and every host runtime: dart:ffi on Linux desktop
// and Android, dart:js_interop (via Emscripten) on web. No C++ types cross
// this boundary — only plain integers, pointers and fixed-width buffers.
//
// This header is also what `ffigen` runs against to generate the Dart
// bindings (lib/engine/bw_bridge_gen.dart) — keep it C, not C++, and keep
// every struct layout explicit and stable; a change here is a breaking
// change for every binding generated from it.
//
// v0 scope: lifecycle + stepping + a few scalar queries, enough to prove the
// bridge boundary end-to-end (see engine/bridge/tests/bridge_smoke_test.c).
// The structured per-frame draw-list (bw_bridge_get_frame_state) and command
// submission (bw_bridge_submit_command) land in a later revision once the
// sprite/GRP decode work (Phase 5) is further along — expect this header to
// gain functions, not to have existing ones change shape without a version
// bump.

#ifndef BW_BRIDGE_H
#define BW_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Bumped whenever a function signature or struct layout below changes.
#define BW_BRIDGE_ABI_VERSION 6

typedef struct bw_bridge bw_bridge_t; // opaque

// Status codes returned by functions below. Never a C++ exception crosses
// this boundary — every throwing OpenBW call is caught internally and
// mapped to one of these.
typedef enum bw_status {
	BW_OK = 0,
	BW_ERR_ALREADY_LOADED = -1,
	BW_ERR_NOT_LOADED = -2,
	BW_ERR_ASSET_LOAD_FAILED = -3,
	BW_ERR_MAP_LOAD_FAILED = -4,
	BW_ERR_NO_GAME = -5,
	BW_ERR_INVALID_ARGUMENT = -6,
	BW_ERR_UNKNOWN = -99,
} bw_status;

int bw_bridge_abi_version(void);

// Create/destroy. One bw_bridge_t drives one simulation at a time.
bw_bridge_t* bw_bridge_create(void);
void bw_bridge_destroy(bw_bridge_t* bridge);

// Loads StarDat.mpq/BrooDat.mpq/Patch_rt.mpq from data_dir (must end in a
// path separator or not — both are accepted). This is the "bring your own
// assets" entry point: data_dir must be a user-supplied location, never a
// path inside the app bundle. See docs/third_party_licensing.md.
bw_status bw_bridge_load_assets(bw_bridge_t* bridge, const char* data_dir);

// Starts a single-player melee game on the given map: `my_player` occupies
// slot my_player_slot (0-11) with race my_race (0=zerg,1=terran,2=protoss,
// per bwgame.h's race_t ordinal — kept as a plain int here, not an enum, so
// this header has no dependency on OpenBW's own enum layout). All other
// slots are inactive. This matches the minimal setup already proven by
// engine/tools/sim_smoke_test; multiplayer/AI opponents are a later revision.
bw_status bw_bridge_new_melee_game(bw_bridge_t* bridge, const char* map_file,
                                    int my_player_slot, int my_race);

// Advances the simulation by n_frames (synchronous, blocking).
bw_status bw_bridge_step(bw_bridge_t* bridge, int n_frames);

// Scalar queries, valid only after bw_bridge_new_melee_game succeeded.
int bw_bridge_current_frame(bw_bridge_t* bridge);
int bw_bridge_unit_count(bw_bridge_t* bridge, int player_slot);
int bw_bridge_minerals(bw_bridge_t* bridge, int player_slot);
int bw_bridge_gas(bw_bridge_t* bridge, int player_slot);

// Supply in BW's own half-unit fixed-point (divide by 2.0 for the usual
// display value, e.g. raw 18 = 9 supply). race: 0=zerg,1=terran,2=protoss.
bw_status bw_bridge_supply(bw_bridge_t* bridge, int player_slot, int race, int* out_used_raw, int* out_available_raw);

// --- Rendering: the "parts list" the bridge hands to a host renderer -------
//
// Deliberately NOT a composited picture: every visible thing is described
// by what it is (image_type_id + frame_index + flipped) and where it is, so
// the host (Flutter) decides what pixels to draw for each one — which is
// what makes swapping in custom/HD textures later possible without touching
// this bridge. See docs/architecture.md.

// Fixed-layout struct shared across the FFI/WASM boundary — do not reorder
// or change field widths without bumping BW_BRIDGE_ABI_VERSION.
typedef struct bw_sprite_info {
	int32_t x;               // map pixel position
	int32_t y;
	int32_t image_type_id;   // identifies which GRP + recolor rules to use
	int32_t frame_index;
	int32_t flipped;         // 0 or 1 (horizontal flip)
	int32_t owner;           // player slot 0-11, for recoloring
	int32_t elevation_level; // z-order
	int32_t modifier;        // image->modifier (0/1 = normal/player-color; others are cloak/shadow/warp/etc, see bw_render_util.h — approximate or ignore these for now)
	int32_t unit_id;         // stable handle for this sprite's owning unit (0 = none); pass to the command functions below
} bw_sprite_info;

// Fills out_sprites (capacity max_count) with every currently visible
// image across all players, returns the number written (which may be less
// than the true total if max_count was too small — call again with a
// larger buffer if the return value equals max_count).
// v0 does not filter by fog-of-war/visibility for a specific viewer; that
// is a known gap, not yet implemented.
int bw_bridge_get_visible_sprites(bw_bridge_t* bridge, bw_sprite_info* out_sprites, int max_count);

// The tileset index (0-7) of the currently loaded map, used to pick which
// Tileset/<name>.wpe palette and recolor table apply.
int bw_bridge_get_tileset_index(bw_bridge_t* bridge);

// 256 RGBA8888 entries (1024 bytes) — the one palette every decoded pixel
// index below should be looked up against. out_cap must be >= 1024.
bw_status bw_bridge_get_palette(bw_bridge_t* bridge, uint8_t* out_rgba, int out_cap);

// 16 players x 8 shades (128 bytes) — palette indices 8..15 in a decoded
// sprite frame should be remapped through player_colors[owner] before
// looking up the palette, to recolor a unit for its owner. out_cap must be
// >= 128.
bw_status bw_bridge_get_player_colors(bw_bridge_t* bridge, uint8_t* out_colors, int out_cap);

// Frame dimensions for a given image type's frame, needed to size the
// buffer passed to bw_bridge_decode_image_frame.
bw_status bw_bridge_get_image_frame_size(bw_bridge_t* bridge, int image_type_id, int frame_index, int* out_width, int* out_height);

// Number of animation frames a GRP has — lets the host batch-decode a
// unit's whole frame set the first time it's seen, instead of decoding one
// animation frame at a time as new ones appear during play (which pops the
// sprite out for a tick on every still-undecoded frame — visible as
// flicker on any animating unit).
bw_status bw_bridge_get_image_frame_count(bw_bridge_t* bridge, int image_type_id, int* out_count);

// Decodes one GRP frame into out_pixels as width*height palette-index bytes
// (0-255, use bw_bridge_get_palette to turn these into colors; index 0 is
// BW's transparent index). out_cap must be >= width*height from
// bw_bridge_get_image_frame_size. Does not apply player-color recoloring —
// that is a host-side lookup against bw_bridge_get_player_colors, since it
// depends on which player owns the sprite being drawn, not the image data
// itself.
bw_status bw_bridge_decode_image_frame(bw_bridge_t* bridge, int image_type_id, int frame_index, int flipped, uint8_t* out_pixels, int out_cap);

// --- Terrain -----------------------------------------------------------
//
// The map is a grid of 32x32-pixel "megatiles". out_width/out_height below
// are in tile units (multiply by 32 for pixels).

bw_status bw_bridge_get_map_tile_size(bw_bridge_t* bridge, int* out_width, int* out_height);

// Fills out_megatiles (capacity map_width*map_height from
// bw_bridge_get_map_tile_size) with one megatile index per tile position,
// row-major. Pass each value to bw_bridge_decode_megatile.
bw_status bw_bridge_get_tile_grid(bw_bridge_t* bridge, uint16_t* out_megatiles, int out_cap);

// Decodes one 32x32 megatile into out_pixels (must hold 32*32 = 1024 bytes)
// as palette-index bytes — apply bw_bridge_get_palette the same way as for
// sprite frames (no player-color remap for terrain).
bw_status bw_bridge_decode_megatile(bw_bridge_t* bridge, int megatile_index, uint8_t* out_pixels, int out_cap);

// --- Commands ------------------------------------------------------------
//
// Unit handles are opaque, stable 32-bit values (index+generation packed;
// 0 means "no unit"); get them from bw_sprite_info.unit_id or
// bw_bridge_pick_unit_at. They go stale once the unit dies — the command
// functions below simply no-op (return BW_OK, nothing happens) if a handle
// no longer resolves to a live unit, same as the original game silently
// ignoring a stale order.

// Finds a unit whose sprite covers map position (x, y), or 0 if none.
int32_t bw_bridge_pick_unit_at(bw_bridge_t* bridge, int x, int y);

// Replaces player's current selection (same semantics as a fresh left-click
// or a drag-box select — not shift-add). count is clamped to 12 (BW's own
// selection limit) by the engine.
bw_status bw_bridge_select_units(bw_bridge_t* bridge, int owner, const int32_t* unit_ids, int count);

// Fills out_unit_ids with the player's currently selected units, returns
// the count written (BW's own cap is 12).
int bw_bridge_get_selected_units(bw_bridge_t* bridge, int owner, int32_t* out_unit_ids, int max_count);

// Orders the current selection to move to (x, y).
bw_status bw_bridge_order_move(bw_bridge_t* bridge, int owner, int x, int y, int queue);

// Orders the current selection to act on whatever's at (x, y) — the same
// "smart click" a right-click performs in the original game: attack if
// target_unit_id is hostile, gather if it's a resource, follow if it's
// friendly, otherwise just move there. Pass target_unit_id 0 (e.g. from
// bw_bridge_pick_unit_at returning none) for a plain move.
bw_status bw_bridge_order_right_click(bw_bridge_t* bridge, int owner, int x, int y, int32_t target_unit_id, int queue);

// Stops the current selection.
bw_status bw_bridge_order_stop(bw_bridge_t* bridge, int owner, int queue);

// Trains unit_type_id (a UnitTypes ordinal) from the current selection
// (only has an effect on selected production buildings that can train it).
bw_status bw_bridge_train(bw_bridge_t* bridge, int owner, int unit_type_id);

#ifdef __cplusplus
}
#endif

#endif // BW_BRIDGE_H
