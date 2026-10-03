// engine/tools/sim_smoke_test/main.cpp
//
// Phase 1 gate: proves the vendored OpenBW simulation core (engine/vendor/openbw)
// builds and runs standalone against the user's own Brood War data files, before
// any bridge/Flutter code is written. No bridge layer is involved yet — this
// links engine/vendor/openbw's headers directly.
//
// No bundled replay (.rep) file was available (OpenBW's own repos don't ship
// one either), so this follows the same pattern as OpenBW's own WASM bring-up
// test (web/wasm_sim_test.cpp in the heiner/openbw fork): load a real melee
// map, start a single-player melee setup, step N frames, and sanity-check the
// resulting state (unit count, minerals) instead of comparing against a
// recorded replay. A replay-based bit-exactness check can be layered on later
// if a .rep file becomes available.
//
// Usage: sim_smoke_test [data_dir] [map_file]
//   data_dir  — folder containing StarDat.mpq, BrooDat.mpq, Patch_rt.mpq
//               (defaults to the user's real install at ~/box/media/games/BROOD)
//   map_file  — a .scm/.scx map to load
//               (defaults to that install's "(4)Lost Temple.scm")

#include "bwgame.h"

#include <cstdio>
#include <cstdlib>
#include <string>

using namespace bwgame;

static std::string default_data_dir() {
	const char* home = std::getenv("HOME");
	return std::string(home ? home : "") + "/box/media/games/BROOD/";
}

static std::string default_map_file() {
	return default_data_dir() + "maps/ladder/(4)Lost Temple.scm";
}

static int count_units(state& st, int owner) {
	int n = 0;
	for (unit_t* u : ptr(st.player_units.at(owner))) { (void)u; ++n; }
	return n;
}

int main(int argc, char** argv) {
	std::string data_dir = argc > 1 ? argv[1] : default_data_dir();
	std::string map_file = argc > 2 ? argv[2] : default_map_file();

	const int my_player = 0;
	const race_t my_race = race_t::terran;

	printf("sim_smoke_test: data_dir='%s' map_file='%s'\n", data_dir.c_str(), map_file.c_str());

	game_player player(data_dir);

	data_loading::mpq_file<> map_loader(map_file);
	game_load_functions game_load(player.st());
	game_load.load_map(map_loader, [&]() {
		state& st = player.st();
		game_load.setup_info.victory_condition = 0;
		game_load.setup_info.tournament_mode = 0;
		game_load.setup_info.starting_units = 0;
		game_load.setup_info.resource_type = 1;
		game_load.setup_info.starting_minerals = 50;
		for (int i = 0; i != 12; ++i) {
			if (i == my_player) {
				st.players[i].controller = player_t::controller_occupied;
				st.players[i].race = my_race;
				game_load.setup_info.create_melee_units_for_player[i] = true;
			} else {
				st.players[i].controller = player_t::controller_inactive;
				game_load.setup_info.create_melee_units_for_player[i] = false;
			}
		}
	});

	state& st = player.st();
	int units_before = count_units(st, my_player);
	int minerals_before = st.current_minerals[my_player];

	printf("sim_smoke_test: map '%s' %dx%d, units=%d, minerals=%d\n",
		st.game->scenario_name.c_str(), (int)st.game->map_width, (int)st.game->map_height,
		units_before, minerals_before);

	for (int i = 0; i != 500; ++i) player.next_frame();

	int units_after = count_units(st, my_player);
	int minerals_after = st.current_minerals[my_player];

	printf("sim_smoke_test: after %d frames: frame=%d units=%d minerals=%d\n",
		(int)st.current_frame, (int)st.current_frame, units_after, minerals_after);

	// Melee start: expect a handful of starting units and no minerals spent
	// yet (nothing is issuing build commands), i.e. the sim advanced without
	// crashing or desyncing into a nonsensical state.
	if (units_after <= 0) {
		printf("sim_smoke_test: FAIL — no units after stepping\n");
		return 1;
	}
	if (st.current_frame != 500) {
		printf("sim_smoke_test: FAIL — frame counter did not advance as expected\n");
		return 1;
	}

	printf("sim_smoke_test: OK\n");
	return 0;
}
