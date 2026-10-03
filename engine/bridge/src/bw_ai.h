// engine/bridge/src/bw_ai.h
//
// Computer opponents. OpenBW reimplements the simulation, not Brood War's
// own AI scripts (aiscript.bin), so this is a small rule-based player: it
// mines, keeps supply ahead of use, follows a short build order per race,
// researches a few key upgrades, trains an army, defends its bases, attacks
// in growing waves and takes expansions.
//
// Diplomacy (bw_alliances.h) aims at the best final score and weighs the
// situation like a player would: neighbours make useful allies, a common
// stronger enemy brings others together, partners who mine a lot are worth
// more (allies share mining points). A player losing a fight at home asks
// for peace or for help and, turned down, offers to surrender. Surrenders
// are accepted when a vassal's tribute is worth more than finishing it off.
// Once no meaningful enemy is left, a player strong enough turns on its
// weaker ally to conquer it. A personality (trust) colours every decision.
// Vassals keep playing for their lord but no longer negotiate.
//
// It only ever commands its own units: OpenBW refuses orders for anyone
// else's, and only the human player is given allies' units to command (in
// bw_bridge.cpp). Units a human ally took over recently are left alone, and
// allied with a human it spends only its share of the common treasury.
//
// It plays through OpenBW's action functions (select, train, build, order),
// the same way a human's commands reach the simulation. It runs inside
// bw_bridge_step and only uses deterministic inputs (unit list order, its
// own seeded random numbers, never pointer order), so a saved game that is
// replayed from its command log plays out identically.

#ifndef BW_AI_H
#define BW_AI_H

#include "bwgame.h"
#include "actions.h"
#include "bw_alliances.h"

#include <algorithm>
#include <array>
#include <cstdint>

namespace bw_ai {

using namespace bwgame;

static const int think_interval = 12; // frames between decisions (about 0.5 s)
static const int human_command_hold = 24 * 60; // frames a human-commanded unit is left alone

struct player {
	int owner = -1;
	race_t race = race_t::terran;
	uint32_t rng = 1;
	xy home;
	xy rally;
	int wave_size = 8;
	bool attacking = false;
	int last_attack_order = -10000;
	int expand_worker_frame = -10000;
	int trust = 50; // 0-99: personality for alliances
	bool diplomacy_started = false;
	int next_invite = 0;
	int next_assess = 0;
	int next_open_change = 0;
	int next_betrayal_check = 0;
	bool losing = false;      // being beaten at home right now
	int attacker = -1;        // who is doing it
	std::array<int, 8> pressure{};  // decaying value lost to each player
	std::array<int, 8> lost_seen{};
	std::array<int, 8> asked_at{}; // frame we last invited each player (+1; 0 = never)
	int losing_since = -1;
	int next_surrender = 0;
	int focus = -1; // a former ally we turned on: attack it first

	uint32_t next() {
		rng = rng * 1103515245u + 12345u;
		return (rng >> 16) & 0x7fff;
	}
};

struct build_step {
	UnitTypes type;
	int count; // wanted total (including ones in progress)
	int supply; // start once this much supply is in use
};

struct research_step {
	UnitTypes building;
	bool is_tech;
	int id;
	int supply;
};

struct ai_system {
	a_vector<player> players;
	a_vector<xy> sites; // resource clusters: possible bases
	bool sites_ready = false;
	bw_alliances::alliance_system* allies = nullptr;
	// Frame a human last commanded each unit (by unit index), for allied
	// units a human player took over.
	a_vector<int> human_frame;

	void human_commanded(const unit_t* u, int frame) {
		if (human_frame.size() <= u->index) human_frame.resize(u->index + 1, -100000);
		human_frame[u->index] = frame;
	}

	bool held_by_human(const unit_t* u, int frame) const {
		return u->index < human_frame.size() && frame - human_frame[u->index] < human_command_hold;
	}

	void add(int owner, race_t race, uint32_t seed, xy home) {
		player p;
		p.owner = owner;
		p.race = race;
		p.rng = seed * 2654435761u + (uint32_t)owner * 40503u + 1;
		p.home = home;
		p.rally = home;
		p.trust = (int)(p.next() % 100);
		p.next_invite = 24 * 60 * 3 + (int)(p.next() % (24 * 60));
		players.push_back(p);
	}

	void clear() {
		players.clear();
		sites.clear();
		sites_ready = false;
		human_frame.clear();
	}

	void update(state& st, action_state& action_st) {
		if (players.empty()) return;
		action_functions f(st, action_st);
		if (!sites_ready) find_sites(f);
		int frame = st.current_frame;
		for (auto& p : players) {
			if ((frame + p.owner * 3) % think_interval != 0) continue;
			// Defeated (its units turned neutral) or already won.
			if (st.players[p.owner].controller != player_t::controller_occupied || st.players[p.owner].victory_state >= 3) continue;
			try {
				if (allies) diplomacy(f, p);
				think(f, p);
			} catch (...) {
				// A failed decision must never stop the game; try again next time.
			}
			// Fold this player's spending into its alliance's treasury
			// before the next one decides.
			if (allies) allies->sync(st);
		}
	}

private:
	// --- static data -------------------------------------------------------------

	static UnitTypes worker_of(race_t r) {
		return r == race_t::zerg ? UnitTypes::Zerg_Drone : r == race_t::protoss ? UnitTypes::Protoss_Probe : UnitTypes::Terran_SCV;
	}
	static UnitTypes depot_of(race_t r) {
		return r == race_t::zerg ? UnitTypes::Zerg_Hatchery : r == race_t::protoss ? UnitTypes::Protoss_Nexus : UnitTypes::Terran_Command_Center;
	}
	static UnitTypes supply_of(race_t r) {
		return r == race_t::zerg ? UnitTypes::Zerg_Overlord : r == race_t::protoss ? UnitTypes::Protoss_Pylon : UnitTypes::Terran_Supply_Depot;
	}
	static UnitTypes gas_of(race_t r) {
		return r == race_t::zerg ? UnitTypes::Zerg_Extractor : r == race_t::protoss ? UnitTypes::Protoss_Assimilator : UnitTypes::Terran_Refinery;
	}

	static const a_vector<build_step>& build_order(race_t r) {
		static const a_vector<build_step> terran = {
			{UnitTypes::Terran_Barracks, 1, 10},
			{UnitTypes::Terran_Refinery, 1, 12},
			{UnitTypes::Terran_Barracks, 2, 14},
			{UnitTypes::Terran_Academy, 1, 18},
			{UnitTypes::Terran_Barracks, 3, 22},
			{UnitTypes::Terran_Engineering_Bay, 1, 28},
			{UnitTypes::Terran_Factory, 1, 32},
			{UnitTypes::Terran_Barracks, 4, 40},
			{UnitTypes::Terran_Barracks, 5, 60},
			{UnitTypes::Terran_Factory, 2, 80},
		};
		static const a_vector<build_step> protoss = {
			{UnitTypes::Protoss_Gateway, 1, 10},
			{UnitTypes::Protoss_Assimilator, 1, 12},
			{UnitTypes::Protoss_Cybernetics_Core, 1, 14},
			{UnitTypes::Protoss_Gateway, 2, 16},
			{UnitTypes::Protoss_Gateway, 3, 22},
			{UnitTypes::Protoss_Forge, 1, 30},
			{UnitTypes::Protoss_Gateway, 4, 38},
			{UnitTypes::Protoss_Gateway, 5, 56},
			{UnitTypes::Protoss_Gateway, 6, 80},
		};
		static const a_vector<build_step> zerg = {
			{UnitTypes::Zerg_Spawning_Pool, 1, 9},
			{UnitTypes::Zerg_Extractor, 1, 11},
			{UnitTypes::Zerg_Hatchery, 2, 13},
			{UnitTypes::Zerg_Hydralisk_Den, 1, 18},
			{UnitTypes::Zerg_Evolution_Chamber, 1, 28},
			{UnitTypes::Zerg_Lair, 1, 32},
			{UnitTypes::Zerg_Spire, 1, 40},
			{UnitTypes::Zerg_Hatchery, 3, 50},
		};
		return r == race_t::zerg ? zerg : r == race_t::protoss ? protoss : terran;
	}

	static const a_vector<research_step>& research_order(race_t r) {
		static const a_vector<research_step> terran = {
			{UnitTypes::Terran_Academy, true, (int)TechTypes::Stim_Packs, 20},
			{UnitTypes::Terran_Academy, false, (int)UpgradeTypes::U_238_Shells, 24},
			{UnitTypes::Terran_Engineering_Bay, false, (int)UpgradeTypes::Terran_Infantry_Weapons, 30},
			{UnitTypes::Terran_Engineering_Bay, false, (int)UpgradeTypes::Terran_Infantry_Armor, 60},
		};
		static const a_vector<research_step> protoss = {
			{UnitTypes::Protoss_Cybernetics_Core, false, (int)UpgradeTypes::Singularity_Charge, 20},
			{UnitTypes::Protoss_Forge, false, (int)UpgradeTypes::Protoss_Ground_Weapons, 30},
			{UnitTypes::Protoss_Forge, false, (int)UpgradeTypes::Protoss_Ground_Armor, 60},
		};
		static const a_vector<research_step> zerg = {
			{UnitTypes::Zerg_Spawning_Pool, false, (int)UpgradeTypes::Metabolic_Boost, 14},
			{UnitTypes::Zerg_Hydralisk_Den, false, (int)UpgradeTypes::Grooved_Spines, 24},
			{UnitTypes::Zerg_Hydralisk_Den, false, (int)UpgradeTypes::Muscular_Augments, 30},
			{UnitTypes::Zerg_Evolution_Chamber, false, (int)UpgradeTypes::Zerg_Missile_Attacks, 32},
			{UnitTypes::Zerg_Evolution_Chamber, false, (int)UpgradeTypes::Zerg_Carapace, 60},
		};
		return r == race_t::zerg ? zerg : r == race_t::protoss ? protoss : terran;
	}

	// --- helpers -----------------------------------------------------------------

	static int dist2(xy a, xy b) {
		int dx = a.x - b.x, dy = a.y - b.y;
		return dx * dx + dy * dy;
	}

	static bool is_idle(const unit_t* u) {
		auto id = u->order_type->id;
		return id == Orders::PlayerGuard || id == Orders::Guard || id == Orders::Nothing || id == Orders::Stop;
	}

	static bool is_gas_order(Orders id) {
		return id == Orders::MoveToGas || id == Orders::WaitForGas || id == Orders::HarvestGas || id == Orders::ReturnGas;
	}

	static bool is_build_order(Orders id) {
		return id == Orders::PlaceBuilding || id == Orders::PlaceProtossBuilding || id == Orders::DroneStartBuild;
	}

	static bool is_army_type(UnitTypes id) {
		switch (id) {
		case UnitTypes::Zerg_Overlord:
		case UnitTypes::Zerg_Larva:
		case UnitTypes::Zerg_Egg:
		case UnitTypes::Zerg_Cocoon:
		case UnitTypes::Zerg_Lurker_Egg:
		case UnitTypes::Protoss_Interceptor:
		case UnitTypes::Protoss_Scarab:
		case UnitTypes::Terran_Vulture_Spider_Mine:
		case UnitTypes::Terran_Nuclear_Missile:
			return false;
		default:
			return true;
		}
	}

	struct snapshot {
		a_vector<unit_t*> workers;
		a_vector<unit_t*> depots; // completed town halls
		a_vector<unit_t*> army;
		a_vector<unit_t*> larvae;
		a_vector<unit_t*> buildings;
		std::array<int, (size_t)UnitTypes::None> planned{}; // existing, queued and ordered
		std::array<int, (size_t)UnitTypes::None> done{};    // completed
		int gas_workers = 0;
		int minerals = 0;
		int gas = 0;
		int supply_used = 0; // whole supply units
		int supply_max = 0;
	};

	static void bump(std::array<int, (size_t)UnitTypes::None>& a, const unit_type_t* t) {
		if (t && (size_t)t->id < a.size()) ++a[(size_t)t->id];
	}

	snapshot take_snapshot(action_functions& f, player& p) {
		snapshot s;
		state& st = f.st;
		int race = (int)p.race;
		for (unit_t* u : ptr(st.player_units.at(p.owner))) {
			if (f.unit_dead(u) || !u->sprite) continue;
			bump(s.planned, u->unit_type);
			// A worker's queue holds the building it was last told to place,
			// even after that failed; only its order says it's still on it.
			if (!f.ut_worker(u)) {
				for (const unit_type_t* q : u->build_queue) bump(s.planned, q);
			}
			bool completed = f.u_completed(u);
			if (completed) bump(s.done, u->unit_type);
			bool held = held_by_human(u, st.current_frame);
			if (f.ut_worker(u)) {
				if (!completed || held) continue;
				s.workers.push_back(u);
				if (is_gas_order(u->order_type->id)) ++s.gas_workers;
				if (is_build_order(u->order_type->id) && !u->build_queue.empty()) bump(s.planned, u->build_queue.front());
			} else if (f.ut_building(u)) {
				s.buildings.push_back(u);
				if (completed && f.ut_resource_depot(u)) s.depots.push_back(u);
			} else if (f.unit_is(u, UnitTypes::Zerg_Larva)) {
				s.larvae.push_back(u);
			} else if (completed && !held && !f.ut_turret(u) && is_army_type(u->unit_type->id)) {
				s.army.push_back(u);
			}
		}
		// Lairs and Hives still count as Hatcheries for the build order.
		s.planned[(size_t)UnitTypes::Zerg_Hatchery] += s.planned[(size_t)UnitTypes::Zerg_Lair] + s.planned[(size_t)UnitTypes::Zerg_Hive];
		s.planned[(size_t)UnitTypes::Zerg_Lair] += s.planned[(size_t)UnitTypes::Zerg_Hive];
		s.done[(size_t)UnitTypes::Zerg_Lair] += s.done[(size_t)UnitTypes::Zerg_Hive];
		s.minerals = st.current_minerals[p.owner];
		s.gas = st.current_gas[p.owner];
		s.supply_used = st.supply_used[p.owner][race].raw_value / 2;
		s.supply_max = std::min(200, (int)(st.supply_available[p.owner][race].raw_value / 2));
		return s;
	}

	bool select(action_functions& f, player& p, unit_t* u) {
		return f.action_select(p.owner, u);
	}

	void order_group(action_functions& f, player& p, const a_vector<unit_t*>& units, Orders order, xy pos) {
		const order_type_t* o = f.get_order_type(order);
		a_vector<unit_t*> batch;
		for (size_t i = 0; i < units.size(); ++i) {
			batch.push_back(units[i]);
			if (batch.size() == 12 || i + 1 == units.size()) {
				f.action_select(p.owner, batch);
				f.action_order(p.owner, o, f.restrict_pos_to_map_bounds(pos), nullptr, nullptr, false);
				batch.clear();
			}
		}
	}

	bool is_enemy(action_functions& f, int me, int other) const {
		if (other == me || other < 0 || other >= 8) return false;
		auto& pl = f.st.players[other];
		if (pl.controller != player_t::controller_occupied) return false;
		if (pl.victory_state != 0) return false;
		return f.st.alliances[me][other] != 2;
	}

	// Mineral fields and geysers grouped into clusters, each a possible base.
	void find_sites(action_functions& f) {
		sites_ready = true;
		a_vector<xy> res;
		for (unit_t* u : ptr(f.st.player_units.at(11))) {
			if (f.unit_dead(u) || !u->sprite) continue;
			if (f.unit_is_mineral_field(u) || f.unit_is(u, UnitTypes::Resource_Vespene_Geyser)) res.push_back(u->sprite->position);
		}
		a_vector<int> cluster(res.size(), -1);
		int n = 0;
		for (size_t i = 0; i != res.size(); ++i) {
			if (cluster[i] != -1) continue;
			cluster[i] = n;
			a_vector<size_t> open{i};
			while (!open.empty()) {
				size_t a = open.back();
				open.pop_back();
				for (size_t j = 0; j != res.size(); ++j) {
					if (cluster[j] == -1 && dist2(res[a], res[j]) <= 256 * 256) {
						cluster[j] = n;
						open.push_back(j);
					}
				}
			}
			++n;
		}
		for (int c = 0; c != n; ++c) {
			xy sum;
			int count = 0;
			for (size_t i = 0; i != res.size(); ++i) {
				if (cluster[i] != c) continue;
				sum += res[i];
				++count;
			}
			if (count >= 4) sites.push_back(sum / count);
		}
	}

	// --- placement -------------------------------------------------------------

	static bool overlaps(const rect& a, const rect& b) {
		return a.from.x < b.to.x && b.from.x < a.to.x && a.from.y < b.to.y && b.from.y < a.to.y;
	}

	// Keeps a free lane around new buildings so units can walk between them,
	// keeps the mineral line clear, and leaves room for Terran addons.
	bool has_clearance(action_functions& f, const unit_type_t* ut, xy_t<size_t> tile, const unit_t* builder) {
		rect r{xy((int)tile.x * 32, (int)tile.y * 32), xy((int)tile.x * 32 + ut->placement_size.x, (int)tile.y * 32 + ut->placement_size.y)};
		rect lane{r.from - xy(32, 32), r.to + xy(32, 32)};
		if (ut->id == UnitTypes::Terran_Factory || ut->id == UnitTypes::Terran_Command_Center) lane.to.x += 64;
		rect keep_off{r.from - xy(96, 96), r.to + xy(96, 96)};
		for (int owner = 0; owner != 12; ++owner) {
			for (unit_t* n : ptr(f.st.player_units.at(owner))) {
				if (n == builder || f.unit_dead(n) || !n->sprite) continue;
				if (f.ut_resource(n)) {
					if (overlaps(keep_off, n->unit_finder_bounding_box)) return false;
				} else if (f.ut_building(n)) {
					rect nb = n->unit_finder_bounding_box;
					// Addon-capable neighbours keep their addon spot free too.
					if (n->unit_type->id == UnitTypes::Terran_Factory || n->unit_type->id == UnitTypes::Terran_Command_Center) nb.to.x += 64;
					if (overlaps(lane, nb)) return false;
				}
			}
		}
		return true;
	}

	bool find_spot(action_functions& f, player& p, unit_t* builder, const unit_type_t* ut, xy center, int min_r, int max_r, xy_t<size_t>& out) {
		int cx = center.x / 32, cy = center.y / 32;
		int w = ut->placement_size.x / 32, h = ut->placement_size.y / 32;
		for (int r = min_r; r <= max_r; ++r) {
			int perimeter = r * 8;
			int start = (int)(p.next() % (uint32_t)perimeter);
			for (int k = 0; k != perimeter; ++k) {
				int i = (start + k) % perimeter;
				int dx, dy;
				int side = i / (2 * r), off = i % (2 * r);
				if (side == 0) { dx = -r + off; dy = -r; }
				else if (side == 1) { dx = r; dy = -r + off; }
				else if (side == 2) { dx = r - off; dy = r; }
				else { dx = -r; dy = r - off; }
				int tx = cx + dx - w / 2, ty = cy + dy - h / 2;
				if (tx < 0 || ty < 0) continue;
				xy_t<size_t> tile((size_t)tx, (size_t)ty);
				xy pos(tx * 32 + ut->placement_size.x / 2, ty * 32 + ut->placement_size.y / 2);
				if (!f.can_place_building(builder, p.owner, ut, pos, false, false)) continue;
				if (!has_clearance(f, ut, tile, builder)) continue;
				out = tile;
				return true;
			}
		}
		return false;
	}

	unit_t* pick_builder(action_functions& f, snapshot& s, xy near) {
		unit_t* best = nullptr;
		int best_d = 0;
		for (unit_t* w : s.workers) {
			auto id = w->order_type->id;
			if (is_build_order(id) || is_gas_order(id) || id == Orders::ConstructingBuilding) continue;
			if (w->order_type->id == Orders::Move) continue; // already sent somewhere
			int d = dist2(w->sprite->position, near);
			if (!best || d < best_d) {
				best = w;
				best_d = d;
			}
		}
		return best;
	}

	static const order_type_t* build_order_for(action_functions& f, const unit_t* builder) {
		if (f.unit_is(builder, UnitTypes::Protoss_Probe)) return f.get_order_type(Orders::PlaceProtossBuilding);
		if (f.unit_is(builder, UnitTypes::Zerg_Drone)) return f.get_order_type(Orders::DroneStartBuild);
		return f.get_order_type(Orders::PlaceBuilding);
	}

	bool affordable(const unit_type_t* ut, int minerals, int gas) {
		return minerals >= ut->mineral_cost && gas >= ut->gas_cost;
	}

	// Places a building of type `type` near the home base. Returns true when
	// an order was issued.
	bool place(action_functions& f, player& p, snapshot& s, UnitTypes type) {
		const unit_type_t* ut = f.get_unit_type(type);
		xy center = s.depots.empty() ? p.home : s.depots.front()->sprite->position;
		unit_t* builder = pick_builder(f, s, center);
		if (!builder) return false;
		xy_t<size_t> tile;
		if (type == gas_of(p.race)) {
			if (!find_geyser(f, p, s, ut, tile)) return false;
		} else {
			int min_r = type == supply_of(p.race) ? 3 : 4;
			if (!find_spot(f, p, builder, ut, center, min_r, 16, tile)) return false;
		}
		if (!select(f, p, builder)) return false;
		return f.action_build(p.owner, build_order_for(f, builder), ut, tile);
	}

	bool find_geyser(action_functions& f, player& p, snapshot& s, const unit_type_t* ut, xy_t<size_t>& out) {
		for (unit_t* d : s.depots) {
			for (unit_t* g : ptr(f.st.player_units.at(11))) {
				if (f.unit_dead(g) || !f.unit_is(g, UnitTypes::Resource_Vespene_Geyser)) continue;
				if (dist2(g->sprite->position, d->sprite->position) > 384 * 384) continue;
				xy top_left = g->sprite->position - ut->placement_size / 2;
				out = xy_t<size_t>((size_t)(top_left.x / 32), (size_t)(top_left.y / 32));
				return true;
			}
		}
		return false;
	}

	// --- decisions ------------------------------------------------------------

	// What a player can see of the balance of power.
	struct assessment {
		std::array<int, 8> army{};    // mineral + gas value of combat units
		std::array<int, 8> economy{}; // 50 per worker
		std::array<xy, 8> base{};     // main base
		std::array<bool, 8> has_base{};
		std::array<int, 8> near_me{}; // army value within reach of my buildings
		int my_home_army = 0;
		int map_diagonal = 1;
	};

	assessment assess(action_functions& f, player& p) {
		assessment a;
		state& st = f.st;
		a.map_diagonal = std::max(1, f.xy_length(xy((int)f.game_st.map_width, (int)f.game_st.map_height)));
		a_vector<xy> mine;
		for (unit_t* u : ptr(st.player_units.at(p.owner))) {
			if (!f.unit_dead(u) && u->sprite && f.ut_building(u)) mine.push_back(u->sprite->position);
		}
		auto near_mine = [&](xy pos) {
			for (xy b : mine) {
				if (dist2(b, pos) < 640 * 640) return true;
			}
			return false;
		};
		for (int o = 0; o != 8; ++o) {
			if (!allies->playing[o]) continue;
			for (unit_t* u : ptr(st.player_units.at(o))) {
				if (f.unit_dead(u) || !u->sprite) continue;
				if (f.ut_resource_depot(u) && !a.has_base[o]) {
					a.base[o] = u->sprite->position;
					a.has_base[o] = true;
				}
				if (f.ut_worker(u)) {
					a.economy[o] += 50;
					continue;
				}
				if (f.ut_building(u) || !f.u_completed(u) || f.ut_turret(u) || !is_army_type(u->unit_type->id)) continue;
				int value = u->unit_type->mineral_cost + u->unit_type->gas_cost;
				a.army[o] += value;
				if (near_mine(u->sprite->position)) {
					if (o == p.owner) a.my_home_army += value;
					else a.near_me[o] += value;
				}
			}
			if (!a.has_base[o]) a.base[o] = st.game->start_locations[(size_t)o];
		}
		return a;
	}

	int strength(const assessment& a, const a_vector<int>& group) const {
		int s = 0;
		for (int m : group) s += a.army[(size_t)m] + a.economy[(size_t)m] / 4;
		return s;
	}

	// How much this player wants to be allied with `g` (another group).
	int alliance_utility(action_functions& f, player& p, const assessment& a, const a_vector<int>& g) {
		auto& al = *allies;
		int u = (p.trust - 50) / 2;
		// Neighbours make the most useful allies (and the worst enemies).
		int d = a.map_diagonal;
		for (int m : g) d = std::min(d, f.xy_length(a.base[(size_t)m] - a.base[(size_t)p.owner]));
		int closeness = 100 - std::min(100, d * 100 / a.map_diagonal);
		u += closeness / 4;
		a_vector<int> my_group = al.members(al.group[p.owner]);
		int mine = strength(a, my_group), theirs = strength(a, g);
		// The strongest of everyone else.
		int strongest = 0;
		for (int q = 0; q != 8; ++q) {
			if (!al.active(f.st, q) || al.group[q] == al.group[p.owner] || al.group[q] == al.group[g.front()]) continue;
			strongest = std::max(strongest, strength(a, al.members(al.group[q])));
		}
		if (p.losing) {
			bool has_attacker = std::find(g.begin(), g.end(), p.attacker) != g.end();
			if (has_attacker) u += 55; // peace with whoever is winning against us
			else {
				int threat = 0;
				for (int q = 0; q != 8; ++q) threat += a.near_me[(size_t)q];
				if (theirs >= threat) u += 40 + closeness / 4; // they can come and help
			}
		} else {
			if (mine > 0 && mine * 10 > std::max(strongest, theirs) * 16) u -= 35; // we don't need anyone
			if (theirs * 3 < mine) u -= 15;                                      // they'd be dead weight
			// Winning a fight against them right now: no reason to stop.
			int beating = 0;
			for (int m : g) beating += allies->value_lost_to[(size_t)m][(size_t)p.owner];
			if (beating > 0 && p.pressure[(size_t)g.front()] == 0 && beating > 400) u -= 20;
		}
		if (strongest * 10 > mine * 13 && strongest > theirs) u += 25; // a common stronger enemy
		// Allies share mining points: partners who mine a lot are worth more.
		int my_rate = 0, their_rate = 0;
		for (int m : my_group) {
			if (!al.vassal(m)) my_rate += al.mineral_rate[m] + al.gas_rate[m];
		}
		for (int m : g) {
			if (!al.vassal(m)) their_rate += al.mineral_rate[m] + al.gas_rate[m];
		}
		if (their_rate > 0) u += std::min(25, their_rate * 20 / std::max(1, my_rate));
		if (theirs > mine * 2 && !p.losing) u += 10;                    // safety with the strong
		return u;
	}

	void diplomacy(action_functions& f, player& p) {
		auto& al = *allies;
		state& st = f.st;
		if (!al.active(st, p.owner) || al.vassal(p.owner)) return;
		int frame = st.current_frame;
		if (!p.diplomacy_started) {
			p.diplomacy_started = true;
			if (p.trust >= 30) al.set_open(st, p.owner, true);
		}
		if (frame < p.next_assess) return;
		p.next_assess = frame + 24;
		assessment a = assess(f, p);

		// Losses to each player, fading over about ten seconds.
		int recent = 0;
		for (int k = 0; k != 8; ++k) {
			int lost = al.value_lost_to[(size_t)p.owner][(size_t)k];
			p.pressure[(size_t)k] = p.pressure[(size_t)k] * 15 / 16 + (lost - p.lost_seen[(size_t)k]);
			p.lost_seen[(size_t)k] = lost;
			recent += p.pressure[(size_t)k];
		}
		int threat = 0, worst = 0;
		p.attacker = -1;
		for (int k = 0; k != 8; ++k) {
			if (k == p.owner || al.same_group(k, p.owner)) continue;
			threat += a.near_me[(size_t)k];
			int danger = a.near_me[(size_t)k] + p.pressure[(size_t)k] * 2;
			if (danger > worst) {
				worst = danger;
				p.attacker = k;
			}
		}
		// Invaders at home that the defenders can't stop.
		p.losing = threat > 300 && threat * 10 > a.my_home_army * 13 && recent > 150;
		if (!p.losing) p.losing_since = -1;
		else if (p.losing_since < 0) p.losing_since = frame;
		if (p.attacker >= 0 && al.vassal(p.attacker)) p.attacker = al.lord[p.attacker];

		a_vector<int> my_group = al.members(al.group[p.owner]);
		int mine = strength(a, my_group);
		int others_best = 0;
		for (int q = 0; q != 8; ++q) {
			if (al.active(st, q) && !al.same_group(q, p.owner)) others_best = std::max(others_best, strength(a, al.members(al.group[q])));
		}

		// Openness follows the situation: under pressure or outmatched,
		// look for friends; dominant and distrustful, keep to yourself.
		if (frame >= p.next_open_change) {
			bool want_open = p.losing || others_best * 10 > mine * 13 || (p.trust >= 30 && !(mine > others_best * 2 && p.trust < 60));
			if (want_open != al.open[p.owner]) {
				al.set_open(st, p.owner, want_open);
				p.next_open_change = frame + 24 * 60;
			}
		}

		// Answer invitations after a moment's thought.
		for (int from = 0; from != bw_alliances::max_players; ++from) {
			int sent = al.invite_frame[p.owner][from];
			if (sent < 0 || frame - sent < 24 * (3 + p.trust % 5)) continue;
			bool yes = false;
			if (al.merge_allowed(st, from, p.owner)) {
				int u = alliance_utility(f, p, a, al.members(al.group[from])) + (int)(p.next() % 20);
				yes = u >= (al.open[p.owner] ? 35 : 55);
			}
			al.respond(st, p.owner, from, yes);
		}

		// Surrenders offered to us: a vassal's tribute (half its mining for
		// the rest of the game, its army on our side) against the score for
		// destroying what it has left.
		for (int from = 0; from != bw_alliances::max_players; ++from) {
			int sent = al.surrender_frame[p.owner][from];
			if (sent < 0 || frame - sent < 24 * (2 + p.trust % 3)) continue;
			bool yes = false;
			if (al.surrender_allowed(st, from, p.owner)) {
				int conquest = 0;
				for (unit_t* u : ptr(st.player_units.at(from))) {
					if (!f.unit_dead(u)) conquest += u->unit_type->destroy_score;
				}
				int tribute = (al.mineral_rate[from] + al.gas_rate[from]) * 5 + a.army[(size_t)from] / 2;
				bool busy = (al.fighting[p.owner] & ~(1u << from)) != 0;
				yes = tribute + (busy ? conquest / 2 : 0) + p.trust * 20 >= conquest * 6 / 10;
			}
			al.answer_surrender(st, p.owner, from, yes);
		}

		// Losing at home and turned down by the others: offer to surrender to
		// whoever is winning (also after a long hopeless defence).
		if (p.losing && p.attacker >= 0 && frame >= p.next_surrender) {
			bool refused = frame - al.last_declined[p.owner] < 24 * 120;
			bool hopeless = p.losing_since >= 0 && frame - p.losing_since > 24 * 75;
			if ((refused || hopeless) && al.surrender_allowed(st, p.owner, p.attacker) && al.surrender_frame[p.attacker][p.owner] < 0) {
				al.offer_surrender(st, p.owner, p.attacker);
				p.next_surrender = frame + 24 * 60;
				return;
			}
		}

		// The best score comes from winning: once no meaningful enemy is left,
		// turn on a clearly weaker ally (the more trusting wait for a bigger
		// edge) to conquer it.
		if (my_group.size() > 1 && frame >= p.next_betrayal_check && frame > 24 * 60 * 8) {
			p.next_betrayal_check = frame + 24 * 60;
			int outside = 0;
			for (int q = 0; q != 8; ++q) {
				if (al.active(st, q) && !al.same_group(q, p.owner)) outside += a.army[(size_t)q] + a.economy[(size_t)q] / 4;
			}
			auto with_vassals = [&](int who) {
				int v = a.army[(size_t)who] + a.economy[(size_t)who] / 4;
				for (int m : my_group) {
					if (al.lord[m] == who) v += a.army[(size_t)m] + a.economy[(size_t)m] / 4;
				}
				return v;
			};
			int me_strength = with_vassals(p.owner);
			int weakest = -1, weakest_strength = 0;
			for (int m : my_group) {
				if (m == p.owner || al.vassal(m)) continue;
				int sm = with_vassals(m);
				if (weakest < 0 || sm < weakest_strength) {
					weakest = m;
					weakest_strength = sm;
				}
			}
			int edge = 140 + p.trust; // percent
			if (weakest >= 0 && !p.losing && outside * 4 < mine && me_strength * 100 > weakest_strength * edge) {
				if (al.leave(st, p.owner)) {
					p.focus = weakest;
					return;
				}
			}
		}

		// Look for a partner: urgently when losing, otherwise now and then.
		if (frame < p.next_invite) return;
		if (!p.losing && frame < 24 * 60 * 3) return;
		p.next_invite = frame + (p.losing ? 24 * 15 : 24 * (45 + (int)(p.next() % 45)));
		if (!p.losing && (!al.open[p.owner] || my_group.size() >= 3)) return;
		int best = -1000;
		int target = -1;
		std::array<bool, 8> seen{};
		for (int q = 0; q != bw_alliances::max_players; ++q) {
			if (q == p.owner || !al.active(st, q) || al.same_group(q, p.owner) || seen[(size_t)al.group[q]]) continue;
			seen[(size_t)al.group[q]] = true;
			a_vector<int> g = al.members(al.group[q]);
			if (!al.merge_allowed(st, p.owner, q)) continue;
			bool pending = false, receptive = p.losing;
			for (int m : g) {
				if (al.invite_frame[(size_t)m][(size_t)p.owner] >= 0) pending = true;
				if (al.open[m]) receptive = true;
			}
			// Don't pester someone who was just asked.
			for (int m : g) {
				if (p.asked_at[(size_t)m] && frame - (p.asked_at[(size_t)m] - 1) < 24 * 60) pending = true;
			}
			if (pending || !receptive) continue;
			int u = alliance_utility(f, p, a, g);
			if (u <= best) continue;
			// Ask the member closest to us.
			int who = g.front();
			for (int m : g) {
				if (dist2(a.base[(size_t)m], a.base[(size_t)p.owner]) < dist2(a.base[(size_t)who], a.base[(size_t)p.owner])) who = m;
			}
			best = u;
			target = who;
		}
		if (target >= 0 && best >= 40 && al.invite(st, p.owner, target)) p.asked_at[(size_t)target] = frame + 1;
	}

	void think(action_functions& f, player& p) {
		snapshot s = take_snapshot(f, p);
		if (s.depots.empty() && s.workers.empty() && s.army.empty()) return;
		if (!s.depots.empty() && p.rally == p.home) p.rally = rally_point(f, p);

		manage_workers(f, p, s);

		// Money still uncommitted after this round's decisions. With human
		// allies the treasury is common: use only the computers' share.
		int minerals = s.minerals, gas = s.gas;
		if (allies) {
			auto mates = allies->members(allies->group[p.owner]);
			int computers = 0;
			for (int m : mates) {
				for (auto& o : players) {
					if (o.owner == m) ++computers;
				}
			}
			if (computers < (int)mates.size()) {
				minerals = minerals * computers / (int)mates.size();
				gas = gas * computers / (int)mates.size();
			}
		}

		bool supply_ordered = keep_supply(f, p, s, minerals, gas);
		train_workers(f, p, s, minerals, gas);
		if (!supply_ordered) follow_build_order(f, p, s, minerals, gas);
		maybe_expand(f, p, s, minerals, gas);
		research(f, p, s, minerals, gas);
		train_army(f, p, s, minerals, gas);
		command_army(f, p, s);
	}

	xy rally_point(action_functions& f, player& p) {
		xy center((int)f.game_st.map_width / 2, (int)f.game_st.map_height / 2);
		xy d = center - p.home;
		int len = std::max(1, f.xy_length(d));
		return f.restrict_pos_to_map_bounds(p.home + d * 288 / len);
	}

	void manage_workers(action_functions& f, player& p, snapshot& s) {
		// Gas: three workers per finished refinery, newest refinery first
		// (the older ones already have theirs).
		a_vector<unit_t*> refineries;
		for (unit_t* b : s.buildings) {
			if (f.unit_is_refinery(b) && f.u_completed(b)) refineries.push_back(b);
		}
		int want_gas = (int)refineries.size() * 3;
		for (unit_t* w : s.workers) {
			if (s.gas_workers >= want_gas) break;
			auto id = w->order_type->id;
			if (id != Orders::MoveToMinerals && id != Orders::WaitForMinerals && id != Orders::MiningMinerals) continue;
			unit_t* refinery = refineries[(size_t)(s.gas_workers / 3) % refineries.size()];
			if (select(f, p, w)) f.action_default_order(p.owner, refinery->sprite->position, refinery, nullptr, false);
			++s.gas_workers;
		}

		// Idle workers go back to the nearest mineral line.
		for (unit_t* w : s.workers) {
			if (!is_idle(w)) continue;
			unit_t* depot = nullptr;
			int best = 0;
			for (unit_t* d : s.depots) {
				int dd = dist2(d->sprite->position, w->sprite->position);
				if (!depot || dd < best) {
					depot = d;
					best = dd;
				}
			}
			xy from = depot ? depot->sprite->position : w->sprite->position;
			unit_t* mineral = nullptr;
			best = 0;
			for (unit_t* m : ptr(f.st.player_units.at(11))) {
				if (f.unit_dead(m) || !f.unit_is_mineral_field(m)) continue;
				int dd = dist2(m->sprite->position, from);
				if (m->building.resource.is_being_gathered) dd += 128 * 128;
				if (!mineral || dd < best) {
					mineral = m;
					best = dd;
				}
			}
			if (!mineral) continue;
			if (select(f, p, w)) f.action_default_order(p.owner, mineral->sprite->position, mineral, nullptr, false);
		}
	}

	bool keep_supply(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		if (s.supply_max >= 200) return false;
		UnitTypes type = supply_of(p.race);
		int producers = 0;
		for (unit_t* b : s.buildings) {
			if (f.u_completed(b) && (f.unit_is(b, UnitTypes::Terran_Barracks) || f.unit_is(b, UnitTypes::Terran_Factory) || f.unit_is(b, UnitTypes::Protoss_Gateway) || f.ut_resource_depot(b))) ++producers;
		}
		int margin = 2 + producers * 3;
		int in_progress = s.planned[(size_t)type] - s.done[(size_t)type];
		int free_supply = s.supply_max - s.supply_used;
		int wanted_in_progress = free_supply < margin ? (margin > 12 ? 2 : 1) : 0;
		if (in_progress >= wanted_in_progress) return false;
		const unit_type_t* ut = f.get_unit_type(type);
		if (!affordable(ut, minerals, gas)) return true; // save up for it
		bool ok;
		if (p.race == race_t::zerg) {
			ok = morph_larva(f, p, s, ut);
		} else {
			ok = place(f, p, s, type);
		}
		if (ok) minerals -= ut->mineral_cost;
		// No room found: let the build order go on rather than stall.
		return ok;
	}

	bool morph_larva(action_functions& f, player& p, snapshot& s, const unit_type_t* ut) {
		if (s.larvae.empty()) return false;
		unit_t* larva = s.larvae.back();
		s.larvae.pop_back();
		if (!select(f, p, larva)) return false;
		return f.action_morph(p.owner, ut);
	}

	int wanted_workers(action_functions& f, snapshot& s) {
		int refineries = 0;
		for (unit_t* b : s.buildings) {
			if (f.unit_is_refinery(b)) ++refineries;
		}
		int bases = 0;
		for (unit_t* d : s.depots) {
			bool near_minerals = false;
			for (xy site : sites) {
				if (dist2(site, d->sprite->position) < 384 * 384) near_minerals = true;
			}
			if (near_minerals) ++bases;
		}
		return std::min(60, std::max(1, bases) * 16 + refineries * 3);
	}

	void train_workers(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		const unit_type_t* ut = f.get_unit_type(worker_of(p.race));
		int want = wanted_workers(f, s);
		int have = s.planned[(size_t)ut->id];
		if (have >= want) return;
		if (p.race == race_t::zerg) {
			// Drones compete with the army for larvae: keep a balance.
			if (have >= 12 && (int)s.army.size() * 2 < have - 10) return;
			if (!affordable(ut, minerals, gas)) return;
			if (s.supply_used + 1 > s.supply_max) return;
			if (morph_larva(f, p, s, ut)) minerals -= ut->mineral_cost;
			return;
		}
		for (unit_t* d : s.depots) {
			if (have >= want || !affordable(ut, minerals, gas)) break;
			if (!d->build_queue.empty()) continue;
			if (s.supply_used + 1 > s.supply_max) break;
			if (select(f, p, d) && f.action_train(p.owner, ut)) {
				minerals -= ut->mineral_cost;
				++have;
				++s.supply_used;
			}
		}
	}

	void follow_build_order(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		for (auto& step : build_order(p.race)) {
			if (s.supply_used < step.supply) break;
			if (s.planned[(size_t)step.type] >= step.count) continue;
			const unit_type_t* ut = f.get_unit_type(step.type);
			if (!affordable(ut, minerals, gas)) {
				// Save for this step instead of spending on units.
				minerals -= ut->mineral_cost;
				gas -= ut->gas_cost;
				return;
			}
			bool ok = false;
			if (step.type == UnitTypes::Zerg_Lair) {
				for (unit_t* b : s.depots) {
					if (!f.unit_is(b, UnitTypes::Zerg_Hatchery) || !b->build_queue.empty()) continue;
					if (select(f, p, b)) ok = f.action_morph_building(p.owner, ut);
					break;
				}
			} else {
				// Requirements (e.g. Cybernetics Core needs a Gateway) are
				// checked by OpenBW against any worker.
				unit_t* any_worker = s.workers.empty() ? nullptr : s.workers.front();
				if (!any_worker || !f.unit_can_build(any_worker, ut)) continue;
				ok = place(f, p, s, step.type);
			}
			if (ok) {
				minerals -= ut->mineral_cost;
				gas -= ut->gas_cost;
			}
			return; // one building per decision
		}
		// Later on, take the gas at every base.
		if (f.st.current_frame > 24 * 60 * 9) {
			int refineries = s.planned[(size_t)gas_of(p.race)];
			if (refineries < (int)s.depots.size()) {
				const unit_type_t* ut = f.get_unit_type(gas_of(p.race));
				if (affordable(ut, minerals, gas) && place(f, p, s, gas_of(p.race))) minerals -= ut->mineral_cost;
			}
		}
	}

	void maybe_expand(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		int frame = f.st.current_frame;
		int wanted_bases = 1 + (frame > 24 * 60 * 7 ? 1 : 0) + (frame > 24 * 60 * 14 ? 1 : 0) + (frame > 24 * 60 * 22 ? 1 : 0);
		UnitTypes depot_type = depot_of(p.race);
		const unit_type_t* ut = f.get_unit_type(depot_type);
		int owned_sites = 0;
		for (xy site : sites) {
			for (unit_t* b : s.buildings) {
				if (f.ut_resource_depot(b) && dist2(site, b->sprite->position) < 384 * 384) {
					++owned_sites;
					break;
				}
			}
		}
		if (owned_sites >= wanted_bases) return;
		// A town hall already on its way?
		for (unit_t* w : s.workers) {
			if (is_build_order(w->order_type->id) && !w->build_queue.empty() && w->build_queue.front() == ut) return;
		}
		if (!affordable(ut, minerals, gas)) {
			minerals -= ut->mineral_cost;
			return;
		}
		// Nearest free site to the home base.
		xy target;
		bool found = false;
		int best = 0;
		for (xy site : sites) {
			bool taken = false;
			for (int owner = 0; owner != 8 && !taken; ++owner) {
				for (unit_t* b : ptr(f.st.player_units.at(owner))) {
					if (f.ut_building(b) && dist2(site, b->sprite->position) < 448 * 448) {
						taken = true;
						break;
					}
				}
			}
			if (taken) continue;
			int d = dist2(site, p.home);
			if (!found || d < best) {
				target = site;
				best = d;
				found = true;
			}
		}
		if (!found) return;
		unit_t* builder = pick_builder(f, s, target);
		if (!builder) return;
		if (!f.player_position_is_explored(p.owner, target)) {
			// Placement needs explored ground: walk there first.
			if (frame - p.expand_worker_frame > 24 * 30 && select(f, p, builder)) {
				f.action_order(p.owner, f.get_order_type(Orders::Move), target, nullptr, nullptr, false);
				p.expand_worker_frame = frame;
			}
			return;
		}
		// The closest legal spot to the resources' center.
		int cx = target.x / 32, cy = target.y / 32;
		int w = ut->placement_size.x / 32, h = ut->placement_size.y / 32;
		bool have = false;
		xy_t<size_t> tile;
		int best_d = 0;
		for (int dy = -10; dy <= 10; ++dy) {
			for (int dx = -10; dx <= 10; ++dx) {
				int tx = cx + dx - w / 2, ty = cy + dy - h / 2;
				if (tx < 0 || ty < 0) continue;
				xy pos(tx * 32 + ut->placement_size.x / 2, ty * 32 + ut->placement_size.y / 2);
				int d = dist2(pos, target);
				if (have && d >= best_d) continue;
				if (!f.can_place_building(builder, p.owner, ut, pos, false, false)) continue;
				tile = xy_t<size_t>((size_t)tx, (size_t)ty);
				best_d = d;
				have = true;
			}
		}
		if (!have || !select(f, p, builder)) return;
		if (f.action_build(p.owner, build_order_for(f, builder), ut, tile)) minerals -= ut->mineral_cost;
	}

	void research(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		for (auto& r : research_order(p.race)) {
			if (s.supply_used < r.supply) continue;
			for (unit_t* b : s.buildings) {
				if (!f.unit_is(b, r.building) || !f.u_completed(b)) continue;
				if (b->building.researching_type || b->building.upgrading_type || !b->build_queue.empty()) continue;
				if (r.is_tech) {
					const tech_type_t* t = f.get_tech_type((TechTypes)r.id);
					if (!f.unit_can_research(b, t, p.owner)) continue;
					if (minerals < t->mineral_cost || gas < t->gas_cost) return;
					if (select(f, p, b) && f.action_research(p.owner, t)) {
						minerals -= t->mineral_cost;
						gas -= t->gas_cost;
					}
				} else {
					const upgrade_type_t* t = f.get_upgrade_type((UpgradeTypes)r.id);
					if (!f.unit_can_upgrade(b, t, p.owner)) continue;
					int mc = f.upgrade_mineral_cost(p.owner, t), gc = f.upgrade_gas_cost(p.owner, t);
					if (minerals < mc || gas < gc) return;
					if (select(f, p, b) && f.action_upgrade(p.owner, t)) {
						minerals -= mc;
						gas -= gc;
					}
				}
				break;
			}
		}
	}

	int count_army(snapshot& s, UnitTypes t) {
		return s.planned[(size_t)t];
	}

	void train_army(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		if (minerals < 50) return;
		if (p.race == race_t::zerg) {
			while (!s.larvae.empty() && minerals >= 50) {
				UnitTypes t = UnitTypes::Zerg_Zergling;
				int lings = count_army(s, UnitTypes::Zerg_Zergling);
				int hydras = count_army(s, UnitTypes::Zerg_Hydralisk);
				int mutas = count_army(s, UnitTypes::Zerg_Mutalisk);
				if (s.done[(size_t)UnitTypes::Zerg_Spire] && gas >= 100 && mutas * 3 < hydras + lings) t = UnitTypes::Zerg_Mutalisk;
				else if (s.done[(size_t)UnitTypes::Zerg_Hydralisk_Den] && gas >= 25 && hydras < lings) t = UnitTypes::Zerg_Hydralisk;
				const unit_type_t* ut = f.get_unit_type(t);
				if (!affordable(ut, minerals, gas)) return;
				if (s.supply_used + (int)(ut->supply_required.raw_value / 2) > s.supply_max) return;
				unit_t* larva = s.larvae.back();
				if (!f.unit_can_build(larva, ut)) return;
				if (!morph_larva(f, p, s, ut)) return;
				minerals -= ut->mineral_cost;
				gas -= ut->gas_cost;
				s.supply_used += std::max(1, (int)(ut->supply_required.raw_value / 2));
				bump(s.planned, ut);
			}
			return;
		}
		for (unit_t* b : s.buildings) {
			if (!f.u_completed(b) || !b->build_queue.empty()) continue;
			UnitTypes t = UnitTypes::None;
			if (f.unit_is(b, UnitTypes::Terran_Barracks)) {
				int marines = count_army(s, UnitTypes::Terran_Marine);
				t = UnitTypes::Terran_Marine;
				if (s.done[(size_t)UnitTypes::Terran_Academy]) {
					if (count_army(s, UnitTypes::Terran_Medic) * 5 < marines && gas >= 25) t = UnitTypes::Terran_Medic;
					else if (count_army(s, UnitTypes::Terran_Firebat) * 5 < marines && gas >= 25) t = UnitTypes::Terran_Firebat;
				}
			} else if (f.unit_is(b, UnitTypes::Terran_Factory)) {
				if (!b->building.addon) {
					build_addon(f, p, b, minerals, gas);
					continue;
				}
				t = f.u_completed(b->building.addon) && gas >= 100 ? UnitTypes::Terran_Siege_Tank_Tank_Mode : UnitTypes::Terran_Vulture;
			} else if (f.unit_is(b, UnitTypes::Protoss_Gateway)) {
				t = UnitTypes::Protoss_Zealot;
				if (s.done[(size_t)UnitTypes::Protoss_Cybernetics_Core] && gas >= 50 &&
				    count_army(s, UnitTypes::Protoss_Dragoon) <= count_army(s, UnitTypes::Protoss_Zealot) * 2) t = UnitTypes::Protoss_Dragoon;
			}
			if (t == UnitTypes::None) continue;
			const unit_type_t* ut = f.get_unit_type(t);
			if (!affordable(ut, minerals, gas)) continue;
			int supply = (int)(ut->supply_required.raw_value / 2);
			if (s.supply_used + supply > s.supply_max) return;
			if (select(f, p, b) && f.action_train(p.owner, ut)) {
				minerals -= ut->mineral_cost;
				gas -= ut->gas_cost;
				s.supply_used += supply;
				bump(s.planned, ut);
			}
		}
	}

	void build_addon(action_functions& f, player& p, unit_t* b, int& minerals, int& gas) {
		const unit_type_t* ut = f.get_unit_type(UnitTypes::Terran_Machine_Shop);
		if (!affordable(ut, minerals, gas) || !f.unit_can_build(b, ut)) return;
		xy top_left = b->sprite->position - b->unit_type->placement_size / 2;
		xy_t<size_t> tile((size_t)((top_left.x + ut->addon_position.x) / 32), (size_t)((top_left.y + ut->addon_position.y) / 32));
		if (select(f, p, b) && f.action_build(p.owner, f.get_order_type(Orders::PlaceAddon), ut, tile)) {
			minerals -= ut->mineral_cost;
			gas -= ut->gas_cost;
		}
	}

	// Nearest enemy unit to `pos` (buildings only if `buildings_only`).
	unit_t* nearest_enemy(action_functions& f, player& p, xy pos, bool buildings_only, int max_dist) {
		unit_t* best = nullptr;
		int best_d = 0;
		for (int owner = 0; owner != 8; ++owner) {
			if (!is_enemy(f, p.owner, owner)) continue;
			for (unit_t* u : ptr(f.st.player_units.at(owner))) {
				if (f.unit_dead(u) || !u->sprite || f.us_hidden(u)) continue;
				if (buildings_only && !f.ut_building(u)) continue;
				int d = dist2(u->sprite->position, pos);
				if (max_dist > 0 && d > max_dist * max_dist) continue;
				if (!best || d < best_d) {
					best = u;
					best_d = d;
				}
			}
		}
		return best;
	}

	void command_army(action_functions& f, player& p, snapshot& s) {
		int frame = f.st.current_frame;

		// Defend: enemies close to any of our buildings.
		unit_t* intruder = nullptr;
		for (unit_t* b : s.buildings) {
			intruder = nearest_enemy(f, p, b->sprite->position, false, 512);
			if (intruder) break;
		}
		if (intruder && !p.attacking) {
			a_vector<unit_t*> idle;
			for (unit_t* u : s.army) {
				if (is_idle(u) || u->order_type->id == Orders::Move) idle.push_back(u);
			}
			if (!idle.empty()) order_group(f, p, idle, Orders::AttackMove, intruder->sprite->position);
			return;
		}

		if (!p.attacking) {
			if ((int)s.army.size() >= p.wave_size) {
				p.attacking = true;
				p.last_attack_order = -10000;
			} else {
				// Gather idle units at the rally point.
				a_vector<unit_t*> stray;
				for (unit_t* u : s.army) {
					if (is_idle(u) && dist2(u->sprite->position, p.rally) > 192 * 192) stray.push_back(u);
				}
				if (!stray.empty()) order_group(f, p, stray, Orders::Move, p.rally);
				return;
			}
		}

		// Attacking: the wave ends once most of it is gone.
		if ((int)s.army.size() < std::max(2, p.wave_size / 4)) {
			p.attacking = false;
			p.wave_size = std::min(40, p.wave_size + 4);
			return;
		}
		unit_t* target = nullptr;
		// A former ally we turned on comes first.
		if (p.focus >= 0 && is_enemy(f, p.owner, p.focus)) {
			int best = 0;
			for (unit_t* u : ptr(f.st.player_units.at(p.focus))) {
				if (f.unit_dead(u) || !u->sprite || !f.ut_building(u)) continue;
				int d = dist2(u->sprite->position, p.home);
				if (!target || d < best) {
					target = u;
					best = d;
				}
			}
		} else {
			p.focus = -1;
		}
		if (!target) target = nearest_enemy(f, p, p.home, true, 0);
		if (!target) target = nearest_enemy(f, p, p.home, false, 0);
		if (!target) return;
		bool refresh = frame - p.last_attack_order > 24 * 20;
		a_vector<unit_t*> group;
		for (unit_t* u : s.army) {
			if (refresh || is_idle(u) || u->order_type->id == Orders::Move) group.push_back(u);
		}
		if (refresh) p.last_attack_order = frame;
		if (!group.empty()) order_group(f, p, group, Orders::AttackMove, target->sprite->position);
	}
};

} // namespace bw_ai

#endif // BW_AI_H
