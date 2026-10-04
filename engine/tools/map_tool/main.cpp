// engine/tools/map_tool/main.cpp
//
// Reads a Brood War map with OpenBW for tool/make_island_map.py:
//
//   map_tool extract <map.scm> <out.chk>
//       the map's scenario data (staredit\scenario.chk), raw
//   map_tool info <data_dir> <map.scm> <out.json>
//       the map as the engine loads it: size, tileset, every tile's
//       graphics id (MTXM) and flags (walkable, height...), the tileset's
//       tile groups, the start locations and the resources.

#include "bwgame.h"

#include <cstdio>
#include <string>

using namespace bwgame;

static int extract(const std::string& map, const std::string& out) {
	data_loading::mpq_file<> mpq(map);
	a_vector<uint8_t> data;
	mpq(data, "staredit\\scenario.chk");
	FILE* f = std::fopen(out.c_str(), "wb");
	if (!f) return 1;
	std::fwrite(data.data(), 1, data.size(), f);
	std::fclose(f);
	return 0;
}

static int info(const std::string& data_dir, const std::string& map, const std::string& out) {
	game_player player(data_dir);
	data_loading::mpq_file<> map_loader(map);
	game_load_functions game_load(player.st());
	game_load.load_map(map_loader, [&]() {
		state& st = player.st();
		for (int i = 0; i != 12; ++i) st.players[i].controller = player_t::controller_inactive;
	});
	state& st = player.st();
	const game_state& g = *st.game;
	FILE* f = std::fopen(out.c_str(), "w");
	if (!f) return 1;
	std::fprintf(f, "{\"width\":%d,\"height\":%d,\"tileset\":%d,\n", (int)g.map_tile_width, (int)g.map_tile_height, (int)g.tileset_index);
	std::fprintf(f, "\"tiles\":[");
	for (size_t i = 0; i != g.gfx_tiles.size(); ++i) std::fprintf(f, "%s[%d,%d]", i ? "," : "", (int)g.gfx_tiles[i].raw_value, (int)st.tiles[i].flags);
	std::fprintf(f, "],\n\"groups\":[");
	for (size_t i = 0; i != g.cv5.size(); ++i) {
		auto& e = g.cv5[i];
		std::fprintf(f, "%s[%d", i ? "," : "", (int)e.flags);
		for (size_t k = 0; k != 16; ++k) std::fprintf(f, ",%d", (int)g.mega_tile_flags.at(e.mega_tile_index[k]));
		std::fprintf(f, "]");
	}
	std::fprintf(f, "],\n\"starts\":[");
	bool first = true;
	for (size_t i = 0; i != g.start_locations.size(); ++i) {
		xy p = g.start_locations[i];
		if (p == xy()) continue;
		std::fprintf(f, "%s[%d,%d,%d]", first ? "" : ",", (int)i, p.x, p.y);
		first = false;
	}
	std::fprintf(f, "],\n\"resources\":[");
	first = true;
	for (unit_t* u : ptr(st.visible_units)) {
		if (!u->unit_type) continue;
		int t = (int)u->unit_type->id;
		if (t != 176 && t != 177 && t != 178 && t != 188) continue;
		std::fprintf(f, "%s[%d,%d,%d]", first ? "" : ",", t, u->sprite->position.x, u->sprite->position.y);
		first = false;
	}
	std::fprintf(f, "]}\n");
	std::fclose(f);
	return 0;
}

int main(int argc, char** argv) {
	try {
		std::string cmd = argc > 1 ? argv[1] : "";
		if (cmd == "extract" && argc == 4) return extract(argv[2], argv[3]);
		if (cmd == "info" && argc == 5) return info(argv[2], argv[3], argv[4]);
		std::fprintf(stderr, "usage: map_tool extract <map> <out.chk> | info <data_dir> <map> <out.json>\n");
		return 2;
	} catch (std::exception& e) {
		std::fprintf(stderr, "map_tool: %s\n", e.what());
		return 1;
	}
}
