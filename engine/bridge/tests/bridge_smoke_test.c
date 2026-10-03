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
	printf("bridge_smoke_test: OK\n");
	return 0;
}
