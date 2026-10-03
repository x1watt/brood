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

int main(int argc, char** argv) {
	char data_dir[1024], map_file[1100];
	const char* home = getenv("HOME");
	snprintf(data_dir, sizeof(data_dir), "%s/box/media/games/BROOD/", home ? home : "");
	snprintf(map_file, sizeof(map_file), "%smaps/ladder/(4)Lost Temple.scm", data_dir);
	const char* dd = argc > 1 ? argv[1] : data_dir;
	const char* mf = argc > 2 ? argv[2] : map_file;
	const int me = 0;

	CHECK(bw_bridge_abi_version() == BW_BRIDGE_ABI_VERSION, "abi mismatch");
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

	/* Train an SCV from the CC; buildable list must offer it. */
	CHECK(bw_bridge_select_units(b, me, ccs, 1) == BW_OK, "select cc");
	int32_t buildable[64];
	int nb = bw_bridge_get_buildable(b, me, buildable, 64), offers_scv = 0;
	for (int i = 0; i != nb; ++i) if (buildable[i] == TERRAN_SCV) offers_scv = 1;
	CHECK(offers_scv, "CC buildable list (%d entries) lacks SCV", nb);
	int before = bw_bridge_minerals(b, me);
	CHECK(bw_bridge_train(b, me, TERRAN_SCV) == BW_OK, "train scv");
	CHECK(bw_bridge_minerals(b, me) == before - 50, "train did not charge 50 minerals");

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

	bw_bridge_destroy(b);
	printf("bridge_smoke_test: OK\n");
	return 0;
}
