// engine/bridge/src/bw_bridge.cpp
//
// Implementation of bw_bridge.h. The only place (besides
// engine/tools/sim_smoke_test) that includes OpenBW's C++ headers: everything
// else talks to the simulation through bw_bridge.h's plain C functions.
//
// Rule of thumb for this file: wherever OpenBW already has a function for
// something (draw order, image placement, right-click resolution, build
// validation, placement checks), call it or mirror it exactly rather than
// approximating it here.

#include "bw_bridge.h"

#include "bwgame.h"
#include "actions.h"
#include "bw_render_util.h"

#include <algorithm>
#include <cstring>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>

using namespace bwgame;

namespace {

const char* const light_names[7] = {"ofire", "gfire", "bfire", "bexpl", "trans50", "red", "green"};

int permille(int value, int max) {
	if (max <= 0) return -1;
	int v = (int)((int64_t)value * 1000 / max);
	return std::max(0, std::min(1000, v));
}

} // namespace

// Sounds the simulation and command code ask for, waiting to be polled.
struct sound_queue {
	a_vector<bw_sound_event> events;
	void push(int id, xy position, const unit_t* source_unit, bool add_race_index) {
		if (events.size() >= 256) return;
		// Same adjustment as OpenBW's reference UI (ui/ui.h play_sound).
		if (add_race_index) id += 1;
		bw_sound_event e;
		e.sound_id = id;
		e.has_position = position != xy() ? 1 : 0;
		e.x = position.x;
		e.y = position.y;
		e.unit_type_id = source_unit ? (int32_t)source_unit->unit_type->id : -1;
		events.push_back(e);
	}
};

// OpenBW reports sounds through the virtual play_sound hook, which is a
// no-op in the base classes; these subclasses route it into the queue.
struct sim_functions : state_functions {
	sound_queue* sounds;
	sim_functions(state& st, sound_queue* sounds) : state_functions(st), sounds(sounds) {}
	void play_sound(int id, xy position, const unit_t* source_unit, bool add_race_index) override {
		sounds->push(id, position, source_unit, add_race_index);
	}
};

struct command_functions : action_functions {
	sound_queue* sounds;
	command_functions(state& st, action_state& action_st, sound_queue* sounds) : action_functions(st, action_st), sounds(sounds) {}
	void play_sound(int id, xy position, const unit_t* source_unit, bool add_race_index) override {
		sounds->push(id, position, source_unit, add_race_index);
	}
};

struct bw_bridge {
	std::unique_ptr<game_player> player;
	std::string data_dir;
	bool assets_loaded = false;
	bool game_started = false;

	int palette_tileset_index = -1;
	a_vector<uint8_t> palette; // 256 * 4 RGBA

	bool player_colors_loaded = false;
	std::array<std::array<uint8_t, 8>, 16> player_colors{};

	int terrain_tileset_index = -1;
	bw_render_util::tileset_terrain terrain;

	int light_tileset_index = -1;
	std::array<bw_render_util::pcx_image, 7> light_tables;

	bool unit_names_loaded = false;
	a_vector<std::string> unit_names;
	// stat_txt.tbl string by its 1-based index (as used by the .dat labels).
	std::string stat_string(int index) {
		ensure_unit_names();
		if (index <= 0 || (size_t)index > unit_names.size()) return std::string();
		return unit_names[(size_t)index - 1];
	}

	// Loaded UI graphics, decoded to plain palette-index pixels per frame.
	struct ui_grp {
		a_vector<int> widths;
		a_vector<int> heights;
		a_vector<a_vector<uint8_t>> pixels;
	};
	a_vector<ui_grp> grps;

	action_state action_st;
	sound_queue sounds;
	std::unique_ptr<sim_functions> sim;
	// Always bind the result with `auto`: assigning it to an
	// action_functions would slice off the sound hook.
	command_functions actions() { return command_functions(player->st(), action_st, &sounds); }

	bool sound_table_loaded = false;
	sound_types_t sound_types;
	a_vector<std::string> sound_filenames;
	void ensure_sound_table() {
		if (sound_table_loaded) return;
		a_vector<uint8_t> data;
		asset_loader()(data, "arr/sfxdata.dat");
		sound_types = data_loading::load_sfxdata_dat(data);
		string_table_data tbl;
		asset_loader()(tbl.data, "arr/sfxdata.tbl");
		sound_filenames.resize(sound_types.vec.size());
		for (size_t i = 0; i != sound_types.vec.size(); ++i) {
			size_t index = sound_types.vec[i].filename_index;
			if (index) sound_filenames[i] = tbl[index].c_str();
		}
		sound_table_loaded = true;
	}

	data_loading::data_files_loader<>& asset_loader() {
		if (!asset_loader_) asset_loader_ = std::make_unique<data_loading::data_files_loader<>>(data_loading::data_files_directory(data_dir));
		return *asset_loader_;
	}
	std::unique_ptr<data_loading::data_files_loader<>> asset_loader_;

	bool in_game() const { return game_started && player; }
	int tileset_index() { return (int)player->st().game->tileset_index; }

	void ensure_light_tables() {
		int t = tileset_index();
		if (light_tileset_index == t) return;
		const char* tileset = bw_render_util::tileset_names().at((size_t)t);
		a_vector<uint8_t> tmp;
		for (size_t i = 0; i != 7; ++i) {
			asset_loader()(tmp, format("Tileset/%s/%s.pcx", tileset, light_names[i]));
			light_tables[i] = bw_render_util::load_pcx_data(tmp);
		}
		light_tileset_index = t;
	}

	void ensure_unit_names() {
		if (unit_names_loaded) return;
		unit_names_loaded = true;
		a_vector<uint8_t> data;
		try {
			asset_loader()(data, "rez/stat_txt.tbl");
		} catch (...) {
			return;
		}
		if (data.size() < 2) return;
		size_t count = data[0] | (data[1] << 8);
		for (size_t i = 0; i != count && 2 + i * 2 + 1 < data.size(); ++i) {
			size_t offset = data[2 + i * 2] | (data[2 + i * 2 + 1] << 8);
			std::string s;
			for (size_t p = offset; p < data.size() && data[p]; ++p) {
				uint8_t c = data[p];
				if (c >= 0x20 && c < 0x7f) s += (char)c;
			}
			unit_names.push_back(std::move(s));
		}
	}
};

static bw_bridge* B(bw_bridge_t* bridge) {
	return reinterpret_cast<bw_bridge*>(bridge);
}

static unit_t* resolve_unit(state_functions& f, int32_t unit_id_raw) {
	if (unit_id_raw == 0) return nullptr;
	return f.get_unit(unit_id_32((uint32_t)unit_id_raw));
}

static int32_t unit_handle(state_functions& f, const unit_t* u) {
	return u ? (int32_t)f.get_unit_id_32(u).raw_value : 0;
}

// --- Lifecycle ----------------------------------------------------------------

int bw_bridge_abi_version(void) {
	return BW_BRIDGE_ABI_VERSION;
}

bw_bridge_t* bw_bridge_create(void) {
	try {
		return reinterpret_cast<bw_bridge_t*>(new bw_bridge());
	} catch (...) {
		return nullptr;
	}
}

void bw_bridge_destroy(bw_bridge_t* bridge) {
	delete B(bridge);
}

bw_status bw_bridge_load_assets(bw_bridge_t* bridge, const char* data_dir) {
	if (!bridge || !data_dir) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (b->assets_loaded) return BW_ERR_ALREADY_LOADED;
	try {
		b->data_dir = data_dir;
		b->player = std::make_unique<game_player>(b->data_dir);
		b->assets_loaded = true;
		return BW_OK;
	} catch (...) {
		b->player.reset();
		return BW_ERR_ASSET_LOAD_FAILED;
	}
}

bw_status bw_bridge_new_melee_game(bw_bridge_t* bridge, const char* map_file, int my_player_slot, int my_race) {
	if (!bridge || !map_file) return BW_ERR_INVALID_ARGUMENT;
	if (my_player_slot < 0 || my_player_slot > 11) return BW_ERR_INVALID_ARGUMENT;
	if (my_race < 0 || my_race > 2) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->assets_loaded || !b->player) return BW_ERR_NOT_LOADED;

	try {
		race_t race = static_cast<race_t>(my_race);
		std::string map_file_str = map_file;
		data_loading::mpq_file<> map_loader(map_file_str);
		game_load_functions game_load(b->player->st());
		game_load.load_map(map_loader, [&]() {
			state& st = b->player->st();
			game_load.setup_info.victory_condition = 0;
			game_load.setup_info.tournament_mode = 0;
			game_load.setup_info.starting_units = 0;
			game_load.setup_info.resource_type = 1;
			game_load.setup_info.starting_minerals = 50;
			for (int i = 0; i != 12; ++i) {
				if (i == my_player_slot) {
					st.players[i].controller = player_t::controller_occupied;
					st.players[i].race = race;
					game_load.setup_info.create_melee_units_for_player[i] = true;
				} else {
					st.players[i].controller = player_t::controller_inactive;
					game_load.setup_info.create_melee_units_for_player[i] = false;
				}
			}
		});
		b->sim = std::make_unique<sim_functions>(b->player->st(), &b->sounds);
		b->game_started = true;
		return BW_OK;
	} catch (...) {
		b->game_started = false;
		return BW_ERR_MAP_LOAD_FAILED;
	}
}

bw_status bw_bridge_step(bw_bridge_t* bridge, int n_frames) {
	if (!bridge || n_frames < 0) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	try {
		for (int i = 0; i != n_frames; ++i) b->sim->next_frame();
		return BW_OK;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

// --- Scalar queries -----------------------------------------------------------

int bw_bridge_current_frame(bw_bridge_t* bridge) {
	if (!bridge || !B(bridge)->in_game()) return -1;
	return (int)B(bridge)->player->st().current_frame;
}

int bw_bridge_unit_count(bw_bridge_t* bridge, int player_slot) {
	if (!bridge || player_slot < 0 || player_slot > 11 || !B(bridge)->in_game()) return -1;
	int n = 0;
	for (unit_t* u : ptr(B(bridge)->player->st().player_units.at(player_slot))) {
		(void)u;
		++n;
	}
	return n;
}

int bw_bridge_minerals(bw_bridge_t* bridge, int player_slot) {
	if (!bridge || player_slot < 0 || player_slot > 11 || !B(bridge)->in_game()) return -1;
	return B(bridge)->player->st().current_minerals[player_slot];
}

int bw_bridge_gas(bw_bridge_t* bridge, int player_slot) {
	if (!bridge || player_slot < 0 || player_slot > 11 || !B(bridge)->in_game()) return -1;
	return B(bridge)->player->st().current_gas[player_slot];
}

bw_status bw_bridge_supply(bw_bridge_t* bridge, int player_slot, int race, int* out_used_raw, int* out_available_raw) {
	if (!bridge || !out_used_raw || !out_available_raw || player_slot < 0 || player_slot > 11 || race < 0 || race > 2) {
		return BW_ERR_INVALID_ARGUMENT;
	}
	if (!B(bridge)->in_game()) return BW_ERR_NO_GAME;
	state& st = B(bridge)->player->st();
	*out_used_raw = st.supply_used[player_slot][race].raw_value;
	*out_available_raw = st.supply_available[player_slot][race].raw_value;
	return BW_OK;
}

// --- Rendering ----------------------------------------------------------------

// Mirrors ui/ui.h ui_util_functions::sprite_depth_order exactly.
static uint32_t sprite_depth_order(const sprite_t* sprite) {
	uint32_t score = 0;
	score |= sprite->elevation_level;
	score <<= 13;
	score |= sprite->elevation_level <= 4 ? sprite->position.y : 0;
	score <<= 1;
	score |= (sprite->flags & sprite_t::flag_turret) ? 1 : 0;
	return score;
}

int bw_bridge_get_draw_list(bw_bridge_t* bridge, int selected_owner,
                            int view_x, int view_y, int view_w, int view_h,
                            bw_draw_item* out_items, int max_count) {
	if (!bridge || !out_items || max_count < 0) return -1;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return -1;

	try {
		auto f = b->actions();
		state& st = b->player->st();

		// Sprites don't point back at their unit, so build that map once
		// (turret subunits map to their parent, which is what gets selected).
		std::unordered_map<const sprite_t*, const unit_t*> sprite_unit;
		for (int owner = 0; owner != 12; ++owner) {
			for (unit_t* u : ptr(st.player_units.at(owner))) {
				if (u->sprite) sprite_unit[u->sprite] = u;
				if (u->subunit && u->subunit->sprite) sprite_unit[u->subunit->sprite] = u;
			}
		}

		std::unordered_map<const sprite_t*, const unit_t*> selected_sprites;
		if (selected_owner >= 0 && (size_t)selected_owner < b->action_st.selection.size()) {
			for (unit_t* u : b->action_st.selection.at(selected_owner)) {
				if (u && u->sprite) selected_sprites[u->sprite] = u;
			}
		}

		// Same visible tile-line window and sort as ui.h draw_sprites().
		int map_tile_h = (int)st.game->map_tile_height;
		int from_y = view_y / 32 - 4;
		int to_y = (view_y + view_h) / 32 + 5;
		if (from_y < 0) from_y = 0;
		if (to_y > map_tile_h) to_y = map_tile_h;
		int min_x = view_x - 256;
		int max_x = view_x + view_w + 256;

		a_vector<std::pair<uint32_t, const sprite_t*>> sorted;
		for (int y = from_y; y < to_y; ++y) {
			for (const sprite_t* sprite : ptr(st.sprites_on_tile_line.at((size_t)y))) {
				if (f.s_hidden(sprite)) continue;
				if (sprite->position.x < min_x || sprite->position.x > max_x) continue;
				sorted.emplace_back(sprite_depth_order(sprite), sprite);
			}
		}
		std::sort(sorted.begin(), sorted.end());

		int n = 0;
		for (auto& entry : sorted) {
			const sprite_t* sprite = entry.second;
			auto unit_it = sprite_unit.find(sprite);
			const unit_t* u = unit_it == sprite_unit.end() ? nullptr : unit_it->second;
			int32_t unit_id = unit_handle(f, u);
			int owner = sprite->owner;
			int color_index = (owner >= 0 && owner < 12) ? (int)st.players[owner].color : 0;

			auto sel_it = selected_sprites.find(sprite);
			const unit_t* draw_selection_u = sel_it == selected_sprites.end() ? nullptr : sel_it->second;

			// ui.h draw_sprite(): images back to front; the selection circle
			// goes right before the first non-shadow image.
			for (const image_t* image : ptr(reverse(sprite->images))) {
				if (image->flags & image_t::flag_hidden) continue;
				if (!image->grp) continue;

				if (draw_selection_u && image->modifier != 10) {
					auto* circle_type = f.get_image_type((ImageTypes)((int)ImageTypes::IMAGEID_Selection_Circle_22pixels + sprite->sprite_type->selection_circle));
					const grp_t* circle_grp = st.global->image_grp[(size_t)circle_type->id];
					if (circle_grp && !circle_grp->frames.empty() && n < max_count) {
						auto& frame = circle_grp->frames.at(0);
						xy pos = sprite->position + xy(0, sprite->sprite_type->selection_circle_vpos);
						pos.x += int(frame.offset.x - circle_grp->width / 2);
						pos.y += int(frame.offset.y - circle_grp->height / 2);
						bw_draw_item& c = out_items[n++];
						c.kind = BW_DRAW_SELECTION_CIRCLE;
						c.x = pos.x;
						c.y = pos.y;
						c.image_type_id = (int32_t)circle_type->id;
						c.frame_index = 0;
						c.flipped = 0;
						c.color_index = color_index;
						c.owner = owner;
						c.modifier = 0;
						c.color_shift = 0;
						c.unit_id = unit_handle(f, draw_selection_u);
						c.hp_permille = permille(draw_selection_u->hp.raw_value, draw_selection_u->unit_type->hitpoints.raw_value);
						c.shield_permille = draw_selection_u->unit_type->has_shield
							? permille(draw_selection_u->shield_points.raw_value, draw_selection_u->unit_type->shield_points << 8)
							: -1;
					}
					draw_selection_u = nullptr;
				}

				if (n >= max_count) return n;
				xy pos = f.get_image_map_position(image);
				bw_draw_item& item = out_items[n++];
				item.kind = BW_DRAW_IMAGE;
				item.x = pos.x;
				item.y = pos.y;
				item.image_type_id = (int32_t)image->image_type->id;
				item.frame_index = (int32_t)image->frame_index;
				item.flipped = (image->flags & image_t::flag_horizontally_flipped) ? 1 : 0;
				item.color_index = color_index;
				item.owner = owner;
				item.modifier = image->modifier;
				item.color_shift = image->image_type->color_shift;
				item.unit_id = unit_id;
				item.hp_permille = -1;
				item.shield_permille = -1;
			}
		}
		return n;
	} catch (...) {
		return -1;
	}
}

int bw_bridge_get_tileset_index(bw_bridge_t* bridge) {
	if (!bridge || !B(bridge)->in_game()) return -1;
	return B(bridge)->tileset_index();
}

bw_status bw_bridge_get_palette(bw_bridge_t* bridge, uint8_t* out_rgba, int out_cap) {
	if (!bridge || !out_rgba || out_cap < 256 * 4) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	int t = b->tileset_index();
	if (b->palette_tileset_index != t) {
		try {
			b->palette = bw_render_util::load_tileset_palette((size_t)t, b->asset_loader());
			b->palette_tileset_index = t;
		} catch (...) {
			return BW_ERR_ASSET_LOAD_FAILED;
		}
	}
	std::memcpy(out_rgba, b->palette.data(), 256 * 4);
	return BW_OK;
}

bw_status bw_bridge_get_player_colors(bw_bridge_t* bridge, uint8_t* out_colors, int out_cap) {
	if (!bridge || !out_colors || out_cap < 16 * 8) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->assets_loaded) return BW_ERR_NOT_LOADED;
	if (!b->player_colors_loaded) {
		try {
			b->player_colors = bw_render_util::load_player_unit_colors(b->asset_loader());
			b->player_colors_loaded = true;
		} catch (...) {
			return BW_ERR_ASSET_LOAD_FAILED;
		}
	}
	std::memcpy(out_colors, b->player_colors.data(), 16 * 8);
	return BW_OK;
}

bw_status bw_bridge_get_light_table(bw_bridge_t* bridge, int light_index, uint8_t* out_table, int out_cap, int* out_rows) {
	if (!bridge || !out_rows || light_index < 1 || light_index > 7) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	try {
		b->ensure_light_tables();
	} catch (...) {
		return BW_ERR_ASSET_LOAD_FAILED;
	}
	auto& pcx = b->light_tables[(size_t)light_index - 1];
	int rows = (int)(pcx.data.size() / 256);
	*out_rows = rows;
	if (!out_table) return BW_OK;
	if (out_cap < rows * 256) return BW_ERR_INVALID_ARGUMENT;
	std::memcpy(out_table, pcx.data.data(), (size_t)rows * 256);
	return BW_OK;
}

static const grp_t::frame_t* get_frame(bw_bridge* b, int image_type_id, int frame_index) {
	state& st = b->player->st();
	if (image_type_id < 0 || (size_t)image_type_id >= st.global->image_grp.size()) return nullptr;
	const grp_t* grp = st.global->image_grp[(size_t)image_type_id];
	if (!grp) return nullptr;
	if (frame_index < 0 || (size_t)frame_index >= grp->frames.size()) return nullptr;
	return &grp->frames.at((size_t)frame_index);
}

bw_status bw_bridge_get_image_frame_size(bw_bridge_t* bridge, int image_type_id, int frame_index, int* out_width, int* out_height) {
	if (!bridge || !out_width || !out_height) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	const grp_t::frame_t* frame = get_frame(b, image_type_id, frame_index);
	if (!frame) return BW_ERR_INVALID_ARGUMENT;
	*out_width = (int)frame->size.x;
	*out_height = (int)frame->size.y;
	return BW_OK;
}

bw_status bw_bridge_get_image_frame_count(bw_bridge_t* bridge, int image_type_id, int* out_count) {
	if (!bridge || !out_count) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	state& st = b->player->st();
	if (image_type_id < 0 || (size_t)image_type_id >= st.global->image_grp.size()) return BW_ERR_INVALID_ARGUMENT;
	const grp_t* grp = st.global->image_grp[(size_t)image_type_id];
	if (!grp) return BW_ERR_INVALID_ARGUMENT;
	*out_count = (int)grp->frames.size();
	return BW_OK;
}

bw_status bw_bridge_decode_image_frame(bw_bridge_t* bridge, int image_type_id, int frame_index, int flipped, uint8_t* out_pixels, int out_cap) {
	if (!bridge || !out_pixels) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	const grp_t::frame_t* frame = get_frame(b, image_type_id, frame_index);
	if (!frame) return BW_ERR_INVALID_ARGUMENT;
	size_t needed = frame->size.x * frame->size.y;
	if ((size_t)out_cap < needed) return BW_ERR_INVALID_ARGUMENT;
	try {
		std::memset(out_pixels, 0, needed);
		bw_render_util::draw_frame(*frame, flipped != 0, out_pixels);
		return BW_OK;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

// --- Terrain ------------------------------------------------------------------

bw_status bw_bridge_get_map_tile_size(bw_bridge_t* bridge, int* out_width, int* out_height) {
	if (!bridge || !out_width || !out_height) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	*out_width = (int)b->player->st().game->map_tile_width;
	*out_height = (int)b->player->st().game->map_tile_height;
	return BW_OK;
}

bw_status bw_bridge_get_tile_grid(bw_bridge_t* bridge, uint16_t* out_megatiles, int out_cap) {
	if (!bridge || !out_megatiles) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	state& st = b->player->st();
	size_t n = st.tiles_mega_tile_index.size();
	if ((size_t)out_cap < n) return BW_ERR_INVALID_ARGUMENT;
	for (size_t i = 0; i != n; ++i) out_megatiles[i] = st.tiles_mega_tile_index[i] & 0x7fff; // drop the creep bit
	return BW_OK;
}

bw_status bw_bridge_decode_megatile(bw_bridge_t* bridge, int megatile_index, uint8_t* out_pixels, int out_cap) {
	if (!bridge || !out_pixels || out_cap < 32 * 32 || megatile_index < 0) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	int t = b->tileset_index();
	if (b->terrain_tileset_index != t) {
		try {
			b->terrain = bw_render_util::load_tileset_terrain((size_t)t, b->asset_loader());
			b->terrain_tileset_index = t;
		} catch (...) {
			return BW_ERR_ASSET_LOAD_FAILED;
		}
	}
	bw_render_util::decode_megatile(b->terrain, (size_t)megatile_index, out_pixels);
	return BW_OK;
}

// --- Units --------------------------------------------------------------------

static void fill_unit_info(state_functions& f, const unit_t* u, bw_unit_info& out) {
	std::memset(&out, 0, sizeof(out));
	out.unit_id = unit_handle(f, u);
	out.unit_type_id = (int32_t)u->unit_type->id;
	out.owner = u->owner;
	out.x = u->sprite ? u->sprite->position.x : 0;
	out.y = u->sprite ? u->sprite->position.y : 0;

	int flags = 0;
	if (f.ut_building(u)) flags |= BW_UNIT_FLAG_BUILDING;
	if (f.ut_resource(u)) flags |= BW_UNIT_FLAG_RESOURCE;
	if (f.ut_worker(u)) flags |= BW_UNIT_FLAG_WORKER;
	if (f.u_completed(u)) flags |= BW_UNIT_FLAG_COMPLETED;
	if (f.u_flying(u)) flags |= BW_UNIT_FLAG_FLYER;
	if (f.u_can_move(u)) flags |= BW_UNIT_FLAG_CAN_MOVE;
	out.flags = flags;

	out.hp = (int32_t)(u->hp.raw_value >> 8);
	out.max_hp = (int32_t)(u->unit_type->hitpoints.raw_value >> 8);
	if (u->unit_type->has_shield) {
		out.shields = (int32_t)(u->shield_points.raw_value >> 8);
		out.max_shields = u->unit_type->shield_points;
	}
	out.energy = f.ut_has_energy(u) ? (int32_t)(u->energy.raw_value >> 8) : 0;
	out.resources = f.ut_resource(u) ? u->building.resource.resource_count : 0;

	const rect& dim = u->unit_type->dimensions;
	out.width = dim.from.x + dim.to.x + 1;
	out.height = dim.from.y + dim.to.y + 1;

	out.queue_count = (int32_t)u->build_queue.size();
	for (size_t i = 0; i != u->build_queue.size() && i != 5; ++i) out.queue[i] = (int32_t)u->build_queue[i]->id;

	out.max_energy = f.ut_has_energy(u) ? (int32_t)(f.unit_max_energy(u).raw_value >> 8) : 0;
	if (f.u_cloaked(u)) out.flags |= BW_UNIT_FLAG_CLOAKED;
	if (f.u_burrowed(u)) out.flags |= BW_UNIT_FLAG_BURROWED;
	if (u->stim_timer > 0) out.flags |= BW_UNIT_FLAG_STIMMED;

	out.researching_tech = -1;
	out.upgrading = -1;
	out.research_progress_permille = -1;
	if (f.ut_building(u)) {
		if (u->building.researching_type) {
			out.researching_tech = (int32_t)u->building.researching_type->id;
			int total = u->building.researching_type->research_time;
			out.research_progress_permille = permille(total - u->building.upgrade_research_time, total);
		} else if (u->building.upgrading_type) {
			out.upgrading = (int32_t)u->building.upgrading_type->id;
			int total = f.upgrade_time_cost(u->owner, u->building.upgrading_type);
			out.research_progress_permille = permille(total - u->building.upgrade_research_time, total);
		}
		const target_t& rally = u->building.rally;
		if (rally.unit || rally.pos != xy()) {
			out.has_rally = 1;
			out.rally_x = rally.unit && rally.unit->sprite ? rally.unit->sprite->position.x : rally.pos.x;
			out.rally_y = rally.unit && rally.unit->sprite ? rally.unit->sprite->position.y : rally.pos.y;
			out.rally_unit_id = unit_handle(f, rally.unit);
		}
	}

	out.progress_permille = -1;
	auto progress_of = [](const unit_t* x) {
		int total = x->unit_type->build_time;
		if (total <= 0) return -1;
		return permille(total - x->remaining_build_time, total);
	};
	if (!f.u_completed(u)) {
		out.progress_permille = progress_of(u);
	} else if (u->current_build_unit && !f.u_completed(u->current_build_unit)) {
		out.progress_permille = progress_of(u->current_build_unit);
	}
}

int bw_bridge_get_units(bw_bridge_t* bridge, bw_unit_info* out_units, int max_count) {
	if (!bridge || !out_units || max_count < 0) return -1;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return -1;
	try {
		auto f = b->actions();
		state& st = b->player->st();
		int n = 0;
		for (int owner = 0; owner != 12; ++owner) {
			for (unit_t* u : ptr(st.player_units.at(owner))) {
				if (n >= max_count) return n;
				if (f.unit_dead(u) || !u->sprite) continue;
				fill_unit_info(f, u, out_units[n++]);
			}
		}
		return n;
	} catch (...) {
		return -1;
	}
}

bw_status bw_bridge_get_unit(bw_bridge_t* bridge, int32_t unit_id, bw_unit_info* out_unit) {
	if (!bridge || !out_unit) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	try {
		auto f = b->actions();
		unit_t* u = resolve_unit(f, unit_id);
		if (!u || !u->sprite) return BW_ERR_INVALID_ARGUMENT;
		fill_unit_info(f, u, *out_unit);
		return BW_OK;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

int32_t bw_bridge_pick_unit_at(bw_bridge_t* bridge, int x, int y) {
	if (!bridge || !B(bridge)->in_game()) return 0;
	try {
		bw_bridge* b = B(bridge);
		auto f = b->actions();
		xy pos{x, y};
		// find_units_noexpand's index is keyed on each unit's left edge, so
		// widen the query by the largest unit size (as ui.h's
		// select_get_unit_at does) and test real bounds ourselves.
		rect area{pos - xy(32, 32), pos + xy(32, 32)};
		area.to.x += (int)f.game_st.max_unit_width;
		area.to.y += (int)f.game_st.max_unit_height;

		unit_t* best = nullptr;
		int best_area = 0;
		for (unit_t* u : f.find_units_noexpand(area)) {
			if (f.unit_dead(u) || !u->sprite) continue;
			const rect& dim = u->unit_type->dimensions;
			xy p = u->sprite->position;
			if (x < p.x - dim.from.x || x > p.x + dim.to.x) continue;
			if (y < p.y - dim.from.y || y > p.y + dim.to.y) continue;
			int a = (dim.from.x + dim.to.x + 1) * (dim.from.y + dim.to.y + 1);
			if (!best || a < best_area) {
				best = u;
				best_area = a;
			}
		}
		return unit_handle(f, best);
	} catch (...) {
		return 0;
	}
}

bw_status bw_bridge_get_unit_type_info(bw_bridge_t* bridge, int unit_type_id, bw_unit_type_info* out_info) {
	if (!bridge || !out_info) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	if (unit_type_id < 0 || unit_type_id >= (int)UnitTypes::None) return BW_ERR_INVALID_ARGUMENT;
	try {
		auto f = b->actions();
		const unit_type_t* ut = f.get_unit_type((UnitTypes)unit_type_id);
		std::memset(out_info, 0, sizeof(*out_info));
		out_info->mineral_cost = ut->mineral_cost;
		out_info->gas_cost = ut->gas_cost;
		out_info->supply_required_raw = (int32_t)ut->supply_required.raw_value;
		out_info->build_time = ut->build_time;
		out_info->placement_width = ut->placement_size.x;
		out_info->placement_height = ut->placement_size.y;
		out_info->is_building = f.ut_building(ut) ? 1 : 0;
		out_info->is_addon = f.ut_addon(ut) ? 1 : 0;
		int race = 3;
		if (ut->group_flags & 1) race = 0;
		else if (ut->group_flags & 2) race = 1;
		else if (ut->group_flags & 4) race = 2;
		out_info->race = race;

		b->ensure_unit_names();
		std::string name = (size_t)unit_type_id < b->unit_names.size() ? b->unit_names[(size_t)unit_type_id] : std::string();
		if (name.empty()) name = "Unit " + std::to_string(unit_type_id);
		std::strncpy(out_info->name, name.c_str(), sizeof(out_info->name) - 1);
		out_info->ready_sound = ut->ready_sound;
		out_info->what_first = ut->first_what_sound;
		out_info->what_last = ut->last_what_sound;
		out_info->pissed_first = ut->first_pissed_sound;
		out_info->pissed_last = ut->last_pissed_sound;
		out_info->yes_first = ut->first_yes_sound;
		out_info->yes_last = ut->last_yes_sound;
		return BW_OK;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

// --- Selection and commands ---------------------------------------------------

bw_status bw_bridge_select_units(bw_bridge_t* bridge, int owner, const int32_t* unit_ids, int count) {
	if (!bridge || (!unit_ids && count > 0) || owner < 0 || owner > 7) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	try {
		auto f = b->actions();
		a_vector<unit_t*> units;
		for (int i = 0; i != count && units.size() < 12; ++i) {
			unit_t* u = resolve_unit(f, unit_ids[i]);
			if (u) units.push_back(u);
		}
		f.action_select(owner, units);
		return BW_OK;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

int bw_bridge_get_selected_units(bw_bridge_t* bridge, int owner, int32_t* out_unit_ids, int max_count) {
	if (!bridge || !out_unit_ids || owner < 0 || owner > 7) return -1;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return -1;
	try {
		auto f = b->actions();
		int n = 0;
		for (unit_t* u : b->action_st.selection.at(owner)) {
			if (n >= max_count) break;
			if (!u || f.unit_dead(u)) continue;
			out_unit_ids[n++] = unit_handle(f, u);
		}
		return n;
	} catch (...) {
		return -1;
	}
}

bw_status bw_bridge_order(bw_bridge_t* bridge, int owner, int order, int x, int y, int32_t target_unit_id, int queue) {
	if (!bridge || owner < 0 || owner > 7) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	try {
		auto f = b->actions();
		unit_t* target = resolve_unit(f, target_unit_id);
		bool q = queue != 0;
		xy pos(x, y);
		bool ok = false;
		switch (order) {
		case BW_ORDER_DEFAULT:
			ok = f.action_default_order(owner, pos, target, nullptr, q);
			break;
		case BW_ORDER_MOVE:
			ok = f.action_order(owner, f.get_order_type(Orders::Move), pos, target, target ? target->unit_type : nullptr, q);
			break;
		case BW_ORDER_ATTACK:
			if (target) ok = f.action_order(owner, f.get_order_type(Orders::AttackUnit), pos, target, target->unit_type, q);
			else ok = f.action_order(owner, f.get_order_type(Orders::AttackMove), pos, nullptr, nullptr, q);
			break;
		case BW_ORDER_STOP:
			ok = f.action_stop(owner, q);
			break;
		case BW_ORDER_HOLD:
			ok = f.action_hold_position(owner, q);
			break;
		case BW_ORDER_RETURN_CARGO:
			ok = f.action_return_cargo(owner, q);
			break;
		case BW_ORDER_REPAIR:
			if (!target) return BW_ERR_INVALID_ARGUMENT;
			ok = f.action_order(owner, f.get_order_type(Orders::Repair), pos, target, target->unit_type, q);
			break;
		case BW_ORDER_PATROL:
			ok = f.action_order(owner, f.get_order_type(Orders::Patrol), pos, nullptr, nullptr, q);
			break;
		default:
			return BW_ERR_INVALID_ARGUMENT;
		}
		return ok ? BW_OK : BW_ERR_REJECTED;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

// The selected unit when the selection is one unit, or several units of the
// same type (e.g. a group of larvae), otherwise null.
static unit_t* first_of_uniform_selection(bw_bridge* b, state_functions& f, int owner) {
	(void)f;
	auto& selection = b->action_st.selection.at(owner);
	if (selection.empty()) return nullptr;
	unit_t* first = selection.front();
	for (unit_t* u : selection) {
		if (u->unit_type != first->unit_type) return nullptr;
	}
	return first;
}

int bw_bridge_get_buildable(bw_bridge_t* bridge, int owner, int32_t* out_unit_type_ids, int max_count) {
	if (!bridge || !out_unit_type_ids || owner < 0 || owner > 7) return -1;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return -1;
	try {
		auto f = b->actions();
		unit_t* u = first_of_uniform_selection(b, f, owner);
		if (!u || u->owner != owner) return 0;
		int n = 0;
		for (int id = 0; id < (int)UnitTypes::None && n < max_count; ++id) {
			const unit_type_t* ut = f.get_unit_type((UnitTypes)id);
			if (f.unit_can_build(u, ut)) out_unit_type_ids[n++] = id;
		}
		return n;
	} catch (...) {
		return -1;
	}
}

static const order_type_t* build_order_for(state_functions& f, const unit_t* builder, const unit_type_t* ut) {
	if (f.ut_addon(ut)) return f.get_order_type(Orders::PlaceAddon);
	if (f.unit_is(builder, UnitTypes::Protoss_Probe)) return f.get_order_type(Orders::PlaceProtossBuilding);
	if (f.unit_is(builder, UnitTypes::Zerg_Drone)) return f.get_order_type(Orders::DroneStartBuild);
	return f.get_order_type(Orders::PlaceBuilding);
}

bw_status bw_bridge_train(bw_bridge_t* bridge, int owner, int unit_type_id) {
	if (!bridge || owner < 0 || owner > 7 || unit_type_id < 0 || unit_type_id >= (int)UnitTypes::None) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	try {
		auto f = b->actions();
		const unit_type_t* ut = f.get_unit_type((UnitTypes)unit_type_id);
		unit_t* u = first_of_uniform_selection(b, f, owner);
		if (!u) return BW_ERR_REJECTED;
		bool ok;
		if (f.ut_addon(ut)) {
			// Addons have a fixed spot relative to their parent building;
			// action_build wants the addon's own top-left tile.
			xy top_left = u->sprite->position - u->unit_type->placement_size / 2;
			xy_t<size_t> tile((size_t)((top_left.x + ut->addon_position.x) / 32), (size_t)((top_left.y + ut->addon_position.y) / 32));
			ok = f.action_build(owner, build_order_for(f, u, ut), ut, tile);
		} else if (f.unit_is(u, UnitTypes::Zerg_Larva) || f.unit_is(u, UnitTypes::Zerg_Hydralisk) || f.unit_is(u, UnitTypes::Zerg_Mutalisk)) {
			ok = f.action_morph(owner, ut);
		} else if (f.unit_is_zerg_building(u) && f.unit_is_zerg_building(ut)) {
			ok = f.action_morph_building(owner, ut);
		} else {
			ok = f.action_train(owner, ut);
		}
		return ok ? BW_OK : BW_ERR_REJECTED;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

int bw_bridge_can_place(bw_bridge_t* bridge, int owner, int unit_type_id, int tile_x, int tile_y) {
	if (!bridge || owner < 0 || owner > 7 || unit_type_id < 0 || unit_type_id >= (int)UnitTypes::None) return 0;
	if (tile_x < 0 || tile_y < 0) return 0;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return 0;
	try {
		auto f = b->actions();
		unit_t* u = f.get_single_selected_unit(owner);
		if (!u) return 0;
		const unit_type_t* ut = f.get_unit_type((UnitTypes)unit_type_id);
		xy pos(tile_x * 32 + ut->placement_size.x / 2, tile_y * 32 + ut->placement_size.y / 2);
		return f.can_place_building(u, owner, ut, pos, false, false) ? 1 : 0;
	} catch (...) {
		return 0;
	}
}

bw_status bw_bridge_build(bw_bridge_t* bridge, int owner, int unit_type_id, int tile_x, int tile_y) {
	if (!bridge || owner < 0 || owner > 7 || unit_type_id < 0 || unit_type_id >= (int)UnitTypes::None) return BW_ERR_INVALID_ARGUMENT;
	if (tile_x < 0 || tile_y < 0) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	try {
		auto f = b->actions();
		unit_t* u = f.get_single_selected_unit(owner);
		if (!u) return BW_ERR_REJECTED;
		const unit_type_t* ut = f.get_unit_type((UnitTypes)unit_type_id);
		xy pos(tile_x * 32 + ut->placement_size.x / 2, tile_y * 32 + ut->placement_size.y / 2);
		// action_build returns true even when placement silently fails, so
		// check placement up front to report a real result.
		if (!f.can_place_building(u, owner, ut, pos, false, false)) return BW_ERR_REJECTED;
		bool ok = f.action_build(owner, build_order_for(f, u, ut), ut, xy_t<size_t>((size_t)tile_x, (size_t)tile_y));
		return ok ? BW_OK : BW_ERR_REJECTED;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

bw_status bw_bridge_cancel_last(bw_bridge_t* bridge, int owner) {
	if (!bridge || owner < 0 || owner > 7) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	try {
		auto f = b->actions();
		unit_t* u = f.get_single_selected_unit(owner);
		if (!u) return BW_ERR_REJECTED;
		bool ok;
		if (!f.u_completed(u)) ok = f.action_cancel_building_unit(owner);
		else ok = f.action_cancel_build_queue(owner, 254);
		return ok ? BW_OK : BW_ERR_REJECTED;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

bw_status bw_bridge_control_group(bw_bridge_t* bridge, int owner, int group, int action) {
	if (!bridge || owner < 0 || owner > 7 || group < 0 || group > 9 || action < 0 || action > 2) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	try {
		auto f = b->actions();
		return f.action_control_group(owner, (size_t)group, action) ? BW_OK : BW_ERR_REJECTED;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

int bw_bridge_cursor_marker_image(void) {
	return (int)ImageTypes::IMAGEID_Cursor_Marker;
}

bw_status bw_bridge_get_selection_circle(bw_bridge_t* bridge, int32_t unit_id, int* out_image_type_id, int* out_x, int* out_y) {
	if (!bridge || !out_image_type_id || !out_x || !out_y) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	try {
		auto f = b->actions();
		unit_t* u = resolve_unit(f, unit_id);
		if (!u || !u->sprite) return BW_ERR_INVALID_ARGUMENT;
		const sprite_t* sprite = u->sprite;
		auto* circle_type = f.get_image_type((ImageTypes)((int)ImageTypes::IMAGEID_Selection_Circle_22pixels + sprite->sprite_type->selection_circle));
		const grp_t* grp = b->player->st().global->image_grp[(size_t)circle_type->id];
		if (!grp || grp->frames.empty()) return BW_ERR_INVALID_ARGUMENT;
		auto& frame = grp->frames.at(0);
		xy pos = sprite->position + xy(0, sprite->sprite_type->selection_circle_vpos);
		*out_image_type_id = (int)circle_type->id;
		*out_x = pos.x + int(frame.offset.x - grp->width / 2);
		*out_y = pos.y + int(frame.offset.y - grp->height / 2);
		return BW_OK;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

int bw_bridge_sound_count(bw_bridge_t* bridge) {
	if (!bridge || !B(bridge)->assets_loaded) return -1;
	try {
		B(bridge)->ensure_sound_table();
		return (int)B(bridge)->sound_types.vec.size();
	} catch (...) {
		return -1;
	}
}

bw_status bw_bridge_get_sound_info(bw_bridge_t* bridge, int sound_id, bw_sound_info* out_info) {
	if (!bridge || !out_info) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->assets_loaded) return BW_ERR_NOT_LOADED;
	try {
		b->ensure_sound_table();
		if (sound_id < 0 || (size_t)sound_id >= b->sound_types.vec.size()) return BW_ERR_INVALID_ARGUMENT;
		const sound_type_t& t = b->sound_types.vec[(size_t)sound_id];
		std::memset(out_info, 0, sizeof(*out_info));
		out_info->priority = t.priority;
		out_info->flags = t.flags;
		out_info->min_volume = t.min_volume;
		std::strncpy(out_info->filename, b->sound_filenames[(size_t)sound_id].c_str(), sizeof(out_info->filename) - 1);
		return BW_OK;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

bw_status bw_bridge_load_sound(bw_bridge_t* bridge, int sound_id, uint8_t* out_data, int out_cap, int* out_len) {
	if (!bridge || !out_len) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->assets_loaded) return BW_ERR_NOT_LOADED;
	try {
		b->ensure_sound_table();
		if (sound_id < 0 || (size_t)sound_id >= b->sound_filenames.size()) return BW_ERR_INVALID_ARGUMENT;
		const std::string& name = b->sound_filenames[(size_t)sound_id];
		if (name.empty()) return BW_ERR_INVALID_ARGUMENT;
		a_vector<uint8_t> data;
		b->asset_loader()(data, a_string("sound/") + name.c_str());
		*out_len = (int)data.size();
		if (!out_data) return BW_OK;
		if (out_cap < (int)data.size()) return BW_ERR_INVALID_ARGUMENT;
		std::memcpy(out_data, data.data(), data.size());
		return BW_OK;
	} catch (...) {
		return BW_ERR_ASSET_LOAD_FAILED;
	}
}

int bw_bridge_poll_sounds(bw_bridge_t* bridge, bw_sound_event* out_events, int max_count) {
	if (!bridge || !out_events || max_count < 0) return -1;
	auto& events = B(bridge)->sounds.events;
	int n = (int)std::min(events.size(), (size_t)max_count);
	for (int i = 0; i != n; ++i) out_events[i] = events[(size_t)i];
	events.erase(events.begin(), events.begin() + n);
	return n;
}

// --- Research, upgrades and abilities ------------------------------------------

bw_status bw_bridge_get_tech_info(bw_bridge_t* bridge, int owner, int tech_id, bw_tech_info* out_info) {
	if (!bridge || !out_info || owner < 0 || owner > 11 || tech_id < 0 || tech_id >= (int)TechTypes::None) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	try {
		auto f = b->actions();
		const tech_type_t* t = f.get_tech_type((TechTypes)tech_id);
		std::memset(out_info, 0, sizeof(*out_info));
		out_info->mineral_cost = t->mineral_cost;
		out_info->gas_cost = t->gas_cost;
		out_info->research_time = t->research_time;
		out_info->energy_cost = t->energy_cost;
		out_info->icon = t->icon;
		out_info->race = t->race;
		out_info->researched = f.player_has_researched(owner, (TechTypes)tech_id) ? 1 : 0;
		std::string name = b->stat_string(t->label);
		std::strncpy(out_info->name, name.c_str(), sizeof(out_info->name) - 1);
		return BW_OK;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

bw_status bw_bridge_get_upgrade_info(bw_bridge_t* bridge, int owner, int upgrade_id, bw_upgrade_info* out_info) {
	if (!bridge || !out_info || owner < 0 || owner > 11 || upgrade_id < 0 || upgrade_id >= (int)UpgradeTypes::None) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	try {
		auto f = b->actions();
		const upgrade_type_t* t = f.get_upgrade_type((UpgradeTypes)upgrade_id);
		std::memset(out_info, 0, sizeof(*out_info));
		out_info->mineral_cost = f.upgrade_mineral_cost(owner, t);
		out_info->gas_cost = f.upgrade_gas_cost(owner, t);
		out_info->time = f.upgrade_time_cost(owner, t);
		out_info->icon = t->icon;
		out_info->race = t->race;
		out_info->level = f.player_upgrade_level(owner, (UpgradeTypes)upgrade_id);
		out_info->max_level = t->max_level;
		std::string name = b->stat_string(t->label);
		std::strncpy(out_info->name, name.c_str(), sizeof(out_info->name) - 1);
		return BW_OK;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

int bw_bridge_get_researchable(bw_bridge_t* bridge, int owner, int32_t* out_tech_ids, int max_count) {
	if (!bridge || !out_tech_ids || owner < 0 || owner > 7) return -1;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return -1;
	try {
		auto f = b->actions();
		unit_t* u = f.get_single_selected_unit(owner);
		if (!u || u->owner != owner) return 0;
		int n = 0;
		for (int id = 0; id < (int)TechTypes::None && n < max_count; ++id) {
			if (f.unit_can_research(u, f.get_tech_type((TechTypes)id), owner)) out_tech_ids[n++] = id;
		}
		return n;
	} catch (...) {
		return -1;
	}
}

int bw_bridge_get_upgradable(bw_bridge_t* bridge, int owner, int32_t* out_upgrade_ids, int max_count) {
	if (!bridge || !out_upgrade_ids || owner < 0 || owner > 7) return -1;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return -1;
	try {
		auto f = b->actions();
		unit_t* u = f.get_single_selected_unit(owner);
		if (!u || u->owner != owner) return 0;
		int n = 0;
		for (int id = 0; id < (int)UpgradeTypes::None && n < max_count; ++id) {
			if (f.unit_can_upgrade(u, f.get_upgrade_type((UpgradeTypes)id), owner)) out_upgrade_ids[n++] = id;
		}
		return n;
	} catch (...) {
		return -1;
	}
}

bw_status bw_bridge_research(bw_bridge_t* bridge, int owner, int tech_id) {
	if (!bridge || owner < 0 || owner > 7 || tech_id < 0 || tech_id >= (int)TechTypes::None) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	try {
		auto f = b->actions();
		return f.action_research(owner, f.get_tech_type((TechTypes)tech_id)) ? BW_OK : BW_ERR_REJECTED;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

bw_status bw_bridge_upgrade(bw_bridge_t* bridge, int owner, int upgrade_id) {
	if (!bridge || owner < 0 || owner > 7 || upgrade_id < 0 || upgrade_id >= (int)UpgradeTypes::None) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	try {
		auto f = b->actions();
		return f.action_upgrade(owner, f.get_upgrade_type((UpgradeTypes)upgrade_id)) ? BW_OK : BW_ERR_REJECTED;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

int bw_bridge_can_use_tech(bw_bridge_t* bridge, int owner, int tech_id) {
	if (!bridge || owner < 0 || owner > 7 || tech_id < 0 || tech_id >= (int)TechTypes::None) return 0;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return 0;
	try {
		auto f = b->actions();
		auto& selection = b->action_st.selection.at(owner);
		if (selection.empty()) return 0;
		const tech_type_t* t = f.get_tech_type((TechTypes)tech_id);
		for (unit_t* u : selection) {
			if (f.unit_can_use_tech(u, t, owner)) return 1;
		}
		return 0;
	} catch (...) {
		return 0;
	}
}

bw_status bw_bridge_cast(bw_bridge_t* bridge, int owner, int tech_id, int x, int y, int32_t target_unit_id, int queue) {
	if (!bridge || owner < 0 || owner > 7 || tech_id < 0 || tech_id >= (int)TechTypes::None) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	try {
		auto f = b->actions();
		// The casting order is the one whose tech_type is this tech
		// (orders.dat), e.g. CastPsionicStorm for Psionic_Storm.
		const order_type_t* order = nullptr;
		for (auto& o : b->player->st().global->order_types.vec) {
			if (o.tech_type == (TechTypes)tech_id) {
				order = &o;
				break;
			}
		}
		if (!order) return BW_ERR_INVALID_ARGUMENT;
		unit_t* target = resolve_unit(f, target_unit_id);
		bool ok = f.action_order(owner, order, xy(x, y), target, target ? target->unit_type : nullptr, queue != 0);
		return ok ? BW_OK : BW_ERR_REJECTED;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

bw_status bw_bridge_action(bw_bridge_t* bridge, int owner, int action) {
	if (!bridge || owner < 0 || owner > 7) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	try {
		auto f = b->actions();
		bool ok;
		switch (action) {
		case BW_ACT_STIM: ok = f.action_stim_pack(owner); break;
		case BW_ACT_SIEGE: ok = f.action_siege(owner, false); break;
		case BW_ACT_UNSIEGE: ok = f.action_unsiege(owner, false); break;
		case BW_ACT_CLOAK: ok = f.action_cloak(owner); break;
		case BW_ACT_DECLOAK: ok = f.action_decloak(owner); break;
		case BW_ACT_BURROW: ok = f.action_burrow(owner, false); break;
		case BW_ACT_UNBURROW: ok = f.action_unburrow(owner); break;
		case BW_ACT_TRAIN_FIGHTER: ok = f.action_train_fighter(owner); break;
		case BW_ACT_ARCHON_WARP: ok = f.action_morph_archon(owner); break;
		case BW_ACT_DARK_ARCHON_MELD: ok = f.action_morph_dark_archon(owner); break;
		case BW_ACT_UNLOAD_ALL: ok = f.action_unload_all(owner, false); break;
		case BW_ACT_CANCEL_RESEARCH: ok = f.action_cancel_research(owner); break;
		case BW_ACT_CANCEL_UPGRADE: ok = f.action_cancel_upgrade(owner); break;
		default: return BW_ERR_INVALID_ARGUMENT;
		}
		return ok ? BW_OK : BW_ERR_REJECTED;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

bw_status bw_bridge_set_rally(bw_bridge_t* bridge, int owner, int x, int y, int32_t target_unit_id) {
	if (!bridge || owner < 0 || owner > 7) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	try {
		auto f = b->actions();
		unit_t* target = resolve_unit(f, target_unit_id);
		const order_type_t* order = f.get_order_type(target ? Orders::RallyPointUnit : Orders::RallyPointTile);
		bool ok = f.action_order(owner, order, xy(x, y), target, target ? target->unit_type : nullptr, false);
		return ok ? BW_OK : BW_ERR_REJECTED;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

// --- Arbitrary game graphics ---------------------------------------------------

// Some UI GRPs (e.g. game\icons.grp) are stored uncompressed: each frame is
// width*height raw bytes at its offset, which OpenBW's read_grp (compressed
// line format) rejects. Both formats are decoded to plain pixels here.
static bool read_raw_grp(const a_vector<uint8_t>& data, bw_bridge::ui_grp& out) {
	if (data.size() < 6) return false;
	size_t count = data[0] | (data[1] << 8);
	if (data.size() < 6 + count * 8) return false;
	for (size_t i = 0; i != count; ++i) {
		const uint8_t* h = &data[6 + i * 8];
		size_t w = h[2], hh = h[3];
		size_t offset = h[4] | (h[5] << 8) | (h[6] << 16) | ((size_t)h[7] << 24);
		if (offset + w * hh > data.size()) return false;
		out.widths.push_back((int)w);
		out.heights.push_back((int)hh);
		out.pixels.emplace_back(data.begin() + offset, data.begin() + offset + w * hh);
	}
	return true;
}

int bw_bridge_grp_load(bw_bridge_t* bridge, const char* path) {
	if (!bridge || !path) return -1;
	bw_bridge* b = B(bridge);
	if (!b->assets_loaded) return -1;
	try {
		a_vector<uint8_t> data;
		b->asset_loader()(data, path);
		bw_bridge::ui_grp out;
		try {
			grp_t grp = read_grp(data_loading::data_reader_le(data.data(), data.data() + data.size()));
			for (auto& f : grp.frames) {
				out.widths.push_back((int)f.size.x);
				out.heights.push_back((int)f.size.y);
				a_vector<uint8_t> px(f.size.x * f.size.y);
				if (!px.empty()) bw_render_util::draw_frame(f, false, px.data());
				out.pixels.push_back(std::move(px));
			}
		} catch (...) {
			out = bw_bridge::ui_grp();
			if (!read_raw_grp(data, out)) return -1;
		}
		b->grps.push_back(std::move(out));
		return (int)b->grps.size() - 1;
	} catch (...) {
		return -1;
	}
}

int bw_bridge_grp_frame_count(bw_bridge_t* bridge, int handle) {
	if (!bridge || handle < 0 || (size_t)handle >= B(bridge)->grps.size()) return -1;
	return (int)B(bridge)->grps[(size_t)handle].pixels.size();
}

bw_status bw_bridge_grp_frame_size(bw_bridge_t* bridge, int handle, int frame, int* out_width, int* out_height) {
	if (!bridge || !out_width || !out_height || handle < 0 || (size_t)handle >= B(bridge)->grps.size()) return BW_ERR_INVALID_ARGUMENT;
	auto& g = B(bridge)->grps[(size_t)handle];
	if (frame < 0 || (size_t)frame >= g.pixels.size()) return BW_ERR_INVALID_ARGUMENT;
	*out_width = g.widths[(size_t)frame];
	*out_height = g.heights[(size_t)frame];
	return BW_OK;
}

bw_status bw_bridge_grp_decode(bw_bridge_t* bridge, int handle, int frame, uint8_t* out_pixels, int out_cap) {
	if (!bridge || !out_pixels || handle < 0 || (size_t)handle >= B(bridge)->grps.size()) return BW_ERR_INVALID_ARGUMENT;
	auto& g = B(bridge)->grps[(size_t)handle];
	if (frame < 0 || (size_t)frame >= g.pixels.size()) return BW_ERR_INVALID_ARGUMENT;
	auto& px = g.pixels[(size_t)frame];
	if ((size_t)out_cap < px.size()) return BW_ERR_INVALID_ARGUMENT;
	if (!px.empty()) std::memcpy(out_pixels, px.data(), px.size());
	return BW_OK;
}

bw_status bw_bridge_load_pcx(bw_bridge_t* bridge, const char* path, uint8_t* out_pixels, int out_cap, int* out_width, int* out_height) {
	if (!bridge || !path || !out_width || !out_height) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->assets_loaded) return BW_ERR_NOT_LOADED;
	try {
		a_vector<uint8_t> data;
		b->asset_loader()(data, path);
		bw_render_util::pcx_image pcx = bw_render_util::load_pcx_data(data);
		*out_width = (int)pcx.width;
		*out_height = (int)pcx.height;
		if (!out_pixels) return BW_OK;
		if ((size_t)out_cap < pcx.data.size()) return BW_ERR_INVALID_ARGUMENT;
		std::memcpy(out_pixels, pcx.data.data(), pcx.data.size());
		return BW_OK;
	} catch (...) {
		return BW_ERR_ASSET_LOAD_FAILED;
	}
}

bw_status bw_bridge_cancel_queue_slot(bw_bridge_t* bridge, int owner, int slot) {
	if (!bridge || owner < 0 || owner > 7 || slot < 0 || slot > 4) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = B(bridge);
	if (!b->in_game()) return BW_ERR_NO_GAME;
	try {
		auto f = b->actions();
		unit_t* u = f.get_single_selected_unit(owner);
		if (!u || (size_t)slot >= u->build_queue.size()) return BW_ERR_REJECTED;
		return f.action_cancel_build_queue(owner, (size_t)slot) ? BW_OK : BW_ERR_REJECTED;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}
