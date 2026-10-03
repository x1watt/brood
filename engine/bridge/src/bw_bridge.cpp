// engine/bridge/src/bw_bridge.cpp
//
// Implementation of the v0 bridge contract declared in bw_bridge.h. This is
// the only place in the project that includes OpenBW's C++ headers directly
// outside of engine/tools/sim_smoke_test — everything else talks to the sim
// only through bw_bridge.h's plain C functions.

#include "bw_bridge.h"

#include "bwgame.h"
#include "actions.h"
#include "bw_render_util.h"

#include <exception>
#include <memory>
#include <string>
#include <cstring>

using namespace bwgame;

struct bw_bridge {
	std::unique_ptr<game_player> player;
	std::string data_dir;
	bool assets_loaded = false;
	bool game_started = false;

	// Lazily loaded on first use, keyed by tileset_index since that's the
	// only thing they vary on; a melee game never changes tileset mid-game.
	bool palette_loaded = false;
	int palette_tileset_index = -1;
	a_vector<uint8_t> palette; // 256 * 4 RGBA bytes

	bool player_colors_loaded = false;
	std::array<std::array<uint8_t, 8>, 16> player_colors{};

	bool terrain_loaded = false;
	int terrain_tileset_index = -1;
	bw_render_util::tileset_terrain terrain;

	action_state action_st;
	action_functions actions() { return action_functions(player->st(), action_st); }

	data_loading::data_files_loader<>& asset_loader() {
		if (!asset_loader_) asset_loader_ = std::make_unique<data_loading::data_files_loader<>>(data_loading::data_files_directory(data_dir));
		return *asset_loader_;
	}
	std::unique_ptr<data_loading::data_files_loader<>> asset_loader_;
};

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
	delete reinterpret_cast<bw_bridge*>(bridge);
}

bw_status bw_bridge_load_assets(bw_bridge_t* bridge, const char* data_dir) {
	if (!bridge || !data_dir) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
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

bw_status bw_bridge_new_melee_game(bw_bridge_t* bridge, const char* map_file,
                                    int my_player_slot, int my_race) {
	if (!bridge || !map_file) return BW_ERR_INVALID_ARGUMENT;
	if (my_player_slot < 0 || my_player_slot > 11) return BW_ERR_INVALID_ARGUMENT;
	if (my_race < 0 || my_race > 2) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
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
		b->game_started = true;
		return BW_OK;
	} catch (...) {
		b->game_started = false;
		return BW_ERR_MAP_LOAD_FAILED;
	}
}

bw_status bw_bridge_step(bw_bridge_t* bridge, int n_frames) {
	if (!bridge || n_frames < 0) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return BW_ERR_NO_GAME;
	try {
		for (int i = 0; i != n_frames; ++i) b->player->next_frame();
		return BW_OK;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

static int count_units(state& st, int owner) {
	int n = 0;
	for (unit_t* u : ptr(st.player_units.at(owner))) { (void)u; ++n; }
	return n;
}

int bw_bridge_current_frame(bw_bridge_t* bridge) {
	if (!bridge) return -1;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return -1;
	return (int)b->player->st().current_frame;
}

int bw_bridge_unit_count(bw_bridge_t* bridge, int player_slot) {
	if (!bridge || player_slot < 0 || player_slot > 11) return -1;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return -1;
	try {
		return count_units(b->player->st(), player_slot);
	} catch (...) {
		return -1;
	}
}

int bw_bridge_minerals(bw_bridge_t* bridge, int player_slot) {
	if (!bridge || player_slot < 0 || player_slot > 11) return -1;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return -1;
	return b->player->st().current_minerals[player_slot];
}

int bw_bridge_gas(bw_bridge_t* bridge, int player_slot) {
	if (!bridge || player_slot < 0 || player_slot > 11) return -1;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return -1;
	return b->player->st().current_gas[player_slot];
}

bw_status bw_bridge_supply(bw_bridge_t* bridge, int player_slot, int race, int* out_used_raw, int* out_available_raw) {
	if (!bridge || !out_used_raw || !out_available_raw || player_slot < 0 || player_slot > 11 || race < 0 || race > 2) {
		return BW_ERR_INVALID_ARGUMENT;
	}
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return BW_ERR_NO_GAME;
	state& st = b->player->st();
	*out_used_raw = st.supply_used[player_slot][race].raw_value;
	*out_available_raw = st.supply_available[player_slot][race].raw_value;
	return BW_OK;
}

int bw_bridge_get_visible_sprites(bw_bridge_t* bridge, bw_sprite_info* out_sprites, int max_count) {
	if (!bridge || !out_sprites || max_count < 0) return -1;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return -1;

	try {
		action_functions f = b->actions();
		state& st = b->player->st();
		int n = 0;
		for (int owner = 0; owner != 12; ++owner) {
			for (unit_t* u : ptr(st.player_units.at(owner))) {
				sprite_t* sprite = u->sprite;
				if (!sprite) continue;
				if (sprite->flags & sprite_t::flag_hidden) continue;
				int32_t unit_id_raw = (int32_t)f.get_unit_id_32(u).raw_value;
				for (image_t* image : ptr(sprite->images)) {
					if (image->flags & image_t::flag_hidden) continue;
					if (n >= max_count) return n;
					bw_sprite_info& info = out_sprites[n];
					info.x = (int32_t)sprite->position.x;
					info.y = (int32_t)sprite->position.y;
					info.image_type_id = (int32_t)image->image_type->id;
					info.frame_index = (int32_t)image->frame_index;
					info.flipped = (image->flags & image_t::flag_horizontally_flipped) ? 1 : 0;
					info.owner = (int32_t)owner;
					info.elevation_level = (int32_t)sprite->elevation_level;
					info.modifier = (int32_t)image->modifier;
					info.unit_id = unit_id_raw;
					++n;
				}
			}
		}
		return n;
	} catch (...) {
		return -1;
	}
}

int bw_bridge_get_tileset_index(bw_bridge_t* bridge) {
	if (!bridge) return -1;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return -1;
	return (int)b->player->st().game->tileset_index;
}

bw_status bw_bridge_get_palette(bw_bridge_t* bridge, uint8_t* out_rgba, int out_cap) {
	if (!bridge || !out_rgba || out_cap < 256 * 4) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return BW_ERR_NO_GAME;

	int tileset_index = (int)b->player->st().game->tileset_index;
	if (!b->palette_loaded || b->palette_tileset_index != tileset_index) {
		try {
			b->palette = bw_render_util::load_tileset_palette((size_t)tileset_index, b->asset_loader());
			b->palette_loaded = true;
			b->palette_tileset_index = tileset_index;
		} catch (...) {
			return BW_ERR_ASSET_LOAD_FAILED;
		}
	}
	std::memcpy(out_rgba, b->palette.data(), 256 * 4);
	return BW_OK;
}

bw_status bw_bridge_get_player_colors(bw_bridge_t* bridge, uint8_t* out_colors, int out_cap) {
	if (!bridge || !out_colors || out_cap < 16 * 8) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
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
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return BW_ERR_NO_GAME;
	const grp_t::frame_t* frame = get_frame(b, image_type_id, frame_index);
	if (!frame) return BW_ERR_INVALID_ARGUMENT;
	*out_width = (int)frame->size.x;
	*out_height = (int)frame->size.y;
	return BW_OK;
}

bw_status bw_bridge_decode_image_frame(bw_bridge_t* bridge, int image_type_id, int frame_index, int flipped, uint8_t* out_pixels, int out_cap) {
	if (!bridge || !out_pixels) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return BW_ERR_NO_GAME;
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

bw_status bw_bridge_get_map_tile_size(bw_bridge_t* bridge, int* out_width, int* out_height) {
	if (!bridge || !out_width || !out_height) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return BW_ERR_NO_GAME;
	*out_width = (int)b->player->st().game->map_tile_width;
	*out_height = (int)b->player->st().game->map_tile_height;
	return BW_OK;
}

bw_status bw_bridge_get_tile_grid(bw_bridge_t* bridge, uint16_t* out_megatiles, int out_cap) {
	if (!bridge || !out_megatiles) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return BW_ERR_NO_GAME;
	state& st = b->player->st();
	size_t n = st.tiles_mega_tile_index.size();
	if ((size_t)out_cap < n) return BW_ERR_INVALID_ARGUMENT;
	for (size_t i = 0; i != n; ++i) {
		out_megatiles[i] = st.tiles_mega_tile_index[i] & 0x7fff; // mask off the creep flag bit
	}
	return BW_OK;
}

bw_status bw_bridge_decode_megatile(bw_bridge_t* bridge, int megatile_index, uint8_t* out_pixels, int out_cap) {
	if (!bridge || !out_pixels || out_cap < 32 * 32 || megatile_index < 0) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return BW_ERR_NO_GAME;

	int tileset_index = (int)b->player->st().game->tileset_index;
	if (!b->terrain_loaded || b->terrain_tileset_index != tileset_index) {
		try {
			b->terrain = bw_render_util::load_tileset_terrain((size_t)tileset_index, b->asset_loader());
			b->terrain_loaded = true;
			b->terrain_tileset_index = tileset_index;
		} catch (...) {
			return BW_ERR_ASSET_LOAD_FAILED;
		}
	}

	try {
		bw_render_util::decode_megatile(b->terrain, (size_t)megatile_index, out_pixels);
		return BW_OK;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

static unit_t* resolve_unit(action_functions& f, int32_t unit_id_raw) {
	if (unit_id_raw == 0) return nullptr;
	return f.get_unit(unit_id_32((uint32_t)unit_id_raw));
}

int32_t bw_bridge_pick_unit_at(bw_bridge_t* bridge, int x, int y) {
	if (!bridge) return 0;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return 0;
	try {
		action_functions f = b->actions();
		xy pos{x, y};
		// find_units_noexpand's spatial index is a sweep list keyed on each
		// unit's left edge, so a point-sized query only matches units whose
		// left edge happens to fall inside it — a building's left edge can
		// be far from a click in its middle. Widen the query by the map's
		// largest unit size (mirrors OpenBW's own ui.h::select_get_unit_at),
		// then narrow down to an actual bounding-box hit ourselves below.
		rect area{pos - xy(16, 16), pos + xy(16, 16)};
		area.to.x += (int)f.game_st.max_unit_width;
		area.to.y += (int)f.game_st.max_unit_height;

		unit_t* best = nullptr;
		size_t best_area = 0;
		for (unit_t* u : f.find_units_noexpand(area)) {
			if (f.unit_dead(u)) continue;
			sprite_t* sprite = u->sprite;
			if (!sprite) continue;
			int left = sprite->position.x - (int)(sprite->width / 2);
			int right = left + (int)sprite->width;
			int top = sprite->position.y - (int)(sprite->height / 2);
			int bottom = top + (int)sprite->height;
			if (x < left || x >= right || y < top || y >= bottom) continue;
			size_t area_px = sprite->width * sprite->height;
			if (!best || area_px < best_area) {
				best = u;
				best_area = area_px;
			}
		}
		return best ? (int32_t)f.get_unit_id_32(best).raw_value : 0;
	} catch (...) {
		return 0;
	}
}

bw_status bw_bridge_select_units(bw_bridge_t* bridge, int owner, const int32_t* unit_ids, int count) {
	if (!bridge || (!unit_ids && count > 0) || owner < 0 || owner > 11) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return BW_ERR_NO_GAME;
	try {
		action_functions f = b->actions();
		a_vector<unit_t*> units;
		for (int i = 0; i != count; ++i) {
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
	if (!bridge || !out_unit_ids || owner < 0 || owner > 11) return -1;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return -1;
	try {
		action_functions f = b->actions();
		auto& selection = b->action_st.selection.at(owner);
		int n = 0;
		for (unit_t* u : selection) {
			if (n >= max_count) break;
			out_unit_ids[n++] = (int32_t)f.get_unit_id_32(u).raw_value;
		}
		return n;
	} catch (...) {
		return -1;
	}
}

bw_status bw_bridge_order_move(bw_bridge_t* bridge, int owner, int x, int y, int queue) {
	if (!bridge || owner < 0 || owner > 11) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return BW_ERR_NO_GAME;
	try {
		action_functions f = b->actions();
		const order_type_t* move = f.get_order_type(Orders::Move);
		f.action_order(owner, move, xy(x, y), nullptr, nullptr, queue != 0);
		return BW_OK;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

bw_status bw_bridge_order_right_click(bw_bridge_t* bridge, int owner, int x, int y, int32_t target_unit_id, int queue) {
	if (!bridge || owner < 0 || owner > 11) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return BW_ERR_NO_GAME;
	try {
		action_functions f = b->actions();
		unit_t* target = resolve_unit(f, target_unit_id);
		const order_type_t* order;
		if (!target) {
			order = f.get_order_type(Orders::Move);
		} else if (f.unit_is_mineral_field(target) || f.unit_is(target, UnitTypes::Resource_Vespene_Geyser)) {
			order = f.get_order_type(Orders::Harvest1);
		} else if (target->owner == owner) {
			order = f.get_order_type(Orders::Follow);
		} else {
			order = f.get_order_type(Orders::AttackUnit);
		}
		const unit_type_t* target_unit_type = target ? target->unit_type : nullptr;
		f.action_order(owner, order, xy(x, y), target, target_unit_type, queue != 0);
		return BW_OK;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

bw_status bw_bridge_order_stop(bw_bridge_t* bridge, int owner, int queue) {
	if (!bridge || owner < 0 || owner > 11) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return BW_ERR_NO_GAME;
	try {
		b->actions().action_stop(owner, queue != 0);
		return BW_OK;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}

bw_status bw_bridge_train(bw_bridge_t* bridge, int owner, int unit_type_id) {
	if (!bridge || owner < 0 || owner > 11 || unit_type_id < 0) return BW_ERR_INVALID_ARGUMENT;
	bw_bridge* b = reinterpret_cast<bw_bridge*>(bridge);
	if (!b->game_started || !b->player) return BW_ERR_NO_GAME;
	try {
		action_functions f = b->actions();
		const unit_type_t* unit_type = f.get_unit_type((UnitTypes)unit_type_id);
		f.action_train(owner, unit_type);
		return BW_OK;
	} catch (...) {
		return BW_ERR_UNKNOWN;
	}
}
