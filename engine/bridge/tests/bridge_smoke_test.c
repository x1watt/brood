/* engine/bridge/tests/bridge_smoke_test.c
 *
 * Plain C on purpose: proves bw_bridge.h is callable from C, which is what
 * dart:ffi binds against. Beyond "doesn't crash", this plays the opening of
 * a real game through the bridge and checks the outcomes a player would
 * see: workers mine (minerals go up), an SCV trains, a Supply Depot gets
 * placed and constructed, the draw list is ordered and positioned sanely.
 *
 * Usage: bridge_smoke_test [data_dir] [map_file]
 */

#include "bw_bridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CHECK(cond, ...) do { if (!(cond)) { printf("bridge_smoke_test: FAIL - " __VA_ARGS__); printf("\n"); exit(1); } } while (0)

enum { TERRAN_SCV = 7, TERRAN_COMMAND_CENTER = 106, TERRAN_SUPPLY_DEPOT = 109 };

static bw_unit_info units[4096];
static bw_draw_item items[16384];

static int find_units(bw_bridge_t* b, int owner, int type, int32_t* out, int max) {
	int n = bw_bridge_get_units(b, units, 4096), k = 0;
	for (int i = 0; i != n && k < max; ++i) {
		if (units[i].owner == owner && units[i].unit_type_id == type) out[k++] = units[i].unit_id;
	}
	return k;
}

static int nearest_place(bw_bridge_t* b, int me, int type, int cx, int cy, int min_r, int* tx, int* ty) {
	for (int r = min_r; r < 18; ++r)
		for (int dy = -r; dy <= r; ++dy)
			for (int dx = -r; dx <= r; ++dx)
				if (bw_bridge_can_place(b, me, type, cx / 32 + dx, cy / 32 + dy)) {
					*tx = cx / 32 + dx;
					*ty = cy / 32 + dy;
					return 1;
				}
	return 0;
}

static int wait_for_completed(bw_bridge_t* b, int me, int type, int max_frames, int32_t* out_id) {
	for (int i = 0; i != max_frames; ++i) {
		bw_bridge_step(b, 1);
		int n = bw_bridge_get_units(b, units, 4096);
		for (int k = 0; k != n; ++k) {
			if (units[k].owner == me && units[k].unit_type_id == type && (units[k].flags & BW_UNIT_FLAG_COMPLETED)) {
				if (out_id) *out_id = units[k].unit_id;
				return 1;
			}
		}
	}
	return 0;
}

static void send_workers_mining(bw_bridge_t* b, int me, int worker_type) {
	int32_t workers[8];
	int nw = find_units(b, me, worker_type, workers, 8);
	int n = bw_bridge_get_units(b, units, 4096);
	for (int w = 0; w != nw; ++w) {
		bw_unit_info wi;
		bw_bridge_get_unit(b, workers[w], &wi);
		int best = -1;
		long best_d = 0;
		for (int i = 0; i != n; ++i) {
			if (units[i].unit_type_id < 176 || units[i].unit_type_id > 178) continue;
			long dx = units[i].x - wi.x, dy = units[i].y - wi.y, d = dx * dx + dy * dy;
			if (best < 0 || d < best_d) { best = i; best_d = d; }
		}
		if (best < 0) continue;
		bw_bridge_select_units(b, me, &workers[w], 1);
		bw_bridge_order(b, me, BW_ORDER_DEFAULT, units[best].x, units[best].y, units[best].unit_id, 0);
	}
}

/* Protoss: Pylon, then a powered Gateway, then a Zealot. */
static void test_protoss(const char* dd, const char* mf) {
	enum { PROBE = 64, NEXUS = 154, PYLON = 156, GATEWAY = 160, ZEALOT = 65 };
	const int me = 0;
	bw_bridge_t* b = bw_bridge_create();
	CHECK(bw_bridge_load_assets(b, dd) == BW_OK && bw_bridge_new_melee_game(b, mf, me, 2) == BW_OK, "protoss game");
	bw_bridge_step(b, 1);
	send_workers_mining(b, me, PROBE);
	bw_bridge_step(b, 24 * 40);
	int32_t probes[4], nexus[1];
	CHECK(find_units(b, me, PROBE, probes, 4) == 4 && find_units(b, me, NEXUS, nexus, 1) == 1, "protoss start units");
	bw_unit_info nx;
	bw_bridge_get_unit(b, nexus[0], &nx);
	int tx, ty;
	bw_bridge_select_units(b, me, &probes[0], 1);
	CHECK(nearest_place(b, me, PYLON, nx.x, nx.y, 4, &tx, &ty) && bw_bridge_build(b, me, PYLON, tx, ty) == BW_OK, "place pylon");
	int32_t pylon;
	printf("bridge_smoke_test: protoss minerals=%d pylon tile %d,%d\n", bw_bridge_minerals(b, me), tx, ty);
	if (!wait_for_completed(b, me, PYLON, 24 * 60, &pylon)) {
		int32_t any[2];
		bw_unit_info pr;
		bw_bridge_get_unit(b, probes[0], &pr);
		printf("bridge_smoke_test: pylons=%d minerals=%d probe at %d,%d\n", find_units(b, me, PYLON, any, 2), bw_bridge_minerals(b, me), pr.x, pr.y);
		CHECK(0, "pylon never completed");
	}
	bw_unit_info py;
	bw_bridge_get_unit(b, pylon, &py);
	{
		/* Psi field: hidden normally, drawn when asked for (placing a powered building).
		 * The pylon creates it with its first order after completing. */
		bw_bridge_step(b, 24);
		int psi_off = 0, psi_on = 0, mod = -1, img = -1;
		int n = bw_bridge_get_draw_list(b, me, py.x - 320, py.y - 240, 640, 480, items, 16384);
		for (int i = 0; i != n; ++i) if (items[i].image_type_id >= 584 && items[i].image_type_id <= 587) ++psi_off;
		bw_bridge_show_psi_fields(b, me);
		n = bw_bridge_get_draw_list(b, me, py.x - 320, py.y - 240, 640, 480, items, 16384);
		for (int i = 0; i != n; ++i) if (items[i].image_type_id >= 584 && items[i].image_type_id <= 587) {
			++psi_on; mod = items[i].modifier; img = items[i].image_type_id;
			/* Quarters surround the pylon: two left of it, two right. */
			CHECK(items[i].flipped ? items[i].x < py.x : items[i].x >= py.x, "psi quarter %d on the wrong side", items[i].image_type_id);
		}
		bw_bridge_show_psi_fields(b, -1);
		printf("bridge_smoke_test: psi field images hidden=%d shown=%d (image %d, modifier %d)\n", psi_off, psi_on, img, mod);
		CHECK(psi_off == 0 && psi_on > 0, "psi field visibility");
	}
	bw_bridge_step(b, 24 * 20);
	bw_bridge_select_units(b, me, &probes[1], 1);
	CHECK(nearest_place(b, me, GATEWAY, py.x, py.y, 2, &tx, &ty) && bw_bridge_build(b, me, GATEWAY, tx, ty) == BW_OK, "place gateway (needs pylon power)");
	int32_t gate;
	CHECK(wait_for_completed(b, me, GATEWAY, 24 * 90, &gate), "gateway never completed");
	bw_bridge_step(b, 24 * 10);
	CHECK(bw_bridge_select_units(b, me, &gate, 1) == BW_OK && bw_bridge_train(b, me, ZEALOT) == BW_OK, "train zealot");
	CHECK(wait_for_completed(b, me, ZEALOT, 24 * 40, NULL), "zealot never appeared");
	printf("bridge_smoke_test: protoss pylon -> gateway -> zealot OK\n");
	bw_bridge_destroy(b);
}

/* Zerg: larvae morph into a Drone; a Drone becomes a Spawning Pool on creep. */
static void test_zerg(const char* dd, const char* mf) {
	enum { DRONE = 41, LARVA = 35, HATCHERY = 131, POOL = 142 };
	const int me = 0;
	bw_bridge_t* b = bw_bridge_create();
	CHECK(bw_bridge_load_assets(b, dd) == BW_OK && bw_bridge_new_melee_game(b, mf, me, 0) == BW_OK, "zerg game");
	bw_bridge_step(b, 1);
	send_workers_mining(b, me, DRONE);
	bw_bridge_step(b, 24 * 20);
	int32_t larvae[4], drones[8], hatch[1];
	int nl = find_units(b, me, LARVA, larvae, 4);
	CHECK(nl > 0, "no larvae");
	CHECK(find_units(b, me, HATCHERY, hatch, 1) == 1, "no hatchery");
	int drones_before = find_units(b, me, DRONE, drones, 8);
	CHECK(bw_bridge_select_units(b, me, larvae, 1) == BW_OK && bw_bridge_train(b, me, DRONE) == BW_OK, "larva morph to drone");
	bw_bridge_step(b, 24 * 25);
	int drones_after = find_units(b, me, DRONE, drones, 8);
	CHECK(drones_after == drones_before + 1, "drone count %d -> %d", drones_before, drones_after);
	bw_bridge_step(b, 24 * 40);
	bw_unit_info h;
	bw_bridge_get_unit(b, hatch[0], &h);
	int tx, ty;
	bw_bridge_select_units(b, me, &drones[0], 1);
	CHECK(nearest_place(b, me, POOL, h.x, h.y, 3, &tx, &ty) && bw_bridge_build(b, me, POOL, tx, ty) == BW_OK, "place spawning pool on creep");
	int32_t pools[1];
	int started = 0;
	for (int i = 0; i != 24 * 20 && !started; ++i) {
		bw_bridge_step(b, 1);
		started = find_units(b, me, POOL, pools, 1);
	}
	CHECK(started, "spawning pool never started");
	printf("bridge_smoke_test: zerg larva -> drone, drone -> spawning pool OK\n");
	bw_bridge_destroy(b);
}


/* Hash of everything the player can observe, to compare two runs. */
static unsigned long long state_hash(bw_bridge_t* b) {
	bw_bridge_set_viewer(b, -1);
	int n = bw_bridge_get_units(b, units, 4096);
	unsigned long long h = 1469598103934665603ull;
#define MIX(v) (h = (h ^ (unsigned long long)(unsigned)(v)) * 1099511628211ull)
	for (int i = 0; i != n; ++i) {
		MIX(units[i].unit_type_id); MIX(units[i].owner); MIX(units[i].x); MIX(units[i].y); MIX(units[i].hp);
	}
	for (int p = 0; p != 8; ++p) { MIX(bw_bridge_minerals(b, p)); MIX(bw_bridge_gas(b, p)); }
	MIX(bw_bridge_current_frame(b));
#undef MIX
	return h;
}

static int count_owned(bw_bridge_t* b, int owner, int* workers, int* buildings, int* army) {
	int n = bw_bridge_get_units(b, units, 4096), total = 0;
	*workers = *buildings = *army = 0;
	for (int i = 0; i != n; ++i) {
		if (units[i].owner != owner) continue;
		++total;
		int t = units[i].unit_type_id;
		if (t == TERRAN_SCV || t == 64 || t == 41) ++*workers;
		else if (units[i].flags & BW_UNIT_FLAG_BUILDING) ++*buildings;
		else if (t != 35 && t != 42 && t != 36) ++*army; /* not larva, overlord, egg */
	}
	return total;
}

/* Computer opponents play one game: `teams` gives each player's team
 * (human first). Returns the minute the game was decided, or -1. */
static int play_ai_game(const char* dd, const char* mf, const int* teams, uint32_t seed, int max_minutes, int* out_states) {
	bw_bridge_t* b = bw_bridge_create();
	CHECK(b && bw_bridge_load_assets(b, dd) == BW_OK, "ai: load");
	bw_game_setup setup;
	memset(&setup, 0, sizeof(setup));
	setup.player_count = 4;
	setup.controller[0] = BW_PLAYER_HUMAN; setup.race[0] = 1;
	for (int i = 1; i != 4; ++i) { setup.controller[i] = BW_PLAYER_COMPUTER; setup.race[i] = i - 1; }
	for (int i = 0; i != 4; ++i) setup.team[i] = teams[i];
	setup.seed = seed;
	int32_t slots[8];
	CHECK(bw_bridge_new_game(b, mf, &setup, slots) == BW_OK, "ai: new_game");
	for (int i = 0; i != 4; ++i) CHECK(slots[i] >= 0 && slots[i] < 8, "ai: player %d got no slot", i);
	int decided = -1;
	clock_t t0 = clock();
	for (int minute = 1; minute <= max_minutes && decided < 0; ++minute) {
		bw_bridge_step(b, 24 * 60);
		int alive_sides = 0, last_team = -1, any_win = 0;
		for (int i = 0; i != 4; ++i) {
			int st = bw_bridge_victory_state(b, slots[i]);
			if (st >= 3) any_win = 1;
			if (st == 0 && (teams[i] == 0 || teams[i] != last_team)) { ++alive_sides; last_team = teams[i]; }
		}
		if (minute % 2 == 0 || any_win) {
			printf("bridge_smoke_test: ai: minute %2d:", minute);
			for (int i = 0; i != 4; ++i) {
				int w, bl, a, used = 0, avail = 0;
				count_owned(b, slots[i], &w, &bl, &a);
				bw_bridge_supply(b, slots[i], setup.race[i], &used, &avail);
				printf(" [%s w%d b%d a%d %d/%d m%d s%d]", i == 0 ? "you" : i == 1 ? "Z" : i == 2 ? "T" : "P", w, bl, a, used / 2, avail / 2,
				       bw_bridge_minerals(b, slots[i]), bw_bridge_victory_state(b, slots[i]));
			}
			printf("\n");
			bw_alliance_player al[8];
			bw_bridge_alliances(b, al, 8);
			printf("bridge_smoke_test: ai:   score");
			for (int i = 0; i != 4; ++i) {
				bw_alliance_player* a = &al[slots[i]];
				printf(" [g%d %s mined %lld built %d killed %d/%d (%lld) lost %d]", a->group, a->open ? "open" : "closed", (long long)a->points, a->production_score,
				       a->units_killed, a->buildings_razed, (long long)a->kill_score, a->units_lost);
			}
			printf("\n");
		}
		if (minute == 4) {
			for (int i = 1; i != 4; ++i) {
				int w, bl, a;
				count_owned(b, slots[i], &w, &bl, &a);
				if (bw_bridge_victory_state(b, slots[i]) == 0)
					CHECK(w >= 12 && bl >= 3, "ai: player %d (race %d) did not build up by 4 min (workers %d buildings %d)", i, setup.race[i], w, bl);
			}
		}
		{
			static const char* kinds[] = {"", "invited", "declined", "formed (b joined a)", "left", "open", "closed",
			                              "offers surrender (a to b)", "SURRENDERED (a to b)", "surrender refused", "vassal moved (a now serves b)"};
			bw_alliance_event ev[64];
			int n = bw_bridge_poll_alliance_events(b, ev, 64);
			for (int i = 0; i != n; ++i) {
				if (ev[i].kind == BW_ALLIANCE_OPEN || ev[i].kind == BW_ALLIANCE_CLOSED) continue;
				printf("bridge_smoke_test: ai:   %d:%02d diplomacy %s a=%d b=%d\n", ev[i].frame * 42 / 60000, ev[i].frame * 42 / 1000 % 60, kinds[ev[i].kind], ev[i].a, ev[i].b);
			}
		}
		if (any_win) decided = minute;
	}
	for (int i = 0; i != 4; ++i) out_states[i] = bw_bridge_victory_state(b, slots[i]);
	printf("bridge_smoke_test: ai: decided at minute %d (%.1fs cpu)\n", decided, (double)(clock() - t0) / CLOCKS_PER_SEC);
	bw_bridge_destroy(b);
	return decided;
}

/* Three computer players against an idle human ("all against you") must
 * win; three in a free for all must finish the game too. */
static void test_ai(const char* dd, const char* mf) {
	int states[4];
	const int all_vs_you[4] = {1, 2, 2, 2};
	int m = play_ai_game(dd, mf, all_vs_you, 12345, 30, states);
	CHECK(m > 0 && states[0] == 2, "ai: computers never defeated the idle human");
	for (int i = 1; i != 4; ++i) CHECK(states[i] >= 3, "ai: allied computer %d not victorious (%d)", i, states[i]);
	const int ffa[4] = {0, 0, 0, 0};
	m = play_ai_game(dd, mf, ffa, 999, 60, states);
	CHECK(m > 0, "ai: free for all never finished");
}

/* Saved games: the command log replayed on a fresh game reaches the same
 * state, computer player included. */
static void test_save_replay(const char* dd, const char* mf) {
	bw_game_setup setup;
	memset(&setup, 0, sizeof(setup));
	setup.player_count = 2;
	setup.controller[0] = BW_PLAYER_HUMAN; setup.race[0] = 2;
	setup.controller[1] = BW_PLAYER_COMPUTER; setup.race[1] = 0;
	setup.seed = 777;
	int32_t slots[8];
	bw_bridge_t* a = bw_bridge_create();
	CHECK(a && bw_bridge_load_assets(a, dd) == BW_OK && bw_bridge_new_game(a, mf, &setup, slots) == BW_OK, "save: game a");
	int me = slots[0];
	bw_bridge_step(a, 1);
	send_workers_mining(a, me, 64);
	bw_bridge_step(a, 24 * 60);
	int32_t nexus[1];
	CHECK(find_units(a, me, 154, nexus, 1) == 1, "save: nexus");
	for (int i = 0; i != 3; ++i) {
		bw_bridge_select_units(a, me, nexus, 1);
		bw_bridge_train(a, me, 64);
		bw_bridge_step(a, 24 * 15);
	}
	bw_bridge_step(a, 24 * 60 * 3);
	/* Fog of war from the human's eyes. */
	{
		int w, h;
		bw_bridge_get_map_tile_size(a, &w, &h);
		uint8_t* fog = (uint8_t*)malloc((size_t)(w * h));
		CHECK(bw_bridge_get_fog(a, me, fog, w * h) == BW_OK, "fog");
		int seen = 0, explored = 0, black = 0;
		for (int i = 0; i != w * h; ++i) { if (fog[i] == 2) ++seen; else if (fog[i] == 1) ++explored; else ++black; }
		printf("bridge_smoke_test: fog: %d visible, %d explored, %d unexplored tiles\n", seen, explored, black);
		CHECK(seen > 50 && black > w * h / 2, "fog looks wrong");
		free(fog);
		int all = bw_bridge_get_units(a, units, 4096);
		bw_bridge_set_viewer(a, me);
		int visible = bw_bridge_get_units(a, units, 4096);
		int enemy_seen = 0;
		for (int i = 0; i != visible; ++i) if (units[i].owner == slots[1]) ++enemy_seen;
		printf("bridge_smoke_test: fog: %d of %d units visible to the human, %d enemy\n", visible, all, enemy_seen);
		CHECK(visible < all && enemy_seen == 0, "fog: hidden units leak into the unit list");
		bw_bridge_set_viewer(a, -1);
	}
	int end_frame = bw_bridge_current_frame(a);
	unsigned long long ha = state_hash(a);
	int len = bw_bridge_command_log(a, NULL, 0);
	CHECK(len > 0, "save: empty command log");
	int32_t* log = (int32_t*)malloc((size_t)len * sizeof(int32_t));
	CHECK(bw_bridge_command_log(a, log, len) == len, "save: copy log");

	bw_bridge_t* c = bw_bridge_create();
	int32_t slots2[8];
	CHECK(c && bw_bridge_load_assets(c, dd) == BW_OK && bw_bridge_new_game(c, mf, &setup, slots2) == BW_OK, "save: game c");
	CHECK(slots2[0] == slots[0] && slots2[1] == slots[1], "save: slots differ");
	clock_t t0 = clock();
	CHECK(bw_bridge_replay_commands(c, log, len, end_frame) == BW_OK, "save: replay");
	double secs = (double)(clock() - t0) / CLOCKS_PER_SEC;
	unsigned long long hc = state_hash(c);
	printf("bridge_smoke_test: save: %d log values, replayed %d frames in %.2fs, hash %llx vs %llx\n", len, end_frame, secs, ha, hc);
	CHECK(ha == hc, "save: replayed state differs");
	CHECK(bw_bridge_command_log(c, NULL, 0) == len, "save: replayed log length differs");
	/* Both keep going identically. */
	bw_bridge_step(a, 24 * 60 * 2);
	bw_bridge_step(c, 24 * 60 * 2);
	CHECK(state_hash(a) == state_hash(c), "save: games diverge after replay");
	free(log);
	bw_bridge_destroy(a);
	bw_bridge_destroy(c);
}

static void alliance_state(bw_bridge_t* b, bw_alliance_player* out) {
	CHECK(bw_bridge_alliances(b, out, 8) == 8, "alliances query");
}

/* Alliances: invite a computer player until one accepts, then check the
 * shared treasury, commanding the ally's units, shared points, the "never
 * everyone" rule, leaving, and that it all replays from the command log. */
static void test_alliances(const char* dd, const char* mf) {
	bw_game_setup setup;
	memset(&setup, 0, sizeof(setup));
	setup.player_count = 3;
	setup.controller[0] = BW_PLAYER_HUMAN; setup.race[0] = 1;
	setup.controller[1] = BW_PLAYER_COMPUTER; setup.race[1] = 1;
	setup.controller[2] = BW_PLAYER_COMPUTER; setup.race[2] = 2;
	int32_t slots[8];
	bw_bridge_t* b = NULL;
	int me = -1, ally = -1, other = -1;
	bw_alliance_player al[8];
	for (uint32_t seed = 1; seed != 20 && ally < 0; ++seed) {
		if (b) bw_bridge_destroy(b);
		setup.seed = seed;
		b = bw_bridge_create();
		CHECK(b && bw_bridge_load_assets(b, dd) == BW_OK && bw_bridge_new_game(b, mf, &setup, slots) == BW_OK, "alliances: new game");
		me = slots[0];
		bw_bridge_step(b, 1);
		send_workers_mining(b, me, TERRAN_SCV);
		bw_bridge_step(b, 24 * 20);
		CHECK(bw_bridge_alliance_set_open(b, me, 1) == BW_OK, "alliances: open");
		for (int k = 1; k != 3 && ally < 0; ++k) {
			CHECK(bw_bridge_alliance_invite(b, me, slots[k]) == BW_OK, "alliances: invite %d", slots[k]);
			alliance_state(b, al);
			CHECK(al[slots[k]].invited_by & (1 << me), "alliances: invitation not pending");
			bw_bridge_step(b, 24 * 10);
			alliance_state(b, al);
			CHECK(!(al[slots[k]].invited_by & (1 << me)), "alliances: computer never answered");
			if (al[slots[k]].group == al[me].group) { ally = slots[k]; other = slots[3 - k]; }
		}
	}
	CHECK(ally >= 0, "alliances: no computer ever accepted");
	printf("bridge_smoke_test: alliances: seed %u, human %d allied with %d\n", setup.seed, me, ally);
	{
		bw_alliance_event ev[64];
		int n = bw_bridge_poll_alliance_events(b, ev, 64), formed = 0;
		for (int i = 0; i != n; ++i) if (ev[i].kind == BW_ALLIANCE_FORMED) formed = 1;
		CHECK(formed, "alliances: no 'formed' event");
	}
	/* Sharing resources is the human's choice and starts off: separate money,
	   then one treasury holding both once switched on, then an equal part
	   back when switched off again. */
	CHECK(bw_bridge_alliance_get_share(b, me) == 0 && bw_bridge_alliance_get_share(b, ally) == 1, "alliances: share defaults");
	{
		int mine = bw_bridge_minerals(b, me), theirs = bw_bridge_minerals(b, ally);
		CHECK(mine != theirs, "alliances: money shared without asking (%d)", mine);
		CHECK(bw_bridge_alliance_set_share(b, me, 1) == BW_OK, "alliances: share on");
		CHECK(bw_bridge_minerals(b, me) == mine + theirs && bw_bridge_minerals(b, ally) == mine + theirs, "alliances: share on: %d + %d gave %d / %d", mine, theirs, bw_bridge_minerals(b, me), bw_bridge_minerals(b, ally));
		CHECK(bw_bridge_alliance_set_share(b, me, 0) == BW_OK, "alliances: share off");
		int total = mine + theirs;
		CHECK(bw_bridge_minerals(b, me) + bw_bridge_minerals(b, ally) == total && bw_bridge_minerals(b, me) >= total / 2 - 1, "alliances: share off split %d / %d", bw_bridge_minerals(b, me), bw_bridge_minerals(b, ally));
		printf("bridge_smoke_test: alliances: share resources %d + %d -> pooled -> %d / %d\n", mine, theirs, bw_bridge_minerals(b, me), bw_bridge_minerals(b, ally));
		CHECK(bw_bridge_alliance_set_share(b, me, 1) == BW_OK, "alliances: share on again");
	}
	/* One treasury. */
	CHECK(bw_bridge_minerals(b, me) == bw_bridge_minerals(b, ally) && bw_bridge_gas(b, me) == bw_bridge_gas(b, ally), "alliances: treasury not shared (%d vs %d)", bw_bridge_minerals(b, me), bw_bridge_minerals(b, ally));
	int32_t cc[1];
	CHECK(find_units(b, me, TERRAN_COMMAND_CENTER, cc, 1) == 1, "alliances: cc");
	for (int i = 0; i != 24 * 60 && bw_bridge_minerals(b, me) < 50; ++i) bw_bridge_step(b, 1);
	int before = bw_bridge_minerals(b, me);
	bw_bridge_select_units(b, me, cc, 1);
	if (bw_bridge_train(b, me, TERRAN_SCV) == BW_OK) {
		bw_bridge_step(b, 1);
		printf("bridge_smoke_test: alliances: trained an SCV, treasury %d -> %d (ally sees %d)\n", before, bw_bridge_minerals(b, me), bw_bridge_minerals(b, ally));
		CHECK(bw_bridge_minerals(b, me) == bw_bridge_minerals(b, ally), "alliances: spending not shared");
	}
	/* "Never everyone": with the third player in, nobody would be left. */
	CHECK(bw_bridge_alliance_invite(b, me, other) == BW_ERR_REJECTED, "alliances: an alliance of everyone was allowed");
	/* Command the ally's worker. */
	{
		int n = bw_bridge_get_units(b, units, 4096);
		int32_t worker = 0;
		bw_unit_info w0;
		/* (An SCV busy constructing refuses orders, as in the original.) */
		for (int i = 0; i != n && !worker; ++i) {
			if (units[i].owner != ally || !(units[i].flags & BW_UNIT_FLAG_WORKER)) continue;
			CHECK(bw_bridge_select_units(b, me, &units[i].unit_id, 1) == BW_OK, "alliances: select ally worker");
			if (bw_bridge_order(b, me, BW_ORDER_MOVE, units[i].x + 160, units[i].y, 0, 0) == BW_OK) { worker = units[i].unit_id; w0 = units[i]; }
		}
		CHECK(worker, "alliances: no ally worker took the order");
		bw_bridge_step(b, 24 * 4);
		bw_unit_info w1;
		bw_bridge_get_unit(b, worker, &w1);
		int moved = abs(w1.x - w0.x) + abs(w1.y - w0.y);
		printf("bridge_smoke_test: alliances: ally's worker moved %d px on the human's order\n", moved);
		CHECK(moved > 40, "alliances: ally's worker ignored the order");
		/* Control groups hold allied units too. */
		CHECK(bw_bridge_control_group(b, me, 5, BW_GROUP_ASSIGN) == BW_OK, "alliances: group ally unit");
		bw_bridge_select_units(b, me, NULL, 0);
		CHECK(bw_bridge_control_group(b, me, 5, BW_GROUP_RECALL) == BW_OK, "alliances: recall ally unit");
		/* Enemy units can't be commanded. */
		for (int i = 0; i != n; ++i) {
			if (units[i].owner == other && (units[i].flags & BW_UNIT_FLAG_WORKER)) {
				bw_bridge_select_units(b, me, &units[i].unit_id, 1);
				CHECK(bw_bridge_order(b, me, BW_ORDER_MOVE, units[i].x + 160, units[i].y, 0, 0) != BW_OK, "alliances: commanded an enemy unit");
				break;
			}
		}
	}
	/* The computer ally never moves the human's units: stop one SCV and
	 * check it stays put for a minute. */
	{
		int32_t scv[1];
		CHECK(find_units(b, me, TERRAN_SCV, scv, 1) == 1, "alliances: human scv");
		bw_unit_info c0;
		bw_bridge_get_unit(b, cc[0], &c0);
		int mw, mh;
		bw_bridge_get_map_tile_size(b, &mw, &mh);
		/* Away from the mineral line, toward the middle of the map. */
		int px = c0.x + (mw * 16 > c0.x ? 320 : -320), py = c0.y + (mh * 16 > c0.y ? 320 : -320);
		bw_bridge_select_units(b, me, scv, 1);
		bw_bridge_order(b, me, BW_ORDER_MOVE, px, py, 0, 0);
		bw_bridge_step(b, 24 * 15);
		bw_unit_info s0, s1;
		bw_bridge_get_unit(b, scv[0], &s0);
		bw_bridge_step(b, 24 * 60);
		bw_bridge_get_unit(b, scv[0], &s1);
		printf("bridge_smoke_test: alliances: scv %d,%d -> %d,%d\n", s0.x, s0.y, s1.x, s1.y);
		CHECK(s0.x == s1.x && s0.y == s1.y, "alliances: the computer ally moved the human's unit");
		printf("bridge_smoke_test: alliances: the computer ally left the human's idle SCV alone\n");
	}
	/* Shared points: both gain the same from here on. */
	alliance_state(b, al);
	int64_t p_me = al[me].points, p_ally = al[ally].points, own_me = al[me].own_points, own_ally = al[ally].own_points;
	bw_bridge_step(b, 24 * 60);
	alliance_state(b, al);
	long long gain_me = (long long)(al[me].points - p_me), gain_ally = (long long)(al[ally].points - p_ally);
	long long mined = (long long)(al[me].own_points - own_me + al[ally].own_points - own_ally);
	printf("bridge_smoke_test: alliances: points +%lld / +%lld, mined together %lld\n", gain_me, gain_ally, mined);
	CHECK(gain_me == gain_ally && gain_me == mined && mined > 0, "alliances: points not shared");
	/* Leaving splits the treasury. */
	int pool = bw_bridge_minerals(b, me);
	CHECK(bw_bridge_alliance_leave(b, me) == BW_OK, "alliances: leave");
	alliance_state(b, al);
	CHECK(al[me].group != al[ally].group, "alliances: still allied after leaving");
	CHECK(bw_bridge_minerals(b, me) + bw_bridge_minerals(b, ally) == pool, "alliances: split %d + %d != %d", bw_bridge_minerals(b, me), bw_bridge_minerals(b, ally), pool);
	bw_bridge_step(b, 24 * 30);

	/* Replays exactly. */
	int end_frame = bw_bridge_current_frame(b);
	unsigned long long h = state_hash(b);
	alliance_state(b, al);
	int len = bw_bridge_command_log(b, NULL, 0);
	int32_t* log = (int32_t*)malloc((size_t)len * sizeof(int32_t));
	bw_bridge_command_log(b, log, len);
	bw_bridge_t* c = bw_bridge_create();
	int32_t slots2[8];
	CHECK(c && bw_bridge_load_assets(c, dd) == BW_OK && bw_bridge_new_game(c, mf, &setup, slots2) == BW_OK, "alliances: replay game");
	CHECK(bw_bridge_replay_commands(c, log, len, end_frame) == BW_OK, "alliances: replay");
	CHECK(state_hash(c) == h, "alliances: replay diverged");
	bw_alliance_player al2[8];
	alliance_state(c, al2);
	for (int p = 0; p != 8; ++p) CHECK(al2[p].points == al[p].points && al2[p].group == al[p].group, "alliances: replayed alliances differ");
	printf("bridge_smoke_test: alliances: replay matches\n");
	free(log);
	bw_bridge_destroy(c);
	bw_bridge_destroy(b);
}

/* Surrender: a computer surrenders to the human (both sides driven through
 * the API), is locked in, pays half its mining to its lord; then the human
 * surrenders to the other computer and the vassal passes along. */
static void test_surrender(const char* dd, const char* mf) {
	bw_game_setup setup;
	memset(&setup, 0, sizeof(setup));
	setup.player_count = 3;
	setup.controller[0] = BW_PLAYER_HUMAN; setup.race[0] = 1;
	setup.controller[1] = BW_PLAYER_COMPUTER; setup.race[1] = 1;
	setup.controller[2] = BW_PLAYER_COMPUTER; setup.race[2] = 2;
	setup.seed = 4242;
	int32_t slots[8];
	bw_bridge_t* b = bw_bridge_create();
	CHECK(b && bw_bridge_load_assets(b, dd) == BW_OK && bw_bridge_new_game(b, mf, &setup, slots) == BW_OK, "surrender: new game");
	int me = slots[0], x = slots[1], z = slots[2];
	bw_bridge_step(b, 1);
	send_workers_mining(b, me, TERRAN_SCV);
	bw_bridge_step(b, 24 * 30);
	CHECK(bw_bridge_alliance_surrender(b, x, me) == BW_OK, "surrender: offer");
	bw_alliance_player al[8];
	alliance_state(b, al);
	CHECK(al[me].surrender_from & (1 << x), "surrender: offer not pending");
	CHECK(bw_bridge_alliance_answer_surrender(b, me, x, 1) == BW_OK, "surrender: accept");
	alliance_state(b, al);
	CHECK(al[x].lord == me && al[x].group == al[me].group, "surrender: not a vassal (lord %d)", al[x].lord);
	CHECK(al[me].name >= 0, "surrender: the new alliance has no name");
	CHECK(bw_bridge_alliance_set_share(b, me, 1) == BW_OK, "surrender: share on");
	CHECK(bw_bridge_minerals(b, x) == bw_bridge_minerals(b, me), "surrender: treasury not shared");
	CHECK(bw_bridge_alliance_leave(b, x) == BW_ERR_REJECTED, "surrender: a vassal left");
	CHECK(bw_bridge_alliance_invite(b, x, z) == BW_ERR_REJECTED, "surrender: a vassal invited");
	CHECK(bw_bridge_alliance_invite(b, z, x) == BW_ERR_REJECTED, "surrender: a vassal was invited");
	/* Tribute: the vassal keeps half its mining, the lord gets the rest. */
	int64_t px = al[x].points, pm = al[me].points, ox = al[x].own_points, om = al[me].own_points;
	bw_bridge_step(b, 24 * 60);
	alliance_state(b, al);
	long long vassal_gain = (long long)(al[x].points - px), vassal_mined = (long long)(al[x].own_points - ox);
	long long lord_gain = (long long)(al[me].points - pm), lord_mined = (long long)(al[me].own_points - om);
	printf("bridge_smoke_test: surrender: vassal mined %lld kept %lld; lord mined %lld gained %lld\n", vassal_mined, vassal_gain, lord_mined, lord_gain);
	CHECK(vassal_mined > 0 && vassal_gain * 2 <= vassal_mined + 30 && vassal_gain * 2 >= vassal_mined - 30, "surrender: vassal did not keep half");
	CHECK(lord_gain == lord_mined + vassal_mined - vassal_gain, "surrender: tribute not paid to the lord");
	printf("bridge_smoke_test: surrender: army %d/%d, mining %d+%d per minute\n", al[me].army_value, al[x].army_value, al[x].mineral_rate, al[x].gas_rate);
	CHECK(al[x].mineral_rate > 100, "surrender: mining rate not measured");
	/* The lord surrenders in turn: its vassal passes to the conqueror. */
	CHECK(bw_bridge_alliance_surrender(b, me, z) == BW_ERR_REJECTED, "surrender: allowed although nobody would be left outside");
	bw_bridge_destroy(b);

	/* Four players so someone stays outside. */
	setup.player_count = 4;
	setup.controller[3] = BW_PLAYER_COMPUTER; setup.race[3] = 0;
	b = bw_bridge_create();
	CHECK(b && bw_bridge_load_assets(b, dd) == BW_OK && bw_bridge_new_game(b, mf, &setup, slots) == BW_OK, "surrender: new game 2");
	me = slots[0]; x = slots[1]; z = slots[2];
	bw_bridge_step(b, 24 * 10);
	CHECK(bw_bridge_alliance_surrender(b, x, me) == BW_OK && bw_bridge_alliance_answer_surrender(b, me, x, 1) == BW_OK, "surrender: x to me");
	CHECK(bw_bridge_alliance_surrender(b, me, z) == BW_OK && bw_bridge_alliance_answer_surrender(b, z, me, 1) == BW_OK, "surrender: me to z");
	alliance_state(b, al);
	CHECK(al[me].lord == z && al[x].lord == z, "surrender: vassal did not pass to the conqueror (me %d, x %d)", al[me].lord, al[x].lord);
	CHECK(al[x].group == al[z].group, "surrender: vassal not in the conqueror's alliance");
	printf("bridge_smoke_test: surrender: vassal passed to the conqueror\n");
	bw_bridge_destroy(b);
}

/* Auto-play for the human: resources only, then building too; units kept in
 * a control group are left alone and the selection is untouched; full auto
 * holds its own against a computer player; all of it replays. */
/* Defensive mode: the human allied (setup teams) with a computer Protoss
 * and a computer Zerg switches it on. Over twelve minutes both fortify
 * their bases (cannons; spore and sunken colonies) and their armies stay
 * near home, while the enemy Terran is left alone. */
static void test_defensive(const char* dd, const char* mf) {
	enum { PROTOSS_NEXUS = 154, PROTOSS_CANNON = 162, ZERG_HATCHERY = 131, ZERG_LAIR = 132, ZERG_SUNKEN = 146, ZERG_SPORE = 144 };
	bw_game_setup setup;
	memset(&setup, 0, sizeof(setup));
	setup.player_count = 4;
	setup.controller[0] = BW_PLAYER_HUMAN; setup.race[0] = 1; setup.team[0] = 1;
	setup.controller[1] = BW_PLAYER_COMPUTER; setup.race[1] = 2; setup.team[1] = 1;
	setup.controller[2] = BW_PLAYER_COMPUTER; setup.race[2] = 0; setup.team[2] = 1;
	setup.controller[3] = BW_PLAYER_COMPUTER; setup.race[3] = 1; setup.team[3] = 2;
	setup.seed = 777;
	int32_t slots[8];
	bw_bridge_t* b = bw_bridge_create();
	CHECK(b && bw_bridge_load_assets(b, dd) == BW_OK && bw_bridge_new_game(b, mf, &setup, slots) == BW_OK, "defensive: new game");
	int me = slots[0], toss = slots[1], zerg = slots[2];
	CHECK(bw_bridge_alliance_get_defensive(b, me) == 0, "defensive: on by default");
	CHECK(bw_bridge_alliance_set_defensive(b, me, 1) == BW_OK && bw_bridge_alliance_get_defensive(b, me) == 1, "defensive: switch on");
	/* The human (in this test) keeps a base going without attacking, so it
	 * stays in the alliance; its leaving would end defensive mode. */
	CHECK(bw_bridge_set_autoplay(b, me, 1 | 2) == BW_OK, "defensive: autoplay");
	int32_t ids[64];
	/* Each minute while the human is in the game: allied units at an enemy
	 * town hall (attacking a colony), and allied units by another ally's
	 * base (helping or guarding it). */
	int enemy = slots[3], raids = 0, guarding[37] = {0};
	for (int minute = 1; minute <= 36; ++minute) { /* every 20 s, 12 minutes */
		bw_bridge_step(b, 24 * 20);
		int n = bw_bridge_get_units(b, units, 4096), human_buildings = 0;
		for (int i = 0; i != n; ++i)
			if (units[i].owner == me && (units[i].flags & BW_UNIT_FLAG_BUILDING)) ++human_buildings;
		if (human_buildings == 0) break; /* out of the alliance: defensive mode ends */
		for (int i = 0; i != n; ++i) {
			int o = units[i].owner;
			if ((o != toss && o != zerg) || (units[i].flags & (BW_UNIT_FLAG_BUILDING | BW_UNIT_FLAG_WORKER))) continue;
			for (int j = 0; j != n; ++j) {
				int oj = units[j].owner, t = units[j].unit_type_id;
				if (!(units[j].flags & BW_UNIT_FLAG_BUILDING)) continue;
				int dx = units[i].x - units[j].x, dy = units[i].y - units[j].y, d = dx * dx + dy * dy;
				if (oj == enemy && t == TERRAN_COMMAND_CENTER && d < 320 * 320) {
					++raids;
					break;
				}
				if ((oj == me || oj == toss || oj == zerg) && oj != o && d < 640 * 640) {
					++guarding[minute];
					break;
				}
			}
		}
	}
	int cannons = find_units(b, toss, PROTOSS_CANNON, ids, 64);
	int sunkens = find_units(b, zerg, ZERG_SUNKEN, ids, 64), spores = find_units(b, zerg, ZERG_SPORE, ids, 64);
	printf("bridge_smoke_test: defensive: allied units by another ally's base, every 20 s:");
	int guarded = 0;
	for (int m = 1; m <= 36; ++m) {
		printf(" %d", guarding[m]);
		guarded += guarding[m];
	}
	printf("\n");
	printf("bridge_smoke_test: defensive: after 12 min protoss %d cannons, zerg %d sunken + %d spore; samples at enemy town halls: %d\n", cannons, sunkens, spores, raids);
	CHECK(cannons >= 3, "defensive: protoss built %d cannons", cannons);
	CHECK(sunkens >= 1 && spores >= 1, "defensive: zerg built %d sunken, %d spore", sunkens, spores);
	CHECK(raids == 0, "defensive: allied units attacked enemy colonies (%d samples)", raids);
	CHECK(guarded > 0, "defensive: no ally ever came to help or guard");
	bw_bridge_destroy(b);
}

static void test_autoplay(const char* dd, const char* mf) {
	enum { BARRACKS = 111, DEPOT = 109 };
	bw_game_setup setup;
	memset(&setup, 0, sizeof(setup));
	setup.player_count = 2;
	setup.controller[0] = BW_PLAYER_HUMAN; setup.race[0] = 1; setup.team[0] = 1;
	setup.controller[1] = BW_PLAYER_COMPUTER; setup.race[1] = 1; setup.team[1] = 1; /* allied: no war while we look */
	setup.player_count = 3;
	setup.controller[2] = BW_PLAYER_COMPUTER; setup.race[2] = 2; setup.team[2] = 2;
	setup.seed = 99;
	int32_t slots[8];
	bw_bridge_t* b = bw_bridge_create();
	CHECK(b && bw_bridge_load_assets(b, dd) == BW_OK && bw_bridge_new_game(b, mf, &setup, slots) == BW_OK, "autoplay: new game");
	int me = slots[0];
	bw_bridge_step(b, 1);
	CHECK(bw_bridge_set_autoplay(b, me, BW_AUTOPLAY_RESOURCES) == BW_OK && bw_bridge_get_autoplay(b, me) == BW_AUTOPLAY_RESOURCES, "autoplay: on");
	int32_t cc[1], scvs[64];
	CHECK(find_units(b, me, TERRAN_COMMAND_CENTER, cc, 1) == 1, "autoplay: cc");
	/* Keep one SCV for ourselves: group 1, sent away. */
	CHECK(find_units(b, me, TERRAN_SCV, scvs, 64) == 4, "autoplay: scvs");
	bw_unit_info c0;
	bw_bridge_get_unit(b, cc[0], &c0);
	bw_bridge_select_units(b, me, &scvs[0], 1);
	bw_bridge_control_group(b, me, 1, BW_GROUP_ASSIGN);
	int mw, mh;
	bw_bridge_get_map_tile_size(b, &mw, &mh);
	int px = c0.x + (mw * 16 > c0.x ? 320 : -320), py = c0.y + (mh * 16 > c0.y ? 320 : -320);
	bw_bridge_order(b, me, BW_ORDER_MOVE, px, py, 0, 0);
	/* The selection we leave: the command center. */
	bw_bridge_select_units(b, me, cc, 1);
	int32_t kept_id = scvs[0];
	bw_bridge_step(b, 24 * 60 * 3);
	int n_scv = find_units(b, me, TERRAN_SCV, scvs, 64);
	int32_t tmp[8];
	int barracks = find_units(b, me, BARRACKS, tmp, 8), depots = find_units(b, me, DEPOT, tmp, 8);
	bw_unit_info kept;
	bw_bridge_get_unit(b, kept_id, &kept);
	int32_t sel[12];
	int nsel = bw_bridge_get_selected_units(b, me, sel, 12);
	printf("bridge_smoke_test: autoplay: resources mode after 3 min: %d SCVs, %d depots, %d barracks; kept SCV at %d,%d (sent to %d,%d)\n",
	       n_scv, depots, barracks, kept.x, kept.y, px, py);
	CHECK(n_scv >= 10, "autoplay: resources mode didn't train workers (%d)", n_scv);
	CHECK(barracks == 0, "autoplay: resources mode built barracks");
	CHECK(abs(kept.x - px) < 64 && abs(kept.y - py) < 64, "autoplay: the grouped SCV was taken over");
	CHECK(nsel == 1 && sel[0] == cc[0], "autoplay: the human's selection changed");
	/* Building too. */
	CHECK(bw_bridge_set_autoplay(b, me, BW_AUTOPLAY_RESOURCES | BW_AUTOPLAY_BUILDING) == BW_OK, "autoplay: building");
	bw_bridge_step(b, 24 * 60 * 3);
	barracks = find_units(b, me, BARRACKS, tmp, 8);
	printf("bridge_smoke_test: autoplay: with building, %d barracks after 3 more min\n", barracks);
	CHECK(barracks >= 1, "autoplay: building mode built nothing");
	/* Off again: nothing more happens on its own (no new workers queued). */
	CHECK(bw_bridge_set_autoplay(b, me, 0) == BW_OK && bw_bridge_get_autoplay(b, me) == 0, "autoplay: off");
	int end_frame = bw_bridge_current_frame(b);
	unsigned long long h = state_hash(b);
	int len = bw_bridge_command_log(b, NULL, 0);
	int32_t* log = (int32_t*)malloc((size_t)len * sizeof(int32_t));
	bw_bridge_command_log(b, log, len);
	bw_bridge_t* c = bw_bridge_create();
	int32_t slots2[8];
	CHECK(c && bw_bridge_load_assets(c, dd) == BW_OK && bw_bridge_new_game(c, mf, &setup, slots2) == BW_OK, "autoplay: replay game");
	CHECK(bw_bridge_replay_commands(c, log, len, end_frame) == BW_OK && state_hash(c) == h, "autoplay: replay diverged");
	printf("bridge_smoke_test: autoplay: replay matches\n");
	free(log);
	bw_bridge_destroy(c);
	bw_bridge_destroy(b);

	/* Colonizing: new bases with defences (allied with a computer, so no
	 * war distracts it). */
	for (int race = 0; race != 3; ++race) {
		static const int depot_types[3] = {131, 106, 154};
		static const int defense_types[3][2] = {{143, 146}, {124, 125}, {162, 162}}; /* creep/sunken, turret/bunker, cannon */
		memset(&setup, 0, sizeof(setup));
		setup.player_count = 3;
		setup.controller[0] = BW_PLAYER_HUMAN; setup.race[0] = race; setup.team[0] = 1;
		setup.controller[1] = BW_PLAYER_COMPUTER; setup.race[1] = 1; setup.team[1] = 1;
		setup.controller[2] = BW_PLAYER_COMPUTER; setup.race[2] = 2; setup.team[2] = 2;
		setup.seed = 31;
		b = bw_bridge_create();
		CHECK(b && bw_bridge_load_assets(b, dd) == BW_OK && bw_bridge_new_game(b, mf, &setup, slots) == BW_OK, "autoplay: colonizing game");
		bw_bridge_step(b, 1);
		CHECK(bw_bridge_set_autoplay(b, slots[0], BW_AUTOPLAY_RESOURCES | BW_AUTOPLAY_BUILDING | BW_AUTOPLAY_COLONIZING) == BW_OK, "autoplay: colonizing on");
		int32_t ids[32];
		int max_halls = 0, max_defenses = 0;
		for (int m = 1; m <= 14; ++m) {
			bw_bridge_step(b, 24 * 60);
			int h = find_units(b, slots[0], depot_types[race], ids, 32);
			int d = find_units(b, slots[0], defense_types[race][0], ids, 32);
			if (defense_types[race][1] != defense_types[race][0]) d += find_units(b, slots[0], defense_types[race][1], ids, 32);
			if (h > max_halls) max_halls = h;
			if (d > max_defenses) max_defenses = d;
		}
		printf("bridge_smoke_test: autoplay: colonizing as race %d: up to %d town halls and %d defences in 14 min\n", race, max_halls, max_defenses);
		CHECK(max_halls >= 2, "autoplay: colonizing never expanded (race %d)", race);
		CHECK(max_defenses >= 1, "autoplay: colonizing never defended a new base (race %d)", race);
		bw_bridge_destroy(b);
	}

	/* Survival first: in resources mode only, once attacked it starts
	 * production, trains an army and fights back (an idle human just falls,
	 * see test_ai). */
	{
		memset(&setup, 0, sizeof(setup));
		setup.player_count = 2;
		setup.controller[0] = BW_PLAYER_HUMAN; setup.race[0] = 1;
		setup.controller[1] = BW_PLAYER_COMPUTER; setup.race[1] = 1;
		setup.seed = 12345;
		b = bw_bridge_create();
		CHECK(b && bw_bridge_load_assets(b, dd) == BW_OK && bw_bridge_new_game(b, mf, &setup, slots) == BW_OK, "autoplay: survival game");
		bw_bridge_step(b, 1);
		CHECK(bw_bridge_set_autoplay(b, slots[0], BW_AUTOPLAY_RESOURCES) == BW_OK, "autoplay: survival on");
		int max_army = 0, fell = 0, barracks = 0;
		int32_t tmp2[8];
		bw_alliance_player al[8];
		for (int q = 1; q <= 12 * 4 && !fell; ++q) {
			int m = (q + 3) / 4;
			bw_bridge_step(b, 24 * 15);
			int w, bl, a;
			count_owned(b, slots[0], &w, &bl, &a);
			if (a > max_army) max_army = a;
			int br = find_units(b, slots[0], BARRACKS, tmp2, 8);
			if (br > barracks) barracks = br;
			if (bw_bridge_victory_state(b, slots[0]) == 2) fell = m;
		}
		alliance_state(b, al);
		printf("bridge_smoke_test: autoplay: resources mode under attack: built %d barracks, up to %d army units, destroyed %d units, %s\n", barracks, max_army,
		       al[slots[0]].units_killed, fell ? "fell" : "still standing after 12 min");
		CHECK(barracks > 0 && max_army > 0, "autoplay: resources mode didn't start defending itself");
		bw_bridge_destroy(b);
	}

	/* Full auto against a computer player, one on one. */
	memset(&setup, 0, sizeof(setup));
	setup.player_count = 2;
	setup.controller[0] = BW_PLAYER_HUMAN; setup.race[0] = 2;
	setup.controller[1] = BW_PLAYER_COMPUTER; setup.race[1] = 0;
	setup.seed = 5;
	b = bw_bridge_create();
	CHECK(b && bw_bridge_load_assets(b, dd) == BW_OK && bw_bridge_new_game(b, mf, &setup, slots) == BW_OK, "autoplay: 1v1");
	bw_bridge_step(b, 1);
	CHECK(bw_bridge_set_autoplay(b, slots[0], BW_AUTOPLAY_ALL) == BW_OK, "autoplay: all");
	int minute = 0, v0 = 0, v1 = 0;
	for (minute = 1; minute <= 40; ++minute) {
		bw_bridge_step(b, 24 * 60);
		v0 = bw_bridge_victory_state(b, slots[0]);
		v1 = bw_bridge_victory_state(b, slots[1]);
		if (v0 || v1) break;
	}
	int w, bl, a;
	count_owned(b, slots[0], &w, &bl, &a);
	printf("bridge_smoke_test: autoplay: full auto vs computer: minute %d, auto-play state %d, computer state %d (auto-play has %d workers, %d buildings)\n",
	       minute, v0, v1, w, bl);
	CHECK(v0 != 2 || minute > 12, "autoplay: full auto collapsed early");
	bw_bridge_destroy(b);
}

int main(int argc, char** argv) {
	char data_dir[1024], map_file[1100];
	const char* home = getenv("HOME");
	snprintf(data_dir, sizeof(data_dir), "%s/box/media/games/BROOD/", home ? home : "");
	snprintf(map_file, sizeof(map_file), "%smaps/ladder/(4)Lost Temple.scm", data_dir);
	const char* dd = argc > 1 ? argv[1] : data_dir;
	const char* mf = argc > 2 ? argv[2] : map_file;
	const int me = 0;

	CHECK(bw_bridge_abi_version() == BW_BRIDGE_ABI_VERSION, "abi mismatch");
	if (getenv("DEF_ONLY")) { test_defensive(dd, mf); printf("bridge_smoke_test: OK\n"); return 0; }
	bw_bridge_t* b = bw_bridge_create();
	CHECK(b, "create");
	CHECK(bw_bridge_load_assets(b, dd) == BW_OK, "load_assets(%s)", dd);
	CHECK(bw_bridge_new_melee_game(b, mf, me, 1) == BW_OK, "new_melee_game(%s)", mf);
	bw_bridge_step(b, 1);

	/* Unit type info comes from the real game data, names included. */
	bw_unit_type_info ti;
	CHECK(bw_bridge_get_unit_type_info(b, TERRAN_SCV, &ti) == BW_OK, "type info");
	printf("bridge_smoke_test: type %d = '%s' cost %d/%d\n", TERRAN_SCV, ti.name, ti.mineral_cost, ti.gas_cost);
	CHECK(strstr(ti.name, "SCV") != NULL, "unexpected SCV name '%s'", ti.name);
	CHECK(bw_bridge_get_unit_type_info(b, TERRAN_SUPPLY_DEPOT, &ti) == BW_OK && ti.is_building && ti.placement_width == 96,
	      "supply depot info (building=%d w=%d)", ti.is_building, ti.placement_width);

	int32_t scvs[8], ccs[1], minerals[64];
	int scv_count = find_units(b, me, TERRAN_SCV, scvs, 8);
	CHECK(scv_count == 4, "expected 4 starting SCVs, got %d", scv_count);
	CHECK(find_units(b, me, TERRAN_COMMAND_CENTER, ccs, 1) == 1, "no command center");
	bw_unit_info cc;
	CHECK(bw_bridge_get_unit(b, ccs[0], &cc) == BW_OK, "get cc");

	/* Draw list: ordered by the engine, positions are frame top-lefts. */
	int view_x = cc.x - 320, view_y = cc.y - 240;
	int n_items = bw_bridge_get_draw_list(b, me, view_x, view_y, 640, 480, items, 16384);
	CHECK(n_items > 0, "empty draw list");
	int shadows = 0;
	for (int i = 0; i != n_items; ++i) if (items[i].modifier == BW_MOD_SHADOW) ++shadows;
	printf("bridge_smoke_test: draw list %d items (%d shadows)\n", n_items, shadows);
	CHECK(shadows > 0, "no shadow images in view - draw list missing images?");

	/* Mining: send every SCV to the nearest mineral via the real right-click. */
	int mineral_count = 0;
	{
		int n = bw_bridge_get_units(b, units, 4096);
		for (int i = 0; i != n; ++i) {
			if ((units[i].flags & BW_UNIT_FLAG_RESOURCE) && units[i].resources > 0 && units[i].unit_type_id != 188 && mineral_count < 64) {
				minerals[mineral_count++] = units[i].unit_id;
			}
		}
	}
	CHECK(mineral_count > 0, "no mineral fields");
	for (int i = 0; i != scv_count; ++i) {
		bw_unit_info scv, best;
		bw_bridge_get_unit(b, scvs[i], &scv);
		long best_d = -1;
		for (int m = 0; m != mineral_count; ++m) {
			bw_unit_info mi;
			if (bw_bridge_get_unit(b, minerals[m], &mi) != BW_OK) continue;
			long dx = mi.x - scv.x, dy = mi.y - scv.y, d = dx * dx + dy * dy;
			if (best_d < 0 || d < best_d) { best_d = d; best = mi; }
		}
		CHECK(bw_bridge_select_units(b, me, &scvs[i], 1) == BW_OK, "select scv");
		CHECK(bw_bridge_order(b, me, BW_ORDER_DEFAULT, best.x, best.y, best.unit_id, 0) == BW_OK, "gather order");
	}
	int start_minerals = bw_bridge_minerals(b, me);
	bw_bridge_step(b, 24 * 30); /* ~30 game seconds */
	int mined = bw_bridge_minerals(b, me) - start_minerals;
	printf("bridge_smoke_test: mined %d minerals in 30s with %d SCVs\n", mined, scv_count);
	CHECK(mined >= 100, "workers did not mine (only %d)", mined);

	/* Sound: the simulation reported sounds while mining; they load as WAVs. */
	{
		bw_sound_event ev[256];
		int ns = bw_bridge_poll_sounds(b, ev, 256);
		CHECK(ns > 0, "no sound events while mining");
		int len = 0;
		CHECK(bw_bridge_load_sound(b, ev[0].sound_id, NULL, 0, &len) == BW_OK && len > 44, "sound %d not loadable", ev[0].sound_id);
		uint8_t* wav = (uint8_t*)malloc((size_t)len);
		CHECK(bw_bridge_load_sound(b, ev[0].sound_id, wav, len, &len) == BW_OK && memcmp(wav, "RIFF", 4) == 0, "sound is not a WAV");
		free(wav);
		bw_unit_type_info scv_info;
		bw_bridge_get_unit_type_info(b, TERRAN_SCV, &scv_info);
		CHECK(scv_info.yes_first > 0 && scv_info.yes_last >= scv_info.yes_first, "SCV has no yes sounds");
		printf("bridge_smoke_test: %d sound events, first id %d (%d byte WAV); SCV yes sounds %d-%d\n", ns, ev[0].sound_id, len, scv_info.yes_first, scv_info.yes_last);
	}

	/* Control groups: assign two SCVs to group 1, clear, recall. */
	CHECK(bw_bridge_select_units(b, me, scvs, 2) == BW_OK, "select two");
	CHECK(bw_bridge_control_group(b, me, 1, BW_GROUP_ASSIGN) == BW_OK, "assign group");
	bw_bridge_select_units(b, me, NULL, 0);
	CHECK(bw_bridge_control_group(b, me, 1, BW_GROUP_RECALL) == BW_OK, "recall group");
	{
		int32_t sel[12];
		CHECK(bw_bridge_get_selected_units(b, me, sel, 12) == 2, "group recall did not select 2 units");
	}

	/* Train an SCV from the CC; buildable list must offer it. */
	CHECK(bw_bridge_select_units(b, me, ccs, 1) == BW_OK, "select cc");
	int32_t buildable[64];
	int nb = bw_bridge_get_buildable(b, me, buildable, 64), offers_scv = 0;
	for (int i = 0; i != nb; ++i) if (buildable[i] == TERRAN_SCV) offers_scv = 1;
	CHECK(offers_scv, "CC buildable list (%d entries) lacks SCV", nb);
	int before = bw_bridge_minerals(b, me);
	CHECK(bw_bridge_train(b, me, TERRAN_SCV) == BW_OK, "train scv");
	CHECK(bw_bridge_minerals(b, me) == before - 50, "train did not charge 50 minerals");
	/* Queue a second SCV and cancel that slot: it's refunded and the queue shrinks. */
	{
		int m0 = bw_bridge_minerals(b, me);
		if (m0 >= 50 && bw_bridge_train(b, me, TERRAN_SCV) == BW_OK) {
			bw_unit_info q;
			bw_bridge_get_unit(b, ccs[0], &q);
			CHECK(q.queue_count == 2, "queue should hold 2, has %d", q.queue_count);
			CHECK(bw_bridge_cancel_queue_slot(b, me, 1) == BW_OK, "cancel queue slot 1");
			bw_bridge_get_unit(b, ccs[0], &q);
			CHECK(q.queue_count == 1 && bw_bridge_minerals(b, me) == m0, "slot cancel: queue %d minerals %d (expected 1, %d)", q.queue_count, bw_bridge_minerals(b, me), m0);
			printf("bridge_smoke_test: queued 2 SCVs, cancelled slot 1, refunded\n");
		}
	}

	/* Supply Depot: SCV must offer it; find a placeable spot near the CC. */
	CHECK(bw_bridge_select_units(b, me, &scvs[0], 1) == BW_OK, "select builder");
	nb = bw_bridge_get_buildable(b, me, buildable, 64);
	int offers_depot = 0;
	for (int i = 0; i != nb; ++i) if (buildable[i] == TERRAN_SUPPLY_DEPOT) offers_depot = 1;
	CHECK(offers_depot, "SCV buildable list (%d entries) lacks Supply Depot", nb);
	int found = 0, tx = 0, ty = 0;
	for (int r = 4; r < 14 && !found; ++r) {
		for (int dy = -r; dy <= r && !found; ++dy) {
			for (int dx = -r; dx <= r && !found; ++dx) {
				tx = cc.x / 32 + dx;
				ty = cc.y / 32 + dy;
				if (bw_bridge_can_place(b, me, TERRAN_SUPPLY_DEPOT, tx, ty)) found = 1;
			}
		}
	}
	CHECK(found, "no placeable supply depot spot near CC");
	CHECK(bw_bridge_can_place(b, me, TERRAN_SUPPLY_DEPOT, cc.x / 32 - 2, cc.y / 32 - 1) == 0, "placing on top of the CC was allowed");
	CHECK(bw_bridge_build(b, me, TERRAN_SUPPLY_DEPOT, tx, ty) == BW_OK, "build depot at %d,%d", tx, ty);
	int32_t depots[2];
	int depot_count = 0;
	for (int i = 0; i != 24 * 20 && depot_count == 0; ++i) {
		bw_bridge_step(b, 1);
		depot_count = find_units(b, me, TERRAN_SUPPLY_DEPOT, depots, 2);
	}
	CHECK(depot_count == 1, "supply depot never appeared");
	bw_unit_info depot;
	bw_bridge_get_unit(b, depots[0], &depot);
	printf("bridge_smoke_test: supply depot placed at tile %d,%d, progress %d/1000\n", tx, ty, depot.progress_permille);
	CHECK(!(depot.flags & BW_UNIT_FLAG_COMPLETED) && depot.progress_permille >= 0, "depot not under construction");

	/* Gas: build a Refinery on the geyser, send workers, gas must go up.
	 * Barracks: build one, train a Marine, it must appear. */
	enum { TERRAN_REFINERY = 110, TERRAN_BARRACKS = 111, TERRAN_MARINE = 0, VESPENE_GEYSER = 188 };
	bw_bridge_step(b, 24 * 90); /* bank minerals for refinery (100) + barracks (150) */
	printf("bridge_smoke_test: banked %d minerals\n", bw_bridge_minerals(b, me));
	CHECK(bw_bridge_minerals(b, me) >= 250, "not enough minerals banked (%d)", bw_bridge_minerals(b, me));
	int32_t geysers[8];
	int ng = find_units(b, 11, VESPENE_GEYSER, geysers, 8);
	CHECK(ng > 0, "no geyser");
	bw_unit_info geyser, best_geyser;
	long gbest = -1;
	for (int i = 0; i != ng; ++i) {
		bw_bridge_get_unit(b, geysers[i], &geyser);
		long dx = geyser.x - cc.x, dy = geyser.y - cc.y, d = dx * dx + dy * dy;
		if (gbest < 0 || d < gbest) { gbest = d; best_geyser = geyser; }
	}
	bw_unit_type_info ref;
	bw_bridge_get_unit_type_info(b, TERRAN_REFINERY, &ref);
	int gtx = (best_geyser.x - ref.placement_width / 2) / 32, gty = (best_geyser.y - ref.placement_height / 2) / 32;
	CHECK(bw_bridge_select_units(b, me, &scvs[1], 1) == BW_OK, "select refinery builder");
	CHECK(bw_bridge_can_place(b, me, TERRAN_REFINERY, gtx, gty), "refinery not placeable on geyser tile %d,%d", gtx, gty);
	CHECK(bw_bridge_build(b, me, TERRAN_REFINERY, gtx, gty) == BW_OK, "build refinery");

	int bx = 0, by = 0, bfound = 0;
	for (int r = 5; r < 16 && !bfound; ++r)
		for (int dy = -r; dy <= r && !bfound; ++dy)
			for (int dx = -r; dx <= r && !bfound; ++dx)
				if (bw_bridge_select_units(b, me, &scvs[2], 1) == BW_OK &&
				    bw_bridge_can_place(b, me, TERRAN_BARRACKS, cc.x / 32 + dx, cc.y / 32 + dy)) {
					bx = cc.x / 32 + dx; by = cc.y / 32 + dy; bfound = 1;
				}
	CHECK(bfound, "no barracks spot");
	CHECK(bw_bridge_build(b, me, TERRAN_BARRACKS, bx, by) == BW_OK, "build barracks");

	int32_t refineries[1], barracks[1];
	int done = 0;
	for (int i = 0; i != 24 * 120 && !done; ++i) {
		bw_bridge_step(b, 1);
		if (find_units(b, me, TERRAN_REFINERY, refineries, 1) && find_units(b, me, TERRAN_BARRACKS, barracks, 1)) {
			bw_unit_info r1, b1;
			bw_bridge_get_unit(b, refineries[0], &r1);
			bw_bridge_get_unit(b, barracks[0], &b1);
			done = (r1.flags & BW_UNIT_FLAG_COMPLETED) && (b1.flags & BW_UNIT_FLAG_COMPLETED);
		}
	}
	if (!done) {
		printf("bridge_smoke_test: refinery units=%d barracks units=%d minerals=%d\n",
		       find_units(b, me, TERRAN_REFINERY, refineries, 1), find_units(b, me, TERRAN_BARRACKS, barracks, 1), bw_bridge_minerals(b, me));
	}
	CHECK(done, "refinery/barracks never completed");

	bw_unit_info refinery;
	bw_bridge_get_unit(b, refineries[0], &refinery);
	for (int i = 0; i != 3; ++i) {
		bw_bridge_select_units(b, me, &scvs[i], 1);
		bw_bridge_order(b, me, BW_ORDER_DEFAULT, refinery.x, refinery.y, refinery.unit_id, 0);
	}
	CHECK(bw_bridge_select_units(b, me, barracks, 1) == BW_OK, "select barracks");
	CHECK(bw_bridge_train(b, me, TERRAN_MARINE) == BW_OK, "train marine");
	int gas0 = bw_bridge_gas(b, me);
	bw_bridge_step(b, 24 * 30);
	int gas_gained = bw_bridge_gas(b, me) - gas0;
	int32_t marines[2];
	int marine_count = find_units(b, me, TERRAN_MARINE, marines, 2);
	printf("bridge_smoke_test: gas +%d in 30s from 3 SCVs, marines=%d\n", gas_gained, marine_count);
	CHECK(gas_gained >= 40, "workers did not harvest gas (only %d)", gas_gained);
	CHECK(marine_count == 1, "marine did not train");

	/* Rally point: set on the barracks, read back through the unit info. */
	{
		bw_unit_info bk;
		bw_bridge_get_unit(b, barracks[0], &bk);
		CHECK(bw_bridge_select_units(b, me, barracks, 1) == BW_OK, "select barracks for rally");
		CHECK(bw_bridge_set_rally(b, me, bk.x + 200, bk.y + 64, 0) == BW_OK, "set rally");
		bw_bridge_get_unit(b, barracks[0], &bk);
		CHECK(bk.has_rally && bk.rally_x == bk.x + 200 && bk.rally_y == bk.y + 64, "rally not stored (%d: %d,%d)", bk.has_rally, bk.rally_x, bk.rally_y);
		printf("bridge_smoke_test: rally point set at %d,%d\n", bk.rally_x, bk.rally_y);
	}

	/* UI graphics: the original command icons and resource icons load. */
	{
		int h1 = bw_bridge_grp_load(b, "unit\\cmdbtns\\cmdicons.grp");
		int h2 = bw_bridge_grp_load(b, "game\\icons.grp");
		CHECK(h1 >= 0 && bw_bridge_grp_frame_count(b, h1) == 390, "cmdicons.grp");
		CHECK(h2 >= 0 && bw_bridge_grp_frame_count(b, h2) == 12, "icons.grp (uncompressed GRP)");
	}

	/* Research and upgrades: Academy -> Stim Packs used by a Marine;
	 * Engineering Bay -> Infantry Weapons level 1. */
	{
		enum { ACADEMY = 112, ENGINEERING_BAY = 122, STIM = 0, INFANTRY_WEAPONS = 7 };
		for (int i = 0; i != 24 * 300 && bw_bridge_minerals(b, me) < 300; ++i) bw_bridge_step(b, 1);
		CHECK(bw_bridge_minerals(b, me) >= 300, "could not bank 300 minerals");
		int ax, ay, ex, ey;
		CHECK(bw_bridge_select_units(b, me, &scvs[0], 1) == BW_OK, "select builder");
		CHECK(nearest_place(b, me, ACADEMY, cc.x, cc.y, 5, &ax, &ay) && bw_bridge_build(b, me, ACADEMY, ax, ay) == BW_OK, "place academy");
		bw_bridge_step(b, 24 * 3);
		CHECK(bw_bridge_select_units(b, me, &scvs[3], 1) == BW_OK, "select builder 2 (a mineral miner, not one inside the refinery)");
		int found_bay = nearest_place(b, me, ENGINEERING_BAY, cc.x, cc.y, 6, &ex, &ey);
		bw_status bay_status = found_bay ? bw_bridge_build(b, me, ENGINEERING_BAY, ex, ey) : BW_ERR_UNKNOWN;
		CHECK(found_bay && bay_status == BW_OK, "place engineering bay (found=%d at %d,%d status=%d minerals=%d)", found_bay, ex, ey, bay_status, bw_bridge_minerals(b, me));
		int32_t academy, bay;
		CHECK(wait_for_completed(b, me, ACADEMY, 24 * 120, &academy), "academy never completed");
		CHECK(wait_for_completed(b, me, ENGINEERING_BAY, 24 * 120, &bay), "engineering bay never completed");
		bw_bridge_step(b, 24 * 30);

		bw_tech_info ti;
		CHECK(bw_bridge_get_tech_info(b, me, STIM, &ti) == BW_OK && !ti.researched, "stim info");
		printf("bridge_smoke_test: tech '%s' %d/%d icon %d\n", ti.name, ti.mineral_cost, ti.gas_cost, ti.icon);
		send_workers_mining(b, me, TERRAN_SCV); /* builders idle after construction, as in the original */
		for (int i = 0; i != 24 * 300 && bw_bridge_minerals(b, me) < 250; ++i) bw_bridge_step(b, 1);
		CHECK(bw_bridge_select_units(b, me, &academy, 1) == BW_OK, "select academy");
		int32_t ids[64];
		int nr = bw_bridge_get_researchable(b, me, ids, 64), has_stim = 0;
		for (int i = 0; i != nr; ++i) if (ids[i] == STIM) has_stim = 1;
		CHECK(has_stim, "academy can't research stim (%d researchable)", nr);
		CHECK(bw_bridge_research(b, me, STIM) == BW_OK, "research stim (minerals %d gas %d)", bw_bridge_minerals(b, me), bw_bridge_gas(b, me));

		CHECK(bw_bridge_select_units(b, me, &bay, 1) == BW_OK, "select bay");
		bw_upgrade_info ui0;
		bw_bridge_get_upgrade_info(b, me, INFANTRY_WEAPONS, &ui0);
		printf("bridge_smoke_test: upgrade '%s' level %d/%d cost %d/%d\n", ui0.name, ui0.level, ui0.max_level, ui0.mineral_cost, ui0.gas_cost);
		CHECK(bw_bridge_upgrade(b, me, INFANTRY_WEAPONS) == BW_OK, "upgrade infantry weapons (minerals %d gas %d)", bw_bridge_minerals(b, me), bw_bridge_gas(b, me));

		int researched = 0;
		for (int i = 0; i != 24 * 120 && !researched; ++i) {
			bw_bridge_step(b, 1);
			bw_bridge_get_tech_info(b, me, STIM, &ti);
			researched = ti.researched;
		}
		CHECK(researched, "stim never finished researching");

		int32_t m[2];
		CHECK(find_units(b, me, TERRAN_MARINE, m, 2) >= 1, "marine gone");
		bw_unit_info before_stim, after_stim;
		bw_bridge_get_unit(b, m[0], &before_stim);
		CHECK(bw_bridge_select_units(b, me, m, 1) == BW_OK, "select marine");
		CHECK(bw_bridge_can_use_tech(b, me, STIM), "marine can't use stim after research");
		CHECK(bw_bridge_action(b, me, BW_ACT_STIM) == BW_OK, "stim");
		bw_bridge_step(b, 2);
		bw_bridge_get_unit(b, m[0], &after_stim);
		printf("bridge_smoke_test: stim packs: marine hp %d -> %d, stimmed=%d\n", before_stim.hp, after_stim.hp, (after_stim.flags & BW_UNIT_FLAG_STIMMED) != 0);
		CHECK(after_stim.hp == before_stim.hp - 10 && (after_stim.flags & BW_UNIT_FLAG_STIMMED), "stim had no effect");

		int level = 0;
		for (int i = 0; i != 24 * 300 && level == 0; ++i) {
			bw_bridge_step(b, 1);
			bw_upgrade_info u;
			bw_bridge_get_upgrade_info(b, me, INFANTRY_WEAPONS, &u);
			level = u.level;
		}
		CHECK(level == 1, "infantry weapons upgrade never finished");
		printf("bridge_smoke_test: infantry weapons now level %d\n", level);
	}

	bw_bridge_destroy(b);
	test_protoss(dd, mf);
	test_zerg(dd, mf);
	test_save_replay(dd, mf);
	test_alliances(dd, mf);
	test_surrender(dd, mf);
	test_defensive(dd, mf);
	test_autoplay(dd, mf);
	test_ai(dd, mf);
	printf("bridge_smoke_test: OK\n");
	return 0;
}
