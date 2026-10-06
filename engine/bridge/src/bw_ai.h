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
// Auto-play: the same player can run for a human, limited to the parts the
// human picks (modes below: resources, building, attacking, colonizing, or
// all of them). It then leaves alone every unit the human commanded in the
// last minute or keeps in a control group, never touches the human's
// selection and doesn't negotiate alliances.
//
// It only ever commands its own units: OpenBW refuses orders for anyone
// else's, and only the human player is given allies' units to command (in
// bw_bridge.cpp). Units a human ally took over recently are left alone, and
// sharing a treasury with a human it spends only its share of it.
//
// Bot profiles (docs/bot_profiles.md, botscript.h) change how a player
// plays: its numbers and tables (bw_ai_params.h), and scripts that make
// decisions at the events fired here (think, attack waves, invitations,
// surrenders, betrayal, helping allies). Without one it plays as always.
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
#include "botscript.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>

namespace bw_ai {

using namespace bwgame;

static const int think_interval = 12; // frames between decisions (about 0.5 s)
static const int human_command_hold = 24 * 60; // frames a human-commanded unit is left alone

// What a player (or auto-play) takes care of. Mirrors BW_AUTOPLAY_* in bw_bridge.h.
enum mode : int {
	mode_resources = 1,  // workers on minerals and gas, more workers, supply
	mode_building = 2,   // the build order, upgrades, supply
	mode_attacking = 4,  // army, defence and attack waves
	mode_colonizing = 8, // new bases with workers and defences
	mode_all = 15,
};

// Everything about a player that is plain data: saved games copy it as is
// (bw_snapshot.h). The lists are in `player`.
struct player_state {
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
	bool human = false; // auto-play for a human player
	int modes = mode_all;
	int next_balance = 0;
	int next_defense = 0;
	int next_fortify = 0;
	// Defensive mode: a detachment sent to an ally under attack stays by it.
	bool fortifying = false;
	bool colony_mode = false; // colonizing without attacking: colonies dig in
	int next_colony = 0;
	int next_colony_units = 0;
	int guard_ally = -1;          // the ally it guards, -1 none
	xy guard_pos;                 // where it waits between attacks
	xy help_target;               // the current threat to the ally
	int help_until = -1;          // that threat is fresh until this frame
	int next_ally_check = 0;
	int last_help_order = -10000;
	int militia_until = -1; // workers pulled into a fight: send them back afterwards
	int threat_until = -1;  // the base was attacked recently
	// Version 2 (see ai_system::version).
	int next_intel = 0;
	bool island = false;      // no enemy base can be reached on the ground
	bool some_island = false; // some can't
	int enemy_air = 0;        // value of the enemies' flying army
	int enemy_cloaked = 0;    // value of enemy units that need detection
	int next_air_defense = 0;
	int last_nuke = -100000;
	int next_scan = 0;
	uint32_t expander = 0; // a worker ferried to build a town hall
	int next_base = 0;
	// Bot profile (botscript.h): the numbers it plays by, its script's
	// variables, and the plan, research and mix variants in use.
	ai_tunables cfg;
	std::array<int32_t, botscript::max_globals> vars{};
	int plan_variant = 0, research_variant = 0, mix_variant = 0;
	int hold_until = -1; // no attack wave before this frame (steered from outside)

	uint32_t next() {
		rng = rng * 1103515245u + 12345u;
		return (rng >> 16) & 0x7fff;
	}
};

struct player : player_state {
	a_vector<uint32_t> detached;  // unit ids (generation-checked) of the detachment
	struct drop {
		uint32_t transport = 0;
		a_vector<uint32_t> passengers;
		xy landing, target;
		int phase = 0; // 0 loading, 1 flying to the landing spot
		int started = 0;
		int last_order = 0;
		bool expand = false; // carries a worker to a new base's island
	};
	a_vector<drop> drops;
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
	// The bridge's control groups: units a human keeps in one are theirs.
	const std::array<std::array<a_vector<unit_id>, 10>, 8>* groups = nullptr;
	a_vector<size_t> grouped; // unit indices in the thinking human's groups
	// 2: the whole tech tree, spells, nukes, drops, air play on island maps
	// (new games); 1: the earlier player, kept for saved games made with it.
	int version = 2;
	bool thinking_human = false;
	bool relaxed_placement = false;
	a_vector<int> cast_frame; // by unit index: when it last used an ability
	// Bot profiles by player slot (none: the standard player). Set before
	// the players are added, like the rest of the game's setup.
	std::array<std::shared_ptr<const botscript::profile>, 8> slot_profile;

	// Turns auto-play for a human player on (with modes) or off (0).
	void set_autoplay(int owner, race_t race, uint32_t seed, xy home, int modes) {
		for (auto& p : players) {
			if (p.owner != owner) continue;
			if (!p.human) return; // a computer player plays everything anyway
			p.modes = modes;
			return;
		}
		if (modes == 0) return;
		add(owner, race, seed, home);
		players.back().human = true;
		players.back().modes = modes;
	}

	// Multiplayer: a human takes over a computer player (human = true; it
	// stops playing, auto-play off), or hands its slot back (the computer
	// plays it fully again).
	void set_controller(int owner, race_t race, uint32_t seed, xy home, bool human) {
		for (auto& p : players) {
			if (p.owner != owner) continue;
			p.human = human;
			p.modes = human ? 0 : mode_all;
			return;
		}
		if (human) return;
		add(owner, race, seed, home);
	}

	int autoplay(int owner) const {
		for (auto& p : players) {
			if (p.owner == owner && p.human) return p.modes;
		}
		return 0;
	}

	void human_commanded(const unit_t* u, int frame) {
		if (human_frame.size() <= u->index) human_frame.resize(u->index + 1, -100000);
		human_frame[u->index] = frame;
	}

	bool held_by_human(const unit_t* u, int frame) const {
		if (u->index < human_frame.size() && frame - human_frame[u->index] < human_command_hold) return true;
		if (std::find(grouped.begin(), grouped.end(), u->index) != grouped.end()) return true;
		// A unit the human told to follow one of their own units (an escort,
		// support for a group) stays on that job however long it lasts.
		if (version >= 2 && thinking_human && u->order_target.unit && u->order_target.unit != u && u->order_target.unit->owner == u->owner) {
			auto id = u->order_type->id;
			if (id == Orders::Follow || id == Orders::Move || id == Orders::Guard) return true;
		}
		return false;
	}

	void add(int owner, race_t race, uint32_t seed, xy home) {
		player p;
		p.owner = owner;
		p.race = race;
		p.rng = seed * 2654435761u + (uint32_t)owner * 40503u + 1;
		p.home = home;
		p.rally = home;
		// The profile's set statements and variables first: they may change
		// the numbers below.
		if (auto* pr = profile_of(p)) {
			for (int fn : pr->init) run_script(nullptr, p, nullptr, fn, nullptr, 0);
		}
		p.trust = p.cfg.personality.trust_min + (int)(p.next() % (uint32_t)p.cfg.personality.trust_span);
		p.next_invite = p.cfg.diplomacy.first_invite + (int)(p.next() % (uint32_t)p.cfg.diplomacy.first_invite_spread);
		p.wave_size = p.cfg.army.wave_first;
		players.push_back(p);
	}

	void clear() {
		players.clear();
		sites.clear();
		sites_ready = false;
		human_frame.clear();
		cast_frame.clear();
		version = 2;
		for (auto& pr : slot_profile) pr.reset();
	}

	// Steering from outside (bw_bridge_bot_steer, logged): an agent or a
	// person directing this computer player, or a human's auto-play.
	enum steer_t : int { steer_attack = 1, steer_hold = 2, steer_focus = 3, steer_number = 4, steer_wave = 5 };
	bool steer(int owner, int what, int a, int b, int frame) {
		for (auto& p : players) {
			if (p.owner != owner) continue;
			switch (what) {
			case steer_attack: // the next wave goes now
				p.hold_until = -1;
				p.attacking = true;
				p.last_attack_order = -10000;
				return true;
			case steer_hold: // the army comes home and waits `a` seconds
				p.attacking = false;
				p.hold_until = frame + std::max(0, a) * 24;
				return true;
			case steer_focus:
				p.focus = a >= 0 && a < 8 && a != owner ? a : -1;
				return true;
			case steer_number: {
				auto& names = tunable_names();
				if (a < 0 || (size_t)a >= names.size()) return false;
				tunable_at(p.cfg, names[(size_t)a].offset) = botscript::wrap((int64_t)b * names[(size_t)a].scale);
				botscript::sanitize(p.cfg);
				return true;
			}
			case steer_wave:
				p.wave_size = std::max(1, a);
				return true;
			default: return false;
			}
		}
		return false;
	}

	const botscript::profile* profile_of(const player_state& p) const {
		return p.owner >= 0 && p.owner < 8 ? slot_profile[(size_t)p.owner].get() : nullptr;
	}

	// The variables of profiles' scripts, for the multiplayer sync check
	// (0 without any).
	uint32_t script_hash() const {
		uint32_t h = 0;
		for (auto& p : players) {
			auto* pr = profile_of(p);
			if (!pr || pr->globals.empty()) continue;
			for (size_t i = 0; i != pr->globals.size(); ++i) h = (h ^ (uint32_t)p.vars[i]) * 16777619u;
		}
		return h;
	}

	void update(state& st, action_state& action_st) {
		if (players.empty()) return;
		action_functions f(st, action_st);
		if (!sites_ready) find_sites(f);
		int frame = st.current_frame;
		for (auto& p : players) {
			if ((frame + p.owner * 3) % think_interval != 0) continue;
			if (p.human && p.modes == 0) continue;
			// Defeated (its units turned neutral) or already won.
			if (st.players[p.owner].controller != player_t::controller_occupied || st.players[p.owner].victory_state >= 3) continue;
			// A human's selection stays as the human left it.
			auto selection = action_st.selection.at(p.owner);
			grouped.clear();
			thinking_human = p.human;
			if (p.human && groups) {
				for (auto& g : groups->at(p.owner)) {
					for (unit_id id : g) {
						if (unit_t* u = f.get_unit(id)) grouped.push_back(u->index);
					}
				}
			}
			try {
				if (allies && !p.human) diplomacy(f, p);
				think(f, p);
			} catch (...) {
				// A failed decision must never stop the game; try again next time.
			}
			action_st.selection.at(p.owner) = selection;
			grouped.clear();
			// Fold this player's spending into its alliance's treasury
			// before the next one decides.
			if (allies) allies->sync(st);
		}
	}

private:
	// --- static data -------------------------------------------------------------

	static const int supply_cap = 2000; // the engine's limit (the original's was 200)

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

	// Also a drone on its way to the spot (version 2; the earlier player
	// missed these and kept sending the same drone elsewhere).
	bool building_order(Orders id) const {
		return is_build_order(id) || (version >= 2 && (id == Orders::DroneLand || id == Orders::DroneBuild));
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
		int reserved_minerals = 0; // buildings whose worker is still on the way
		int reserved_gas = 0;
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
				if (building_order(u->order_type->id) && !u->build_queue.empty()) {
					bump(s.planned, u->build_queue.front());
					// Paid only when placed: keep the money for it.
					s.reserved_minerals += u->build_queue.front()->mineral_cost;
					s.reserved_gas += u->build_queue.front()->gas_cost;
				}
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
		s.planned[(size_t)UnitTypes::Zerg_Spire] += s.planned[(size_t)UnitTypes::Zerg_Greater_Spire];
		s.done[(size_t)UnitTypes::Zerg_Spire] += s.done[(size_t)UnitTypes::Zerg_Greater_Spire];
		s.minerals = st.current_minerals[p.owner];
		s.gas = st.current_gas[p.owner];
		s.supply_used = st.supply_used[p.owner][race].raw_value / 2;
		s.supply_max = std::min(supply_cap, (int)(st.supply_available[p.owner][race].raw_value / 2));
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
		// Relaxed (a crowded base, version 2): buildings may touch, and only
		// the ground right by the minerals stays free.
		int gap = relaxed_placement ? 0 : 32, berth = relaxed_placement ? 48 : 96;
		rect lane{r.from - xy(gap, gap), r.to + xy(gap, gap)};
		if (ut->id == UnitTypes::Terran_Factory || ut->id == UnitTypes::Terran_Command_Center) lane.to.x += 64;
		rect keep_off{r.from - xy(berth, berth), r.to + xy(berth, berth)};
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
			if (building_order(id) || is_gas_order(id) || id == Orders::ConstructingBuilding) continue;
			if (w->order_type->id == Orders::Move) continue; // already sent somewhere
			// (Version 2: only one that can walk there, islands being islands.)
			if (version >= 2 && !f.is_reachable(w->sprite->position, near)) continue;
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
		xy center = s.depots.empty() ? p.home : s.depots.front()->sprite->position;
		if (version < 2) return place_near(f, p, s, type, center, type == supply_of(p.race) ? 3 : 4, 16);
		// Version 2: the main base first, then the others (a small island
		// fills up). Refineries go to a free geyser at any base.
		if (type == gas_of(p.race)) return place_gas(f, p, s);
		for (bool relaxed : {false, true}) {
			relaxed_placement = relaxed;
			int reach = relaxed ? 26 : 16; // tiles from the town hall
			bool ok = place_near(f, p, s, type, center, type == supply_of(p.race) ? 3 : 4, reach);
			for (unit_t* d : s.depots) {
				if (ok) break;
				if (d == s.depots.front()) continue;
				ok = place_near(f, p, s, type, d->sprite->position, type == supply_of(p.race) ? 3 : 4, reach - 4);
			}
			relaxed_placement = false;
			if (ok) return true;
		}
		return false;
	}

	bool place_gas(action_functions& f, player& p, snapshot& s) {
		const unit_type_t* ut = f.get_unit_type(gas_of(p.race));
		for (unit_t* d : s.depots) {
			for (unit_t* g : ptr(f.st.player_units.at(11))) {
				if (f.unit_dead(g) || !f.unit_is(g, UnitTypes::Resource_Vespene_Geyser)) continue;
				if (dist2(g->sprite->position, d->sprite->position) > 384 * 384) continue;
				unit_t* builder = pick_builder(f, s, g->sprite->position);
				if (!builder) continue;
				xy top_left = g->sprite->position - ut->placement_size / 2;
				xy_t<size_t> tile((size_t)(top_left.x / 32), (size_t)(top_left.y / 32));
				if (!select(f, p, builder)) return false;
				return f.action_build(p.owner, build_order_for(f, builder), ut, tile);
			}
		}
		return false;
	}

	bool place_near(action_functions& f, player& p, snapshot& s, UnitTypes type, xy center, int min_r, int max_r) {
		const unit_type_t* ut = f.get_unit_type(type);
		unit_t* builder = pick_builder(f, s, center);
		if (!builder) return false;
		xy_t<size_t> tile;
		if (type == gas_of(p.race)) {
			if (!find_geyser(f, p, s, ut, tile)) return false;
		} else {
			if (!find_spot(f, p, builder, ut, center, min_r, max_r, tile)) return false;
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
		auto& c = p.cfg.diplomacy;
		int u = (p.trust - c.trust_center) / c.trust_div;
		// Neighbours make the most useful allies (and the worst enemies).
		int d = a.map_diagonal;
		for (int m : g) d = std::min(d, f.xy_length(a.base[(size_t)m] - a.base[(size_t)p.owner]));
		int closeness = 100 - std::min(100, d * 100 / a.map_diagonal);
		u += closeness / c.closeness_div;
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
			if (has_attacker) u += c.peace; // peace with whoever is winning against us
			else {
				int threat = 0;
				for (int q = 0; q != 8; ++q) threat += a.near_me[(size_t)q];
				if (theirs >= threat) u += c.helper + closeness / c.closeness_div; // they can come and help
			}
		} else {
			if (mine > 0 && mine * 100 > std::max(strongest, theirs) * c.dominant_pct) u -= c.dominant; // we don't need anyone
			if (theirs * c.dead_weight_ratio < mine) u -= c.dead_weight;                                    // they'd be dead weight
			// Winning a fight against them right now: no reason to stop.
			int beating = 0;
			for (int m : g) beating += allies->value_lost_to[(size_t)m][(size_t)p.owner];
			if (beating > 0 && p.pressure[(size_t)g.front()] == 0 && beating > c.beating_value) u -= c.beating;
		}
		if (strongest * 100 > mine * c.common_enemy_pct && strongest > theirs) u += c.common_enemy; // a common stronger enemy
		// Allies share mining points: partners who mine a lot are worth more.
		int my_rate = 0, their_rate = 0;
		for (int m : my_group) {
			if (!al.vassal(m)) my_rate += al.mineral_rate[m] + al.gas_rate[m];
		}
		for (int m : g) {
			if (!al.vassal(m)) their_rate += al.mineral_rate[m] + al.gas_rate[m];
		}
		if (their_rate > 0) u += std::min(c.mining_max, their_rate * c.mining_scale / std::max(1, my_rate));
		if (theirs > mine * 2 && !p.losing) u += c.strong_ally;                   // safety with the strong
		return u;
	}

	void diplomacy(action_functions& f, player& p) {
		auto& al = *allies;
		auto& c = p.cfg.diplomacy;
		state& st = f.st;
		if (!al.active(st, p.owner) || al.vassal(p.owner)) return;
		int frame = st.current_frame;
		if (!p.diplomacy_started) {
			p.diplomacy_started = true;
			if (p.trust >= c.open_trust) al.set_open(st, p.owner, true);
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
		p.losing = threat > c.losing_threat && threat * 100 > a.my_home_army * c.losing_pct && recent > c.losing_losses;
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
			bool want_open = p.losing || others_best * 100 > mine * c.outmatched_pct || (p.trust >= c.open_trust && !(mine > others_best * 2 && p.trust < c.closed_trust));
			if (want_open != al.open[p.owner]) {
				al.set_open(st, p.owner, want_open);
				p.next_open_change = frame + c.open_check;
			}
		}

		// Answer invitations after a moment's thought.
		for (int from = 0; from != bw_alliances::max_players; ++from) {
			int sent = al.invite_frame[p.owner][from];
			if (sent < 0 || frame - sent < 24 * (3 + p.trust % 5)) continue;
			bool yes = false;
			if (al.merge_allowed(st, from, p.owner)) {
				int u = alliance_utility(f, p, a, al.members(al.group[from])) + (int)(p.next() % (uint32_t)c.accept_noise);
				yes = u >= (al.open[p.owner] ? c.accept_open : c.accept_closed);
				auto r = fire(f, p, nullptr, botscript::h_invite, {from});
				if (r.value) yes = r.v != 0;
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
				int tribute = (al.mineral_rate[from] + al.gas_rate[from]) * c.tribute_rate + a.army[(size_t)from] / c.tribute_army_div;
				bool busy = (al.fighting[p.owner] & ~(1u << from)) != 0;
				yes = tribute + (busy ? conquest / 2 : 0) + p.trust * c.tribute_trust >= conquest * c.conquest_pct / 100;
				auto r = fire(f, p, nullptr, botscript::h_surrender_offer, {from, tribute, conquest});
				if (r.value) yes = r.v != 0;
			}
			al.answer_surrender(st, p.owner, from, yes);
		}

		// Losing at home and turned down by the others: offer to surrender to
		// whoever is winning (also after a long hopeless defence).
		if (p.losing && p.attacker >= 0 && frame >= p.next_surrender) {
			bool refused = frame - al.last_declined[p.owner] < c.refused_window;
			bool hopeless = p.losing_since >= 0 && frame - p.losing_since > c.hopeless_after;
			bool offer = refused || hopeless;
			if (al.surrender_allowed(st, p.owner, p.attacker) && al.surrender_frame[p.attacker][p.owner] < 0) {
				auto r = fire(f, p, nullptr, botscript::h_surrender, {p.attacker});
				if (r.value) offer = r.v != 0;
			} else {
				offer = false;
			}
			if (offer) {
				al.offer_surrender(st, p.owner, p.attacker);
				p.next_surrender = frame + c.surrender_retry;
				return;
			}
		}

		// The best score comes from winning: once no meaningful enemy is left,
		// turn on a clearly weaker ally (the more trusting wait for a bigger
		// edge) to conquer it.
		if (my_group.size() > 1 && frame >= p.next_betrayal_check && frame > c.betray_after) {
			p.next_betrayal_check = frame + c.betray_check;
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
			int edge = c.betray_edge + p.trust; // percent
			bool betray = weakest >= 0 && !p.losing && outside * c.betray_outside < mine && me_strength * 100 > weakest_strength * edge;
			if (weakest >= 0) {
				auto r = fire(f, p, nullptr, botscript::h_betray, {weakest});
				if (r.value) betray = r.v != 0;
			}
			if (betray) {
				if (al.leave(st, p.owner)) {
					p.focus = weakest;
					return;
				}
			}
		}

		// Look for a partner: urgently when losing, otherwise now and then.
		// (With a human in the alliance, the humans decide who joins.)
		if (al.capped && al.human_in(al.group[p.owner]) >= 0) return;
		if (frame < p.next_invite) return;
		if (!p.losing && frame < c.first_invite) return;
		p.next_invite = frame + (p.losing ? c.invite_losing : c.invite_interval + 24 * (int)(p.next() % (uint32_t)c.invite_spread));
		int size = al.capped ? al.free_members(al.group[p.owner]) : (int)my_group.size();
		if (!p.losing && (!al.open[p.owner] || size >= bw_alliances::alliance_system::max_members)) return;
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
				if (p.asked_at[(size_t)m] && frame - (p.asked_at[(size_t)m] - 1) < c.no_pester) pending = true;
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
		if (target >= 0 && best >= c.invite_utility && al.invite(st, p.owner, target)) p.asked_at[(size_t)target] = frame + 1;
	}

	void think(action_functions& f, player& p) {
		if (version >= 2) {
			think2(f, p);
			return;
		}
		snapshot s = take_snapshot(f, p);
		if (s.depots.empty() && s.workers.empty() && s.army.empty()) return;
		if (!s.depots.empty() && p.rally == p.home) p.rally = rally_point(f, p);

		bool resources = p.modes & mode_resources, building = p.modes & mode_building;
		bool attacking = p.modes & mode_attacking, colonizing = p.modes & mode_colonizing;
		// Defensive mode (a human ally's switch): no attack waves; the army
		// stays home and the bases are fortified against ground and air.
		bool fortifying = !p.human && allies && allies->defensive_for(p.owner);
		if (fortifying) attacking = false;
		if (!fortifying && p.fortifying) {
			p.detached.clear();
			p.guard_ally = -1;
		}
		p.fortifying = fortifying;
		// Survival comes before the chosen job (see defend()).
		unit_t* intruder = p.human ? find_intruder(f, p, s) : nullptr;
		// Warned early by an enemy army on its way, not just at the gates.
		if (intruder || (p.human && find_intruder(f, p, s, p.cfg.defense.warning_range))) p.threat_until = f.st.current_frame + p.cfg.defense.threat_hold;
		// Under attack (and for a while after): the army there is, and the
		// nearby workers, defend (command_army, defend()). Units are only
		// trained in the attacking mode: an auto-play without it spending the
		// player's money on an army was not what the player picked.
		bool threatened = f.st.current_frame < p.threat_until;
		if (resources || f.st.current_frame < p.militia_until + 24 * 30) manage_workers(f, p, s);
		if (resources) balance_workers(f, p, s);

		// Money still uncommitted after this round's decisions. Sharing a
		// treasury with a human: use only the computers' share.
		int minerals = s.minerals - s.reserved_minerals, gas = s.gas - s.reserved_gas;
		if (allies && !p.human) {
			auto mates = allies->pool(p.owner);
			int computers = 0;
			for (int m : mates) {
				for (auto& o : players) {
					if (o.owner == m && !o.human) ++computers;
				}
			}
			if (computers < (int)mates.size()) {
				minerals = minerals * computers / (int)mates.size();
				gas = gas * computers / (int)mates.size();
			}
		}

		bool supply_ordered = keep_supply(f, p, s, minerals, gas);
		if (resources || colonizing) train_workers(f, p, s, minerals, gas);
		// Defences for new bases come before the next building of the build
		// order (which would otherwise keep the money reserved); new bases
		// after it, since defences need its buildings.
		// Colonizing without attacking: every colony is fortified as heavily
		// as money allows, with one production building for a few mobile
		// units (colony_defense). With attacking on, new bases just get a
		// couple of defences.
		p.colony_mode = colonizing && !attacking;
		if (colonizing && !p.colony_mode) build_defenses(f, p, s, minerals, gas);
		// In colony mode the next town hall comes first, then the colonies'
		// defences, and only then the build order's other buildings.
		if (p.colony_mode) {
			colony_units(f, p, s, minerals, gas);
			maybe_expand(f, p, s, minerals, gas);
			colony_defense(f, p, s, minerals, gas);
		}
		if (building && !supply_ordered) follow_build_order(f, p, s, minerals, gas);
		if (colonizing && !p.colony_mode) maybe_expand(f, p, s, minerals, gas);
		if (building) research(f, p, s, minerals, gas);
		if (fortifying) fortify(f, p, s, minerals, gas);
		if (attacking || fortifying) train_army(f, p, s, minerals, gas);
		if (attacking || threatened || !s.army.empty()) command_army(f, p, s, attacking);
	}

	xy rally_point(action_functions& f, player& p) {
		xy center((int)f.game_st.map_width / 2, (int)f.game_st.map_height / 2);
		xy d = center - p.home;
		int len = std::max(1, f.xy_length(d));
		return f.restrict_pos_to_map_bounds(p.home + d * p.cfg.army.rally_distance / len);
	}

	void manage_workers(action_functions& f, player& p, snapshot& s) {
		// Gas: three workers per finished refinery, newest refinery first
		// (the older ones already have theirs).
		a_vector<unit_t*> refineries;
		for (unit_t* b : s.buildings) {
			if (f.unit_is_refinery(b) && f.u_completed(b)) refineries.push_back(b);
		}
		int want_gas = (int)refineries.size() * p.cfg.economy.workers_per_refinery;
		for (unit_t* w : s.workers) {
			if (s.gas_workers >= want_gas) break;
			auto id = w->order_type->id;
			if (id != Orders::MoveToMinerals && id != Orders::WaitForMinerals && id != Orders::MiningMinerals) continue;
			unit_t* refinery = refineries[(size_t)(s.gas_workers / p.cfg.economy.workers_per_refinery) % refineries.size()];
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
		if (s.supply_max >= supply_cap) return false;
		UnitTypes type = supply_of(p.race);
		int producers = 0;
		for (unit_t* b : s.buildings) {
			if (f.u_completed(b) && (f.unit_is(b, UnitTypes::Terran_Barracks) || f.unit_is(b, UnitTypes::Terran_Factory) || f.unit_is(b, UnitTypes::Protoss_Gateway) || f.ut_resource_depot(b))) ++producers;
		}
		int margin = p.cfg.economy.supply_margin + producers * p.cfg.economy.supply_margin_per_producer;
		int in_progress = s.planned[(size_t)type] - s.done[(size_t)type];
		int free_supply = s.supply_max - s.supply_used;
		int wanted_in_progress = free_supply < margin ? (margin > p.cfg.economy.supply_double_margin ? 2 : 1) : 0;
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

	int wanted_workers(action_functions& f, player& p, snapshot& s) {
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
		auto& c = p.cfg.economy;
		return std::min(c.max_workers, std::max(1, bases) * c.workers_per_base + refineries * c.workers_per_refinery);
	}

	void train_workers(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		const unit_type_t* ut = f.get_unit_type(worker_of(p.race));
		int want = wanted_workers(f, p, s);
		int have = s.planned[(size_t)ut->id];
		if (have >= want) return;
		if (p.race == race_t::zerg) {
			// Drones compete with the army for larvae: keep a balance.
			if (have >= p.cfg.economy.zerg_drones_first && (int)s.army.size() * 2 < have - p.cfg.economy.zerg_drone_lead) return;
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

	static bool is_production(UnitTypes t) {
		return t == UnitTypes::Terran_Barracks || t == UnitTypes::Terran_Factory || t == UnitTypes::Terran_Starport ||
		       t == UnitTypes::Protoss_Gateway || t == UnitTypes::Protoss_Robotics_Facility || t == UnitTypes::Protoss_Stargate;
	}

	void follow_build_order(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		for (auto& step : build_order(p.race)) {
			if (s.supply_used < step.supply) break;
			if (s.planned[(size_t)step.type] >= step.count) continue;
			// Colonies dig in: one of each production building at most.
			if (p.colony_mode && is_production(step.type) && s.planned[(size_t)step.type] >= 1) continue;
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
		// Colonizing picked for a human (rather than full auto, which plays
		// like any computer player): a new base as soon as the current ones
		// are well worked or money piles up.
		if (p.human && p.modes != mode_all && frame > 24 * 60 * 3) {
			// Colonizing picked for a human: a new base when the current ones
			// are well worked, money piles up, or every couple of minutes
			// (zerg drones turn into colonies, so workers stay few).
			bool saturated = (int)s.workers.size() >= std::max(1, owned_sites) * 14;
			bool due = frame >= p.next_base;
			for (unit_t* d : s.depots) {
				colony_count c = count_colony(f, p, s, d);
				if (c.ground + c.air + c.tanks < 4) due = false; // dig in first
			}
			wanted_bases = std::min(6, owned_sites + (saturated || due || s.minerals >= 500 ? 1 : 0));
		}
		if (owned_sites >= wanted_bases) return;
		// A town hall already on its way?
		for (unit_t* w : s.workers) {
			if (building_order(w->order_type->id) && !w->build_queue.empty() && w->build_queue.front() == ut) return;
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

	// Moves miners from crowded bases to ones with free mineral patches.
	void balance_workers(action_functions& f, player& p, snapshot& s) {
		int frame = f.st.current_frame;
		if (frame < p.next_balance || s.depots.size() < 2) return;
		p.next_balance = frame + p.cfg.economy.balance_interval;
		struct base_load {
			unit_t* depot;
			int patches = 0;
			a_vector<unit_t*> miners;
		};
		a_vector<base_load> bases;
		for (unit_t* d : s.depots) bases.push_back({d});
		for (unit_t* m : ptr(f.st.player_units.at(11))) {
			if (f.unit_dead(m) || !f.unit_is_mineral_field(m)) continue;
			for (auto& b : bases) {
				if (dist2(m->sprite->position, b.depot->sprite->position) < 320 * 320) {
					++b.patches;
					break;
				}
			}
		}
		for (unit_t* w : s.workers) {
			auto id = w->order_type->id;
			if (id != Orders::MoveToMinerals && id != Orders::WaitForMinerals && id != Orders::MiningMinerals) continue;
			base_load* best = nullptr;
			int best_d = 0;
			for (auto& b : bases) {
				int d = dist2(w->sprite->position, b.depot->sprite->position);
				if (!best || d < best_d) {
					best = &b;
					best_d = d;
				}
			}
			if (best) best->miners.push_back(w);
		}
		// Two miners per patch is the sweet spot.
		for (auto& from : bases) {
			int surplus = (int)from.miners.size() - from.patches * p.cfg.economy.miners_per_patch;
			for (auto& to : bases) {
				if (surplus <= 0) break;
				if (&to == &from || to.patches == 0) continue;
				int room = to.patches * p.cfg.economy.miners_per_patch - (int)to.miners.size();
				while (room > 0 && surplus > 0 && !from.miners.empty()) {
					unit_t* w = from.miners.back();
					from.miners.pop_back();
					unit_t* patch = nullptr;
					for (unit_t* m : ptr(f.st.player_units.at(11))) {
						if (!f.unit_dead(m) && f.unit_is_mineral_field(m) && dist2(m->sprite->position, to.depot->sprite->position) < 320 * 320) {
							patch = m;
							if (!m->building.resource.is_being_gathered) break;
						}
					}
					if (!patch) break;
					if (select(f, p, w)) f.action_default_order(p.owner, patch->sprite->position, patch, nullptr, false);
					to.miners.push_back(w);
					--room;
					--surplus;
				}
			}
		}
	}

	static bool is_defense(UnitTypes t) {
		return t == UnitTypes::Terran_Bunker || t == UnitTypes::Terran_Missile_Turret || t == UnitTypes::Protoss_Photon_Cannon ||
		       t == UnitTypes::Zerg_Creep_Colony || t == UnitTypes::Zerg_Sunken_Colony || t == UnitTypes::Zerg_Spore_Colony;
	}

	// Two defences at every base other than the main one.
	void build_defenses(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		if (f.st.current_frame < p.next_defense) return;
		// New bases get their defences while the town hall is still going up.
		for (unit_t* d : s.buildings) {
			if (!f.ut_resource_depot(d)) continue;
			xy at = d->sprite->position;
			if (dist2(at, p.home) < 320 * 320) continue;
			int defenses = 0;
			unit_t* pylon = nullptr;
			unit_t* creep_colony = nullptr;
			for (unit_t* b : s.buildings) {
				if (dist2(b->sprite->position, at) > 288 * 288) continue;
				if (is_defense(b->unit_type->id)) ++defenses;
				// A finished pylon powers cannons; an unfinished one is waited for.
				if (f.unit_is(b, UnitTypes::Protoss_Pylon) && (!pylon || f.u_completed(b))) pylon = b;
				if (f.unit_is(b, UnitTypes::Zerg_Creep_Colony) && f.u_completed(b) && b->build_queue.empty()) creep_colony = b;
			}
			if (defenses >= p.cfg.defense.expansion_defenses && !creep_colony) continue;
			UnitTypes type = UnitTypes::None;
			if (p.race == race_t::terran) {
				if (s.done[(size_t)UnitTypes::Terran_Engineering_Bay]) type = UnitTypes::Terran_Missile_Turret;
				else if (s.done[(size_t)UnitTypes::Terran_Barracks]) type = UnitTypes::Terran_Bunker;
			} else if (p.race == race_t::protoss) {
				if (!pylon) type = UnitTypes::Protoss_Pylon;
				else if (!f.u_completed(pylon)) continue;
				else if (s.done[(size_t)UnitTypes::Protoss_Forge]) type = UnitTypes::Protoss_Photon_Cannon;
				else if (!s.planned[(size_t)UnitTypes::Protoss_Forge]) {
					const unit_type_t* forge = f.get_unit_type(UnitTypes::Protoss_Forge);
					if (affordable(forge, minerals, gas) && place(f, p, s, UnitTypes::Protoss_Forge)) minerals -= forge->mineral_cost;
					return;
				}
			} else {
				// Creep colonies grow into sunken colonies once the pool is up.
				if (creep_colony && s.done[(size_t)UnitTypes::Zerg_Spawning_Pool]) {
					const unit_type_t* sunken = f.get_unit_type(UnitTypes::Zerg_Sunken_Colony);
					if (affordable(sunken, minerals, gas) && select(f, p, creep_colony) && f.action_morph_building(p.owner, sunken)) minerals -= sunken->mineral_cost;
					return;
				}
				if (defenses < p.cfg.defense.expansion_defenses) type = UnitTypes::Zerg_Creep_Colony;
			}
			if (type == UnitTypes::None || defenses >= p.cfg.defense.expansion_defenses) continue;
			const unit_type_t* ut = f.get_unit_type(type);
			if (!affordable(ut, minerals, gas)) return;
			// Cannons must stand in the pylon's power field.
			xy center = type == UnitTypes::Protoss_Photon_Cannon && pylon ? pylon->sprite->position : at;
			if (place_near(f, p, s, type, center, type == UnitTypes::Protoss_Photon_Cannon ? 1 : 2, 8)) {
				minerals -= ut->mineral_cost;
				gas -= ut->gas_cost;
				// Give the worker time to walk there before asking again.
				p.next_defense = f.st.current_frame + 24 * 20;
			}
			return; // one at a time
		}
	}

	// Defensive mode: every base gets ground and air defences, the main one
	// more: Terran bunkers and missile turrets, Protoss photon cannons (they
	// hit both) by a pylon, Zerg sunken and spore colonies grown from creep
	// colonies. The buildings these need (engineering bay, forge, evolution
	// chamber) come first. One building at a time, like the other jobs.
	void fortify(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		if (f.st.current_frame < p.next_fortify) return;
		auto need = [&](UnitTypes t) {
			if (s.done[(size_t)t] || s.planned[(size_t)t]) return false;
			const unit_type_t* ut = f.get_unit_type(t);
			if (affordable(ut, minerals, gas) && place(f, p, s, t)) {
				minerals -= ut->mineral_cost;
				gas -= ut->gas_cost;
				p.next_fortify = f.st.current_frame + 24 * 10;
			}
			return true;
		};
		UnitTypes tech = p.race == race_t::terran ? UnitTypes::Terran_Engineering_Bay
		                 : p.race == race_t::protoss ? UnitTypes::Protoss_Forge
		                                             : UnitTypes::Zerg_Evolution_Chamber;
		if (!s.done[(size_t)tech]) {
			if (s.planned[(size_t)tech]) return; // on its way
			need(tech);
			return;
		}
		for (unit_t* d : s.depots) {
			xy at = d->sprite->position;
			bool main = dist2(at, p.home) < 320 * 320;
			auto& c = p.cfg.defense;
			int want_ground = main ? c.fortify_main_ground : c.fortify_ground, want_air = main ? c.fortify_main_air : c.fortify_air;
			int ground = 0, air = 0;
			unit_t* pylon = nullptr;
			unit_t* creep_colony = nullptr;
			for (unit_t* b : s.buildings) {
				if (dist2(b->sprite->position, at) > 320 * 320) continue;
				switch (b->unit_type->id) {
				case UnitTypes::Terran_Bunker: case UnitTypes::Zerg_Sunken_Colony: ++ground; break;
				case UnitTypes::Terran_Missile_Turret: case UnitTypes::Zerg_Spore_Colony: ++air; break;
				case UnitTypes::Protoss_Photon_Cannon: ++ground; ++air; break;
				case UnitTypes::Zerg_Creep_Colony:
					if (f.u_completed(b) && b->build_queue.empty()) creep_colony = b;
					else ++ground; // already turning into something
					break;
				case UnitTypes::Protoss_Pylon:
					if (!pylon || f.u_completed(b)) pylon = b;
					break;
				default: break;
				}
			}
			if (ground >= want_ground && air >= want_air) continue;
			UnitTypes type = UnitTypes::None;
			xy center = at;
			int min_r = 2;
			if (p.race == race_t::terran) {
				type = air < want_air && (air <= ground || !s.done[(size_t)UnitTypes::Terran_Barracks]) ? UnitTypes::Terran_Missile_Turret : UnitTypes::Terran_Bunker;
				if (type == UnitTypes::Terran_Bunker && !s.done[(size_t)UnitTypes::Terran_Barracks]) {
					need(UnitTypes::Terran_Barracks);
					return;
				}
			} else if (p.race == race_t::protoss) {
				if (!pylon) type = UnitTypes::Protoss_Pylon;
				else if (!f.u_completed(pylon)) continue;
				else {
					type = UnitTypes::Protoss_Photon_Cannon;
					center = pylon->sprite->position;
					min_r = 1;
				}
			} else {
				if (creep_colony) {
					// Spores against air, sunkens (they need the pool) against ground.
					UnitTypes grow = air < want_air && (air <= ground || !s.done[(size_t)UnitTypes::Zerg_Spawning_Pool])
					                     ? UnitTypes::Zerg_Spore_Colony
					                     : UnitTypes::Zerg_Sunken_Colony;
					if (grow == UnitTypes::Zerg_Sunken_Colony && !s.done[(size_t)UnitTypes::Zerg_Spawning_Pool]) continue;
					const unit_type_t* ut = f.get_unit_type(grow);
					if (affordable(ut, minerals, gas) && select(f, p, creep_colony) && f.action_morph_building(p.owner, ut)) {
						minerals -= ut->mineral_cost;
						p.next_fortify = f.st.current_frame + 24 * 2;
					}
					return;
				}
				type = UnitTypes::Zerg_Creep_Colony;
			}
			const unit_type_t* ut = f.get_unit_type(type);
			if (!affordable(ut, minerals, gas)) return;
			if (place_near(f, p, s, type, center, min_r, 9)) {
				minerals -= ut->mineral_cost;
				gas -= ut->gas_cost;
				// Give the worker time to walk there before asking again.
				p.next_fortify = f.st.current_frame + 24 * 8;
			} else {
				p.next_fortify = f.st.current_frame + 24 * 4;
			}
			return; // one at a time
		}
	}

	// --- colonizing without attacking: colonies dig in ---------------------------

	// A unit standing guard at one of the colonies (sieged tanks, units by
	// a town hall) isn't called back to the rally point.
	bool guards_colony(action_functions& f, snapshot& s, unit_t* u) {
		if (f.unit_is(u, UnitTypes::Terran_Siege_Tank_Siege_Mode)) return true;
		for (unit_t* d : s.depots) {
			if (dist2(d->sprite->position, u->sprite->position) < 384 * 384) return true;
		}
		return false;
	}

	struct colony_count {
		unit_t* hall = nullptr;
		int ground = 0, air = 0, bunkers = 0, tanks = 0;
		unit_t* pylon = nullptr;
		unit_t* creep_colony = nullptr;
	};

	colony_count count_colony(action_functions& f, player& p, snapshot& s, unit_t* hall) {
		colony_count c;
		c.hall = hall;
		xy at = hall->sprite->position;
		for (unit_t* b : s.buildings) {
			if (dist2(b->sprite->position, at) > 352 * 352) continue;
			switch (b->unit_type->id) {
			case UnitTypes::Terran_Bunker: ++c.ground; ++c.bunkers; break;
			case UnitTypes::Zerg_Sunken_Colony: ++c.ground; break;
			case UnitTypes::Terran_Missile_Turret: case UnitTypes::Zerg_Spore_Colony: ++c.air; break;
			case UnitTypes::Protoss_Photon_Cannon: ++c.ground; ++c.air; break;
			case UnitTypes::Zerg_Creep_Colony:
				if (f.u_completed(b) && b->build_queue.empty()) c.creep_colony = b;
				else ++c.ground; // already turning into something
				break;
			case UnitTypes::Protoss_Pylon:
				if (!c.pylon || f.u_completed(b)) c.pylon = b;
				break;
			default: break;
			}
		}
		for (unit_t* u : s.army) {
			if ((f.unit_is(u, UnitTypes::Terran_Siege_Tank_Tank_Mode) || f.unit_is(u, UnitTypes::Terran_Siege_Tank_Siege_Mode)) &&
			    dist2(u->sprite->position, at) < 384 * 384) ++c.tanks;
		}
		return c;
	}

	void colony_defense(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		if (f.st.current_frame < p.next_colony) return;
		UnitTypes tech = p.race == race_t::terran ? UnitTypes::Terran_Engineering_Bay
		                 : p.race == race_t::protoss ? UnitTypes::Protoss_Forge
		                                             : UnitTypes::Zerg_Spawning_Pool;
		auto build_once = [&](UnitTypes t) {
			if (s.done[(size_t)t] || s.planned[(size_t)t]) return;
			const unit_type_t* ut = f.get_unit_type(t);
			if (affordable(ut, minerals, gas) && place(f, p, s, t)) {
				minerals -= ut->mineral_cost;
				gas -= ut->gas_cost;
				p.next_colony = f.st.current_frame + 24 * 8;
			}
		};
		if (!s.done[(size_t)tech]) {
			build_once(tech);
			return;
		}
		if (p.race == race_t::zerg && !s.done[(size_t)UnitTypes::Zerg_Evolution_Chamber]) build_once(UnitTypes::Zerg_Evolution_Chamber);
		if (p.race == race_t::terran && !s.done[(size_t)UnitTypes::Terran_Barracks]) {
			build_once(UnitTypes::Terran_Barracks); // bunkers need it
			return;
		}

		// The weakest colony first; if nothing fits there, the next. With
		// money piling up, colonies keep growing past the usual target (up
		// to twice it).
		// How heavily a colony is fortified: ground defences (bunkers count with
		// their tanks for Terran) and air defences.
		int colony_ground = p.cfg.defense.colony_ground, colony_air = p.cfg.defense.colony_air;
		int ground_target = minerals >= p.cfg.defense.colony_rich ? colony_ground * 2 : colony_ground;
		a_vector<colony_count> colonies;
		for (unit_t* d : s.depots) {
			colony_count c = count_colony(f, p, s, d);
			if (c.ground + c.tanks >= ground_target && c.air >= colony_air) continue;
			colonies.push_back(c);
		}
		std::stable_sort(colonies.begin(), colonies.end(), [](const colony_count& a, const colony_count& b) {
			return a.ground + a.tanks + a.air < b.ground + b.tanks + b.air;
		});
		for (colony_count& c : colonies) {
			int r = fortify_colony(f, p, s, c, minerals, gas);
			if (r != 0) {
				p.next_colony = f.st.current_frame + (r > 0 ? 24 * 6 : 24 * 2);
				return;
			}
		}
		p.next_colony = f.st.current_frame + 24 * 3;
	}

	// One defence (or what it needs) at colony c: 1 built or ordered, -1
	// out of money (stop for now), 0 nothing fits here (try another colony).
	int fortify_colony(action_functions& f, player& p, snapshot& s, colony_count& c, int& minerals, int& gas) {
		int colony_air = p.cfg.defense.colony_air;
		bool want_air = c.air < colony_air && (c.air * 3 <= c.ground + c.tanks);
		xy at = c.hall->sprite->position;
		auto try_place = [&](UnitTypes type, xy center, int min_r) {
			const unit_type_t* ut = f.get_unit_type(type);
			if (!affordable(ut, minerals, gas)) return -1;
			if (!place_near(f, p, s, type, center, min_r, 10)) return 0;
			minerals -= ut->mineral_cost;
			gas -= ut->gas_cost;
			return 1;
		};
		if (p.race == race_t::terran) {
			UnitTypes type = want_air ? UnitTypes::Terran_Missile_Turret
			                 : c.bunkers < 3 || c.air >= colony_air ? UnitTypes::Terran_Bunker
			                                                        : UnitTypes::Terran_Missile_Turret;
			return try_place(type, at, 3);
		}
		if (p.race == race_t::protoss) {
			// Cannons by any finished pylon of the colony; another pylon when
			// their power fields are full.
			bool pending_pylon = false;
			for (unit_t* b : s.buildings) {
				if (!f.unit_is(b, UnitTypes::Protoss_Pylon) || dist2(b->sprite->position, at) > 352 * 352) continue;
				if (!f.u_completed(b)) {
					pending_pylon = true;
					continue;
				}
				int r = try_place(UnitTypes::Protoss_Photon_Cannon, b->sprite->position, 1);
				if (r != 0) return r;
			}
			if (pending_pylon) return 0;
			return try_place(UnitTypes::Protoss_Pylon, at, 4);
		}
		// Zerg: creep colonies grow into spores (air) or sunkens (ground).
		if (c.creep_colony) {
			UnitTypes grow = want_air && s.done[(size_t)UnitTypes::Zerg_Evolution_Chamber] ? UnitTypes::Zerg_Spore_Colony
			                                                                               : UnitTypes::Zerg_Sunken_Colony;
			const unit_type_t* ut = f.get_unit_type(grow);
			if (!affordable(ut, minerals, gas)) return -1;
			if (select(f, p, c.creep_colony) && f.action_morph_building(p.owner, ut)) {
				minerals -= ut->mineral_cost;
				return 1;
			}
			return 0;
		}
		return try_place(UnitTypes::Zerg_Creep_Colony, at, 3);
	}

	// A few mobile units from the one production building: marines for the
	// bunkers and siege tanks at every colony (Terran), a handful of
	// zealots and dragoons (Protoss) or zerglings and hydralisks (Zerg).
	// Marines go into bunkers with room and tanks siege at their colony.
	void colony_units(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		if (f.st.current_frame < p.next_colony_units) return;
		p.next_colony_units = f.st.current_frame + 24;
		const int few = p.cfg.defense.colony_mobile;
		int mobile = 0;
		for (unit_t* u : s.army) {
			if (!f.unit_is(u, UnitTypes::Terran_Siege_Tank_Tank_Mode) && !f.unit_is(u, UnitTypes::Terran_Siege_Tank_Siege_Mode)) ++mobile;
		}
		auto train_at = [&](UnitTypes building, UnitTypes t) {
			const unit_type_t* ut = f.get_unit_type(t);
			if (!affordable(ut, minerals, gas)) return false;
			if (s.supply_used + (int)(ut->supply_required.raw_value / 2) > s.supply_max) return false;
			for (unit_t* b : s.buildings) {
				if (!f.unit_is(b, building) || !f.u_completed(b) || !b->build_queue.empty()) continue;
				if (select(f, p, b) && f.action_train(p.owner, ut)) {
					minerals -= ut->mineral_cost;
					gas -= ut->gas_cost;
					return true;
				}
				return false;
			}
			return false;
		};
		if (p.race == race_t::terran) {
			int bunkers = 0, tanks = 0;
			for (unit_t* b : s.buildings) {
				if (f.unit_is(b, UnitTypes::Terran_Bunker) && f.u_completed(b)) ++bunkers;
			}
			for (unit_t* u : s.army) {
				if (f.unit_is(u, UnitTypes::Terran_Siege_Tank_Tank_Mode) || f.unit_is(u, UnitTypes::Terran_Siege_Tank_Siege_Mode)) ++tanks;
			}
			if (mobile < bunkers * p.cfg.defense.marines_per_bunker + p.cfg.defense.colony_marines) train_at(UnitTypes::Terran_Barracks, UnitTypes::Terran_Marine);
			// Tanks: one factory with its machine shop, siege mode researched.
			int want_tanks = p.cfg.defense.colony_tanks * (int)s.depots.size();
			if (s.done[(size_t)UnitTypes::Terran_Barracks] && tanks < want_tanks) {
				if (!s.planned[(size_t)UnitTypes::Terran_Factory]) {
					const unit_type_t* fac = f.get_unit_type(UnitTypes::Terran_Factory);
					if (affordable(fac, minerals, gas) && place(f, p, s, UnitTypes::Terran_Factory)) {
						minerals -= fac->mineral_cost;
						gas -= fac->gas_cost;
					}
				}
				for (unit_t* b : s.buildings) {
					if (!f.unit_is(b, UnitTypes::Terran_Factory) || !f.u_completed(b)) continue;
					if (!b->building.addon) {
						if (b->build_queue.empty()) build_addon(f, p, b, minerals, gas);
					} else if (f.u_completed(b->building.addon)) {
						unit_t* shop = b->building.addon;
						const tech_type_t* siege = f.get_tech_type(TechTypes::Tank_Siege_Mode);
						if (!shop->building.researching_type && f.unit_can_research(shop, siege, p.owner) &&
						    minerals >= siege->mineral_cost && gas >= siege->gas_cost && select(f, p, shop) && f.action_research(p.owner, siege)) {
							minerals -= siege->mineral_cost;
							gas -= siege->gas_cost;
						}
						train_at(UnitTypes::Terran_Factory, UnitTypes::Terran_Siege_Tank_Tank_Mode);
					}
					break;
				}
			}
			// Marines into bunkers with room; tanks to the colony with the
			// fewest, sieged once there.
			for (unit_t* u : s.army) {
				if (f.unit_is(u, UnitTypes::Terran_Marine) && is_idle(u)) {
					unit_t* best = nullptr;
					int best_d = 0;
					for (unit_t* b : s.buildings) {
						if (!f.unit_is(b, UnitTypes::Terran_Bunker) || !f.u_completed(b)) continue;
						int loaded = 0;
						for (auto id : b->loaded_units) {
							if (f.get_unit(id)) ++loaded;
						}
						if (loaded >= p.cfg.defense.marines_per_bunker) continue;
						int d = dist2(b->sprite->position, u->sprite->position);
						if (!best || d < best_d) {
							best = b;
							best_d = d;
						}
					}
					if (best && select(f, p, u)) {
						f.action_order(p.owner, f.get_order_type(Orders::EnterTransport), best->sprite->position, best, nullptr, false);
					}
				} else if (f.unit_is(u, UnitTypes::Terran_Siege_Tank_Tank_Mode) && is_idle(u)) {
					unit_t* home = nullptr;
					int fewest = 1 << 30;
					for (unit_t* d : s.depots) {
						colony_count c = count_colony(f, p, s, d);
						if (c.tanks < fewest) {
							fewest = c.tanks;
							home = d;
						}
					}
					if (!home) continue;
					if (dist2(u->sprite->position, home->sprite->position) < 256 * 256 || fewest >= p.cfg.defense.colony_tanks) {
						if (select(f, p, u)) f.action_siege(p.owner, false);
					} else {
						order_group(f, p, {u}, Orders::Move, home->sprite->position);
					}
				}
			}
		} else if (p.race == race_t::protoss) {
			if (mobile < few) {
				bool dragoon = s.done[(size_t)UnitTypes::Protoss_Cybernetics_Core] && gas >= 50 &&
				               count_army(s, UnitTypes::Protoss_Dragoon) <= count_army(s, UnitTypes::Protoss_Zealot);
				train_at(UnitTypes::Protoss_Gateway, dragoon ? UnitTypes::Protoss_Dragoon : UnitTypes::Protoss_Zealot);
			}
		} else {
			if (mobile < few && s.done[(size_t)UnitTypes::Zerg_Spawning_Pool]) {
				bool hydra = s.done[(size_t)UnitTypes::Zerg_Hydralisk_Den] && gas >= 25 &&
				             count_army(s, UnitTypes::Zerg_Hydralisk) < count_army(s, UnitTypes::Zerg_Zergling);
				const unit_type_t* ut = f.get_unit_type(hydra ? UnitTypes::Zerg_Hydralisk : UnitTypes::Zerg_Zergling);
				if (affordable(ut, minerals, gas) && s.supply_used + (int)(ut->supply_required.raw_value / 2) <= s.supply_max &&
				    morph_larva(f, p, s, ut)) {
					minerals -= ut->mineral_cost;
					gas -= ut->gas_cost;
				}
			}
		}
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

	// An enemy close to any of our buildings (within `range`), or null.
	unit_t* find_intruder(action_functions& f, player& p, snapshot& s, int range = 0) {
		if (range == 0) range = p.cfg.defense.intruder_range;
		for (unit_t* b : s.buildings) {
			if (unit_t* e = nearest_enemy(f, p, b->sprite->position, false, range)) {
				// Further out, only an armed force counts (not a scout or an Overlord).
				if (range <= p.cfg.defense.intruder_range || (!f.ut_worker(e) && f.unit_can_attack(e))) return e;
			}
		}
		return nullptr;
	}

	// Survival first: with the base under attack every unit defends (an
	// attack wave out in the field is called back), and if there is no army
	// to answer a small raid, the nearby workers fight it off.
	void defend(action_functions& f, player& p, snapshot& s, unit_t* intruder) {
		p.attacking = false;
		a_vector<unit_t*> army;
		for (unit_t* u : s.army) {
			if (is_idle(u) || u->order_type->id == Orders::Move || u->order_type->id == Orders::AttackMove) army.push_back(u);
		}
		if (!army.empty()) order_group(f, p, army, Orders::AttackMove, intruder->sprite->position);
		int ours = 0, theirs = 0;
		for (unit_t* u : s.army) ours += u->unit_type->mineral_cost + u->unit_type->gas_cost;
		for (int o = 0; o != 8; ++o) {
			if (!is_enemy(f, p.owner, o)) continue;
			for (unit_t* u : ptr(f.st.player_units.at(o))) {
				if (f.unit_dead(u) || !u->sprite || f.ut_worker(u) || f.ut_building(u)) continue;
				if (dist2(u->sprite->position, intruder->sprite->position) < 384 * 384) theirs += u->unit_type->mineral_cost + u->unit_type->gas_cost;
			}
		}
		// Workers can't hit air, and an army of our own does better.
		if (ours >= theirs || f.u_flying(intruder)) return;
		size_t pull = (size_t)(ours == 0 ? p.cfg.defense.militia_all : p.cfg.defense.militia_some);
		a_vector<unit_t*> militia;
		for (unit_t* w : s.workers) {
			if (militia.size() >= pull) break;
			if (dist2(w->sprite->position, intruder->sprite->position) < 320 * 320) militia.push_back(w);
		}
		if (militia.empty()) return;
		order_group(f, p, militia, Orders::AttackMove, intruder->sprite->position);
		p.militia_until = f.st.current_frame + p.cfg.defense.militia_time;
	}

	// Defensive mode: when an ally's base is attacked, about half the army
	// (the units nearest to it) goes to clear the threat; afterwards that
	// detachment stays by the ally, ready for the next attack, and never
	// goes on to enemy bases. Returns the detachment's units.
	a_vector<unit_t*> help_allies(action_functions& f, player& p, snapshot& s) {
		int frame = f.st.current_frame;
		auto& c = p.cfg.help;
		if (frame >= p.next_ally_check) {
			p.next_ally_check = frame + 24;
			for (int m : allies->members(allies->group[p.owner])) {
				if (m == p.owner || !allies->active(f.st, m)) continue;
				unit_t* threat = nullptr;
				xy base;
				for (unit_t* b : ptr(f.st.player_units.at(m))) {
					if (f.unit_dead(b) || !b->sprite || !f.ut_building(b)) continue;
					unit_t* e = nearest_enemy(f, p, b->sprite->position, false, c.range);
					if (!e || f.ut_worker(e) || !f.unit_can_attack(e)) continue;
					auto r = fire(f, p, &s, botscript::h_ally_attacked, {m});
					if (r.value && !r.v) break;
					threat = e;
					base = b->sprite->position;
					break;
				}
				if (!threat) continue;
				if (m != p.guard_ally) p.detached.clear();
				if (version >= 2 && p.guard_ally != m) ai_log(f, p, "help", (int)s.army.size());
				p.guard_ally = m;
				p.guard_pos = base;
				p.help_target = threat->sprite->position;
				p.help_until = frame + c.fresh;
				break;
			}
		}
		if (p.guard_ally >= 0 && (!allies->same_group(p.owner, p.guard_ally) || !allies->active(f.st, p.guard_ally))) {
			p.guard_ally = -1;
			p.detached.clear();
		}
		if (p.guard_ally < 0) return {};

		// The detachment's units still alive (ids carry a generation, so a
		// reused slot isn't mistaken for one of them).
		a_vector<unit_t*> group;
		a_vector<uint32_t> alive;
		for (unit_t* u : s.army) {
			uint32_t id = f.get_unit_id_32(u).raw_value;
			if (std::find(p.detached.begin(), p.detached.end(), id) != p.detached.end()) {
				group.push_back(u);
				alive.push_back(id);
			}
		}
		p.detached = alive;
		bool threat = frame < p.help_until;
		// Picked when the ally is attacked: half the army, nearest first.
		if (group.empty() && threat && s.army.size() >= 2) {
			a_vector<unit_t*> by_distance = s.army;
			std::stable_sort(by_distance.begin(), by_distance.end(), [&](unit_t* a, unit_t* b) {
				return dist2(a->sprite->position, p.help_target) < dist2(b->sprite->position, p.help_target);
			});
			// (Version 2: a small army goes whole.)
			if (version < 2 || (int)by_distance.size() > c.whole_army) by_distance.resize((by_distance.size() + 1) / 2);
			group = by_distance;
			for (unit_t* u : group) p.detached.push_back(f.get_unit_id_32(u).raw_value);
			p.last_help_order = -10000;
		}
		if (group.empty()) return {};
		if (threat) {
			bool refresh = frame - p.last_help_order > c.refresh;
			a_vector<unit_t*> go;
			for (unit_t* u : group) {
				if (refresh || is_idle(u) || u->order_type->id == Orders::Move) go.push_back(u);
			}
			if (refresh) p.last_help_order = frame;
			if (!go.empty()) order_group(f, p, go, Orders::AttackMove, p.help_target);
		} else {
			// Threat gone: wait by the ally.
			a_vector<unit_t*> back;
			for (unit_t* u : group) {
				if (is_idle(u) && dist2(u->sprite->position, p.guard_pos) > c.guard_radius * c.guard_radius) back.push_back(u);
			}
			if (!back.empty()) order_group(f, p, back, Orders::Move, p.guard_pos);
		}
		return group;
	}

	void command_army(action_functions& f, player& p, snapshot& s, bool may_attack = true) {
		int frame = f.st.current_frame;

		unit_t* intruder = find_intruder(f, p, s);
		if (intruder) {
			defend(f, p, s, intruder);
			return;
		}

		if (!may_attack) {
			// Defensive mode: help allies under attack, then guard them.
			a_vector<unit_t*> detachment;
			if (p.fortifying) detachment = help_allies(f, p, s);
			// Not our job to attack: wait at the rally point.
			a_vector<unit_t*> stray;
			for (unit_t* u : s.army) {
				if (std::find(detachment.begin(), detachment.end(), u) != detachment.end()) continue;
				if (p.colony_mode && guards_colony(f, s, u)) continue;
				if (is_idle(u) && dist2(u->sprite->position, p.rally) > 192 * 192) stray.push_back(u);
			}
			if (!stray.empty()) order_group(f, p, stray, Orders::Move, p.rally);
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
	// =============================================================================
	// Version 2: the whole tech tree, as the original's computer players use it.
	//
	// Builds follow a plan per race that reaches every tier (and a different
	// one when no enemy base can be reached on the ground: then the army is
	// mostly air, ground units go by dropship, shuttle or overlord, and every
	// base gets anti-air early). The army's mix follows the plan's tier and
	// what the enemies field (flyers call for anti-air, cloaked units for
	// detection). Units use their abilities: tanks siege, vultures lay spider
	// mines, marines stim, ghosts cloak, lock down and call in nukes from
	// armed silos, battlecruisers fire Yamato, science vessels irradiate and
	// shield, high templar storm (and merge into archons when spent), arbiters
	// freeze, corsairs web, defilers swarm, plague and consume, queens ensnare
	// and spawn broodlings, lurkers burrow, carriers and reavers keep their
	// interceptors and scarabs, comsats scan for cloaked attackers.
	// Transports and spellcasters never lead an attack: transports carry drops
	// or wait at home, casters stay with the army.
	// =============================================================================

	struct unit_want {
		UnitTypes type;
		int share; // relative share of the army
		int cap;   // at most this many (0: no cap)
	};

	static bool step_applies(const player& p, int where) {
		return where == 0 || (where == 1 && !p.island) || (where == 2 && p.island);
	}

	static int value_of(const unit_t* u) {
		return u->unit_type->mineral_cost + u->unit_type->gas_cost;
	}

	unit_t* resolve(action_functions& f, uint32_t raw) {
		return f.get_unit(unit_id(raw));
	}

	// --- what the enemies have, and whether they can be reached on foot --------

	void update_intel(action_functions& f, player& p) {
		int frame = f.st.current_frame;
		if (frame < p.next_intel) return;
		p.next_intel = frame + 24 * 4;
		int bases = 0, reachable = 0, air = 0, cloaked = 0;
		for (int o = 0; o != 8; ++o) {
			if (!is_enemy(f, p.owner, o)) continue;
			for (unit_t* u : ptr(f.st.player_units.at(o))) {
				if (f.unit_dead(u) || !u->sprite) continue;
				if (f.ut_building(u)) {
					if (f.u_flying(u)) continue; // a lifted Terran building
					++bases;
					if (f.is_reachable(p.home, u->sprite->position)) ++reachable;
					continue;
				}
				if (f.ut_worker(u) || !f.u_completed(u) || !is_army_type(u->unit_type->id)) continue;
				if (f.u_flying(u) && f.unit_can_attack(u)) air += value_of(u);
				auto t = u->unit_type->id;
				if (t == UnitTypes::Protoss_Dark_Templar || t == UnitTypes::Zerg_Lurker || t == UnitTypes::Protoss_Arbiter || f.u_cloaked(u)) cloaked += value_of(u);
			}
		}
		p.island = bases > 0 && reachable == 0;
		p.some_island = reachable < bases;
		p.enemy_air = air;
		p.enemy_cloaked = cloaked;
	}

	// --- the army's mix ---------------------------------------------------------

	a_vector<unit_want> composition(action_functions& f, player& p, snapshot& s) {
		auto& c = p.cfg.army;
		int aa = std::min(c.aa_max, p.enemy_air / c.aa_per);
		bool late = f.st.current_frame > c.late_game;
		bool cloak = p.enemy_cloaked > 0;
		a_vector<unit_want> w;
		for (auto& r : mix_of(p)) {
			if (r.some_island && !p.some_island) continue;
			int share = late && r.late >= 0 ? r.late : cloak && r.cloak >= 0 ? r.cloak : r.share;
			w.push_back({r.type, share + aa * r.aa_mul / r.aa_div, r.cap});
		}
		(void)s;
		return w;
	}

	int army_count(snapshot& s, UnitTypes t) {
		int n = s.planned[(size_t)t];
		if (t == UnitTypes::Terran_Siege_Tank_Tank_Mode) n += s.planned[(size_t)UnitTypes::Terran_Siege_Tank_Siege_Mode];
		if (t == UnitTypes::Zerg_Lurker) n += s.planned[(size_t)UnitTypes::Zerg_Lurker_Egg];
		if (t == UnitTypes::Zerg_Guardian) n += s.planned[(size_t)UnitTypes::Zerg_Cocoon];
		return n;
	}

	// The wanted type furthest below its share that `maker` can make now.
	// Shares count among the types it can make now (a spire still building
	// doesn't hold back zerglings).
	const unit_type_t* pick_unit(action_functions& f, player& p, snapshot& s, const a_vector<unit_want>& wants, unit_t* maker, int minerals, int gas) {
		struct option {
			const unit_type_t* ut;
			int share;
			int have;
		};
		a_vector<option> options;
		int total = 0, shares = 0;
		for (auto& w : wants) {
			if (w.share <= 0) continue;
			const unit_type_t* ut = f.get_unit_type(w.type);
			if (!f.unit_can_build(maker, ut)) continue;
			int have = army_count(s, w.type);
			// Short of gas with minerals piling up, units that cost no gas
			// count more (and may go past their usual number).
			// (Not walkers on an island: they would only wait at home.)
			bool starved = ut->gas_cost == 0 && gas < p.cfg.army.starved_gas && minerals > p.cfg.army.starved_minerals && !(p.island && !f.ut_flyer(ut));
			if (w.cap > 0 && have >= w.cap * (starved ? p.cfg.army.starved_factor : 1)) continue;
			int share = w.share;
			if (starved) share *= p.cfg.army.starved_factor;
			options.push_back({ut, share, have});
			total += have;
			shares += share;
		}
		const unit_type_t* best = nullptr;
		int best_need = 0;
		for (auto& o : options) {
			if (!affordable(o.ut, minerals, gas)) continue;
			// Need: how far below its share it is (scaled by 100).
			int need = o.share * (total + 4) * 100 / shares - o.have * 100;
			if (!best || need > best_need) {
				best = o.ut;
				best_need = need;
			}
		}
		return best;
	}

	static bool makes_units(UnitTypes t) {
		return t == UnitTypes::Terran_Barracks || t == UnitTypes::Terran_Factory || t == UnitTypes::Terran_Starport ||
		       t == UnitTypes::Protoss_Gateway || t == UnitTypes::Protoss_Robotics_Facility || t == UnitTypes::Protoss_Stargate;
	}

	void train_army2(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		if (minerals < p.cfg.army.min_minerals) return;
		auto wants = composition(f, p, s);
		if (p.race == race_t::zerg) {
			while (!s.larvae.empty() && minerals >= p.cfg.army.min_minerals) {
				unit_t* larva = s.larvae.back();
				const unit_type_t* ut = pick_unit(f, p, s, wants, larva, minerals, gas);
				if (!ut) return;
				int supply = std::max(1, (int)(ut->supply_required.raw_value / 2));
				if (s.supply_used + supply > s.supply_max) return;
				if (!morph_larva(f, p, s, ut)) return;
				minerals -= ut->mineral_cost;
				gas -= ut->gas_cost;
				s.supply_used += supply;
				bump(s.planned, ut);
			}
			return;
		}
		for (unit_t* b : s.buildings) {
			if (!f.u_completed(b) || !b->build_queue.empty() || !makes_units(b->unit_type->id)) continue;
			const unit_type_t* ut = pick_unit(f, p, s, wants, b, minerals, gas);
			if (!ut) continue;
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

	// Lurkers from hydralisks, guardians and devourers from mutalisks, archons
	// from spent high templar.
	void morph_units(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		auto wants = composition(f, p, s);
		auto want_of = [&](UnitTypes t) {
			for (auto& w : wants) {
				if (w.type == t) return w;
			}
			return unit_want{t, 0, 0};
		};
		auto morph_from = [&](UnitTypes from, UnitTypes to) {
			unit_want w = want_of(to);
			if (w.share <= 0) return;
			int have = army_count(s, to);
			int limit = w.cap > 0 ? w.cap : std::max(p.cfg.army.morph_min, army_count(s, from) / 2);
			if (have >= limit) return;
			const unit_type_t* ut = f.get_unit_type(to);
			if (!affordable(ut, minerals, gas)) return;
			for (unit_t* u : s.army) {
				if (!f.unit_is(u, from) || !is_idle(u)) continue;
				if (!f.unit_can_build(u, ut)) return;
				if (select(f, p, u) && f.action_morph(p.owner, ut)) {
					minerals -= ut->mineral_cost;
					gas -= ut->gas_cost;
				}
				return; // one at a time
			}
		};
		if (p.race == race_t::zerg) {
			morph_from(UnitTypes::Zerg_Hydralisk, UnitTypes::Zerg_Lurker);
			morph_from(UnitTypes::Zerg_Mutalisk, UnitTypes::Zerg_Guardian);
			morph_from(UnitTypes::Zerg_Mutalisk, UnitTypes::Zerg_Devourer);
		} else if (p.race == race_t::protoss) {
			// Two high templar low on energy become an archon.
			a_vector<unit_t*> spent;
			for (unit_t* u : s.army) {
				if (f.unit_is(u, UnitTypes::Protoss_High_Templar) && u->energy < fp8::integer(p.cfg.army.archon_energy) && is_idle(u)) spent.push_back(u);
			}
			if (spent.size() >= 2 && army_count(s, UnitTypes::Protoss_High_Templar) > 2) {
				a_vector<unit_t*> pair{spent[0], spent[1]};
				if (f.action_select(p.owner, pair)) f.action_morph_archon(p.owner);
			}
		}
	}

	// --- buildings ------------------------------------------------------------

	static UnitTypes morphs_from(UnitTypes t) {
		switch (t) {
		case UnitTypes::Zerg_Lair: return UnitTypes::Zerg_Hatchery;
		case UnitTypes::Zerg_Hive: return UnitTypes::Zerg_Lair;
		case UnitTypes::Zerg_Greater_Spire: return UnitTypes::Zerg_Spire;
		default: return UnitTypes::None;
		}
	}

	void follow_plan(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		for (auto& step : plan_of(p)) {
			if (!step_applies(p, step.where)) continue;
			if (s.supply_used < step.supply) break;
			int have = s.planned[(size_t)step.type];
			if (step.type == UnitTypes::Zerg_Lair) have = s.planned[(size_t)UnitTypes::Zerg_Lair] + s.planned[(size_t)UnitTypes::Zerg_Hive];
			if (have >= step.count) continue;
			if (p.colony_mode && is_production(step.type) && have >= 1) continue;
			const unit_type_t* ut = f.get_unit_type(step.type);
			UnitTypes base = morphs_from(step.type);
			bool ok = false;
			if (base != UnitTypes::None) {
				unit_t* from = nullptr;
				for (unit_t* b : s.buildings) {
					if (f.unit_is(b, base) && f.u_completed(b) && b->build_queue.empty() && !b->building.researching_type && !b->building.upgrading_type) {
						from = b;
						break;
					}
				}
				if (!from || !f.unit_can_build(from, ut)) continue; // requirements still missing
				if (!affordable(ut, minerals, gas)) {
					minerals -= ut->mineral_cost;
					gas -= ut->gas_cost;
					return;
				}
				if (select(f, p, from)) ok = f.action_morph_building(p.owner, ut);
			} else {
				unit_t* any_worker = s.workers.empty() ? nullptr : s.workers.front();
				if (!any_worker || !f.unit_can_build(any_worker, ut)) continue;
				if (!affordable(ut, minerals, gas)) {
					// Save for this step instead of spending on units.
					minerals -= ut->mineral_cost;
					gas -= ut->gas_cost;
					return;
				}
				ok = place(f, p, s, step.type);
			}
			if (ok) {
				minerals -= ut->mineral_cost;
				gas -= ut->gas_cost;
			}
			return; // one building per decision
		}
		// Gas at every base from the middle game on: the tech tree runs on it.
		if (f.st.current_frame > p.cfg.economy.gas_everywhere_after) {
			int refineries = s.planned[(size_t)gas_of(p.race)];
			if (refineries < (int)s.depots.size()) {
				const unit_type_t* ut = f.get_unit_type(gas_of(p.race));
				if (affordable(ut, minerals, gas) && place(f, p, s, gas_of(p.race))) minerals -= ut->mineral_cost;
			}
		}
	}

	// An addon for b: 1 ordered, 0 saving up for it, -1 it can't go there.
	int build_addon_of(action_functions& f, player& p, unit_t* b, UnitTypes type, int& minerals, int& gas) {
		const unit_type_t* ut = f.get_unit_type(type);
		if (!f.unit_can_build(b, ut)) return -1;
		if (!affordable(ut, minerals, gas)) {
			// Saved for: units wait.
			minerals -= ut->mineral_cost;
			gas -= ut->gas_cost;
			return 0;
		}
		xy top_left = b->sprite->position - b->unit_type->placement_size / 2;
		xy_t<size_t> tile((size_t)((top_left.x + ut->addon_position.x) / 32), (size_t)((top_left.y + ut->addon_position.y) / 32));
		if (select(f, p, b) && f.action_build(p.owner, f.get_order_type(Orders::PlaceAddon), ut, tile)) {
			minerals -= ut->mineral_cost;
			gas -= ut->gas_cost;
			return 1;
		}
		return -1;
	}

	// Terran addons: machine shops, control towers, a physics lab and covert
	// ops on the science facilities, a nuclear silo and comsats on the
	// command centers. The silo first, then the rest, comsats last; one at
	// a time, and a spot that's blocked doesn't hold up the others.
	void manage_addons(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		if (p.race != race_t::terran) return;
		int silos = s.planned[(size_t)UnitTypes::Terran_Nuclear_Silo];
		int comsats = s.planned[(size_t)UnitTypes::Terran_Comsat_Station];
		bool labs = s.planned[(size_t)UnitTypes::Terran_Physics_Lab] > 0, ops = s.planned[(size_t)UnitTypes::Terran_Covert_Ops] > 0;
		struct job {
			unit_t* b;
			UnitTypes type;
			int rank;
		};
		a_vector<job> jobs;
		for (unit_t* b : s.buildings) {
			if (!f.u_completed(b) || b->building.addon || !b->build_queue.empty() || f.u_flying(b)) continue;
			if (b->building.researching_type || b->building.upgrading_type) continue;
			switch (b->unit_type->id) {
			case UnitTypes::Terran_Factory: jobs.push_back({b, UnitTypes::Terran_Machine_Shop, 1}); break;
			case UnitTypes::Terran_Starport: jobs.push_back({b, UnitTypes::Terran_Control_Tower, 2}); break;
			case UnitTypes::Terran_Science_Facility:
				if (!labs) jobs.push_back({b, UnitTypes::Terran_Physics_Lab, 1});
				else if (!ops) jobs.push_back({b, UnitTypes::Terran_Covert_Ops, 1});
				break;
			case UnitTypes::Terran_Command_Center:
				// The main command center keeps its slot for the silo.
				if (dist2(b->sprite->position, p.home) < 320 * 320 || (silos == 0 && comsats > 0)) {
					if (s.done[(size_t)UnitTypes::Terran_Covert_Ops] && silos < (f.st.current_frame > p.cfg.defense.silos_late_after ? p.cfg.defense.silos_late : p.cfg.defense.silos)) jobs.push_back({b, UnitTypes::Terran_Nuclear_Silo, 0});
				} else if (s.done[(size_t)UnitTypes::Terran_Academy] && comsats < p.cfg.defense.max_comsats) {
					jobs.push_back({b, UnitTypes::Terran_Comsat_Station, 3});
				}
				break;
			default: break;
			}
		}
		std::stable_sort(jobs.begin(), jobs.end(), [](const job& a, const job& b) { return a.rank < b.rank; });
		for (auto& j : jobs) {
			if (build_addon_of(f, p, j.b, j.type, minerals, gas) >= 0) return;
		}
	}

	void research2(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		auto fits = [&](unit_t* b, UnitTypes want) {
			if (f.unit_is(b, want)) return true;
			if (want == UnitTypes::Zerg_Lair) return f.unit_is(b, UnitTypes::Zerg_Hive);
			if (want == UnitTypes::Zerg_Spire) return f.unit_is(b, UnitTypes::Zerg_Greater_Spire);
			return false;
		};
		for (auto& r : research_of(p)) {
			if (!step_applies(p, r.where) || s.supply_used < r.supply) continue;
			for (unit_t* b : s.buildings) {
				if (!fits(b, r.building) || !f.u_completed(b)) continue;
				if (b->building.researching_type || b->building.upgrading_type || !b->build_queue.empty()) continue;
				if (r.is_tech) {
					const tech_type_t* t = f.get_tech_type((TechTypes)r.id);
					if (!f.unit_can_research(b, t, p.owner)) continue;
					if (minerals < t->mineral_cost || gas < t->gas_cost) {
						minerals -= t->mineral_cost; // saved for: units wait
						gas -= t->gas_cost;
						return;
					}
					if (select(f, p, b) && f.action_research(p.owner, t)) {
						minerals -= t->mineral_cost;
						gas -= t->gas_cost;
					}
				} else {
					const upgrade_type_t* t = f.get_upgrade_type((UpgradeTypes)r.id);
					if (!f.unit_can_upgrade(b, t, p.owner)) continue;
					int mc = f.upgrade_mineral_cost(p.owner, t), gc = f.upgrade_gas_cost(p.owner, t);
					if (minerals < mc || gas < gc) {
						minerals -= mc;
						gas -= gc;
						return;
					}
					if (select(f, p, b) && f.action_upgrade(p.owner, t)) {
						minerals -= mc;
						gas -= gc;
					}
				}
				break;
			}
		}
	}

	// Silos keep a nuke armed (at most two at a time).
	void arm_silos(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		const unit_type_t* nuke = f.get_unit_type(UnitTypes::Terran_Nuclear_Missile);
		for (unit_t* b : s.buildings) {
			if (!f.unit_is(b, UnitTypes::Terran_Nuclear_Silo) || !f.u_completed(b)) continue;
			if (b->building.silo.nuke || !b->build_queue.empty()) continue;
			if (s.supply_used + 8 > s.supply_max) return;
			if (!affordable(nuke, minerals, gas)) {
				minerals -= nuke->mineral_cost;
				gas -= nuke->gas_cost;
				return;
			}
			if (select(f, p, b) && f.action_train(p.owner, nuke)) {
				f.set_unit_order(b, f.get_order_type(Orders::NukeTrain));
				ai_log(f, p, "arm-silo", 0);
				minerals -= nuke->mineral_cost;
				gas -= nuke->gas_cost;
			}
			return;
		}
	}

	// Anti-air at every base when the enemies fly (or can only be reached by
	// air, so they will come that way too): missile turrets, photon cannons
	// or spore colonies, more the bigger the enemy air force.
	void air_defense(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		int frame = f.st.current_frame;
		if (frame < p.next_air_defense) return;
		auto& c = p.cfg.defense;
		if (!p.island && p.enemy_air < c.air_trigger) return;
		if (p.island && frame < c.air_island_after && p.enemy_air == 0) return;
		int want = std::max(p.island ? c.air_island_min : 1, std::min(c.air_max, p.enemy_air / c.air_per + 1));
		UnitTypes tech = p.race == race_t::terran ? UnitTypes::Terran_Engineering_Bay
		                 : p.race == race_t::protoss ? UnitTypes::Protoss_Forge
		                                             : UnitTypes::Zerg_Evolution_Chamber;
		if (!s.done[(size_t)tech]) {
			if (!s.planned[(size_t)tech]) {
				const unit_type_t* ut = f.get_unit_type(tech);
				if (affordable(ut, minerals, gas) && place(f, p, s, tech)) minerals -= ut->mineral_cost;
			}
			p.next_air_defense = frame + 24 * 5;
			return;
		}
		for (unit_t* d : s.depots) {
			xy at = d->sprite->position;
			int air = 0;
			unit_t* pylon = nullptr;
			unit_t* creep_colony = nullptr;
			for (unit_t* b : s.buildings) {
				if (dist2(b->sprite->position, at) > 352 * 352) continue;
				auto t = b->unit_type->id;
				if (t == UnitTypes::Terran_Missile_Turret || t == UnitTypes::Zerg_Spore_Colony || t == UnitTypes::Protoss_Photon_Cannon) ++air;
				if (t == UnitTypes::Protoss_Pylon && (!pylon || f.u_completed(b))) pylon = b;
				if (t == UnitTypes::Zerg_Creep_Colony) {
					if (f.u_completed(b) && b->build_queue.empty()) creep_colony = b;
					else ++air;
				}
			}
			if (air >= want) continue;
			if (p.race == race_t::zerg && creep_colony) {
				const unit_type_t* spore = f.get_unit_type(UnitTypes::Zerg_Spore_Colony);
				if (affordable(spore, minerals, gas) && select(f, p, creep_colony) && f.action_morph_building(p.owner, spore)) minerals -= spore->mineral_cost;
				p.next_air_defense = frame + 24 * 2;
				return;
			}
			UnitTypes type = p.race == race_t::terran ? UnitTypes::Terran_Missile_Turret
			                 : p.race == race_t::zerg ? UnitTypes::Zerg_Creep_Colony
			                                          : (pylon && f.u_completed(pylon) ? UnitTypes::Protoss_Photon_Cannon : UnitTypes::Protoss_Pylon);
			if (p.race == race_t::protoss && pylon && !f.u_completed(pylon)) continue;
			const unit_type_t* ut = f.get_unit_type(type);
			if (!affordable(ut, minerals, gas)) return;
			xy center = type == UnitTypes::Protoss_Photon_Cannon ? pylon->sprite->position : at;
			if (place_near(f, p, s, type, center, type == UnitTypes::Protoss_Photon_Cannon ? 1 : 2, 9)) {
				minerals -= ut->mineral_cost;
				gas -= ut->gas_cost;
				p.next_air_defense = frame + 24 * 8;
			} else {
				p.next_air_defense = frame + 24 * 4;
			}
			return;
		}
		p.next_air_defense = frame + 24 * 6;
	}

	// --- the army ---------------------------------------------------------------

	static bool is_transport(UnitTypes t) {
		return t == UnitTypes::Terran_Dropship || t == UnitTypes::Protoss_Shuttle || t == UnitTypes::Zerg_Overlord;
	}

	// Units that support the army rather than fight at its head.
	static bool is_support(UnitTypes t) {
		switch (t) {
		case UnitTypes::Terran_Science_Vessel:
		case UnitTypes::Protoss_Observer:
		case UnitTypes::Protoss_High_Templar:
		case UnitTypes::Protoss_Dark_Archon:
		case UnitTypes::Zerg_Defiler:
		case UnitTypes::Zerg_Queen:
			return true;
		default:
			return false;
		}
	}

	bool in_drop(player& p, action_functions& f, unit_t* u) {
		uint32_t id = f.get_unit_id(u).raw_value;
		for (auto& d : p.drops) {
			if (d.transport == id) return true;
			if (std::find(d.passengers.begin(), d.passengers.end(), id) != d.passengers.end()) return true;
		}
		return false;
	}

	// The nearest enemy building to `from`, only ones reachable on the ground
	// from `from` when `ground`.
	unit_t* target_building(action_functions& f, player& p, xy from, bool ground) {
		unit_t* best = nullptr;
		int best_d = 0;
		if (p.focus >= 0 && is_enemy(f, p.owner, p.focus)) {
			for (unit_t* u : ptr(f.st.player_units.at(p.focus))) {
				if (f.unit_dead(u) || !u->sprite || !f.ut_building(u) || f.u_flying(u)) continue;
				if (ground && !f.is_reachable(from, u->sprite->position)) continue;
				int d = dist2(u->sprite->position, from);
				if (!best || d < best_d) {
					best = u;
					best_d = d;
				}
			}
			if (best) return best;
		} else {
			p.focus = -1;
		}
		for (int o = 0; o != 8; ++o) {
			if (!is_enemy(f, p.owner, o)) continue;
			for (unit_t* u : ptr(f.st.player_units.at(o))) {
				if (f.unit_dead(u) || !u->sprite || !f.ut_building(u) || f.us_hidden(u)) continue;
				if (ground && (f.u_flying(u) || !f.is_reachable(from, u->sprite->position))) continue;
				int d = dist2(u->sprite->position, from);
				if (!best || d < best_d) {
					best = u;
					best_d = d;
				}
			}
		}
		return best;
	}

	void order_units(action_functions& f, player& p, const a_vector<unit_t*>& units, Orders order, xy pos, unit_t* target) {
		const order_type_t* o = f.get_order_type(order);
		a_vector<unit_t*> batch;
		for (size_t i = 0; i < units.size(); ++i) {
			batch.push_back(units[i]);
			if (batch.size() == 12 || i + 1 == units.size()) {
				f.action_select(p.owner, batch);
				f.action_order(p.owner, o, f.restrict_pos_to_map_bounds(pos), target, target ? target->unit_type : nullptr, false);
				batch.clear();
			}
		}
	}

	void defend2(action_functions& f, player& p, snapshot& s, unit_t* intruder) {
		p.attacking = false;
		bool air = f.u_flying(intruder);
		a_vector<unit_t*> army, support;
		for (unit_t* u : s.army) {
			if (in_drop(p, f, u)) continue;
			auto t = u->unit_type->id;
			if (is_transport(t)) continue;
			if (is_support(t)) {
				support.push_back(u);
				continue;
			}
			if (!f.unit_can_attack(u)) continue;
			// Only those that can hit it (and reach it) answer.
			if (air ? !f.unit_or_subunit_air_weapon(u) && !f.unit_interceptor_count(u) : !f.u_flying(u) && !f.is_reachable(u->sprite->position, intruder->sprite->position)) continue;
			if (is_idle(u) || u->order_type->id == Orders::Move || u->order_type->id == Orders::AttackMove) army.push_back(u);
		}
		if (!army.empty()) order_units(f, p, army, Orders::AttackMove, intruder->sprite->position, nullptr);
		a_vector<unit_t*> go;
		for (unit_t* u : support) {
			if (is_idle(u) && dist2(u->sprite->position, intruder->sprite->position) > 256 * 256) go.push_back(u);
		}
		if (!go.empty()) order_units(f, p, go, Orders::Move, intruder->sprite->position, nullptr);
		// Workers fight off a small ground raid when there is no army.
		int ours = 0, theirs = 0;
		for (unit_t* u : army) ours += value_of(u);
		for (int o = 0; o != 8; ++o) {
			if (!is_enemy(f, p.owner, o)) continue;
			for (unit_t* u : ptr(f.st.player_units.at(o))) {
				if (f.unit_dead(u) || !u->sprite || f.ut_worker(u) || f.ut_building(u)) continue;
				if (dist2(u->sprite->position, intruder->sprite->position) < 384 * 384) theirs += value_of(u);
			}
		}
		if (ours >= theirs || air) return;
		size_t pull = (size_t)(ours == 0 ? p.cfg.defense.militia_all : p.cfg.defense.militia_some);
		a_vector<unit_t*> militia;
		for (unit_t* w : s.workers) {
			if (militia.size() >= pull) break;
			// Workers on their way to build (a new base) keep going.
			if (building_order(w->order_type->id) || w->order_type->id == Orders::ConstructingBuilding) continue;
			if (dist2(w->sprite->position, intruder->sprite->position) < 320 * 320) militia.push_back(w);
		}
		if (militia.empty()) return;
		order_units(f, p, militia, Orders::AttackMove, intruder->sprite->position, nullptr);
		p.militia_until = f.st.current_frame + p.cfg.defense.militia_time;
	}

	// Where a drop lands: by the target, on its side of the water.
	xy landing_spot(action_functions& f, player& p, xy target) {
		xy d = p.home - target;
		int len = std::max(1, f.xy_length(d));
		for (int r : {160, 96, 32}) {
			xy at = f.restrict_pos_to_map_bounds(target + d * r / len);
			if (f.is_walkable(at) && f.is_reachable(at, target)) return at;
		}
		return target;
	}

	a_vector<unit_t*> free_transports(action_functions& f, player& p, snapshot& s) {
		a_vector<unit_t*> out;
		auto consider = [&](unit_t* u) {
			if (!f.unit_provides_space(u) || in_drop(p, f, u) || !f.u_completed(u)) return;
			if (!f.loaded_units(u).empty()) return;
			if (dist2(u->sprite->position, p.rally) > 900 * 900) return;
			out.push_back(u);
		};
		for (unit_t* u : s.army) {
			if (f.unit_is(u, UnitTypes::Terran_Dropship) || f.unit_is(u, UnitTypes::Protoss_Shuttle)) consider(u);
		}
		// Zerg overlords carry once Ventral Sacs is researched; a few of them.
		if (p.race == race_t::zerg && f.player_has_upgrade(p.owner, UpgradeTypes::Ventral_Sacs)) {
			int n = 0;
			for (unit_t* u : ptr(f.st.player_units.at(p.owner))) {
				if (n >= p.cfg.drops.overlords) break;
				if (f.unit_dead(u) || !f.unit_is(u, UnitTypes::Zerg_Overlord) || held_by_human(u, f.st.current_frame)) continue;
				size_t before = out.size();
				consider(u);
				if (out.size() > before) ++n;
			}
		}
		return out;
	}

	// Drops: ground units ride to bases they can't walk to.
	void run_drops(action_functions& f, player& p, snapshot& s, unit_t* target, bool start_new) {
		int frame = f.st.current_frame;
		for (size_t i = 0; i < p.drops.size();) {
			auto& d = p.drops[i];
			unit_t* t = resolve(f, d.transport);
			if (!t) {
				p.drops.erase(p.drops.begin() + i);
				continue;
			}
			size_t loaded = 0;
			for (unit_t* c : f.loaded_units(t)) {
				(void)c;
				++loaded;
			}
			a_vector<unit_t*> waiting;
			for (uint32_t id : d.passengers) {
				unit_t* u = resolve(f, id);
				if (u && !f.u_loaded(u)) waiting.push_back(u);
			}
			bool done = false;
			if (d.phase == 0) {
				if (loaded > 0 && (waiting.empty() || frame - d.started > p.cfg.drops.load_time)) {
					d.phase = 1;
					d.last_order = -10000;
				} else if (loaded == 0 && frame - d.started > p.cfg.drops.give_up) {
					done = true;
				} else if (frame - d.last_order > 24 * 4) {
					for (unit_t* u : waiting) {
						if (select(f, p, u)) f.action_order(p.owner, f.get_order_type(Orders::EnterTransport), t->sprite->position, t, t->unit_type, false);
					}
					d.last_order = frame;
				}
			}
			if (d.phase == 1) {
				if (loaded == 0) {
					// Landed: everyone attacks (a worker builds the new base); the
					// transport flies home.
					a_vector<unit_t*> landed;
					for (uint32_t id : d.passengers) {
						if (unit_t* u = resolve(f, id)) landed.push_back(u);
					}
					ai_log(f, p, d.expand ? "landed-expand" : "landed", (int)landed.size());
					if (d.expand) {
						if (!landed.empty()) p.expander = f.get_unit_id(landed.front()).raw_value;
					} else if (!landed.empty()) {
						order_units(f, p, landed, Orders::AttackMove, d.target, nullptr);
					}
					done = true;
				} else if (frame - d.last_order > 24 * 6 && t->order_type->id != Orders::MoveUnload && t->order_type->id != Orders::Unload) {
					if (select(f, p, t)) f.action_order(p.owner, f.get_order_type(Orders::MoveUnload), d.landing, nullptr, nullptr, false);
					d.last_order = frame;
				}
			}
			if (done) {
				if (select(f, p, t)) f.action_order(p.owner, f.get_order_type(Orders::Move), p.rally, nullptr, nullptr, false);
				p.drops.erase(p.drops.begin() + i);
				continue;
			}
			++i;
		}
		if (!start_new || !target || (int)p.drops.size() >= p.cfg.drops.max) return;
		xy goal = target->sprite->position;
		for (unit_t* t : free_transports(f, p, s)) {
			// Ground units at home that can't walk to the target.
			a_vector<unit_t*> riders;
			for (unit_t* u : s.army) {
				if (f.u_flying(u) || is_support(u->unit_type->id) || !f.unit_can_attack(u) || in_drop(p, f, u)) continue;
				if (f.unit_is(u, UnitTypes::Terran_Siege_Tank_Siege_Mode) || f.u_burrowed(u)) continue;
				if (!is_idle(u) && u->order_type->id != Orders::Move) continue;
				if (f.is_reachable(u->sprite->position, goal)) continue;
				if (!f.is_reachable(u->sprite->position, t->sprite->position) && !f.u_flying(t)) continue;
				riders.push_back(u);
			}
			std::stable_sort(riders.begin(), riders.end(), [&](unit_t* a, unit_t* b) {
				return dist2(a->sprite->position, t->sprite->position) < dist2(b->sprite->position, t->sprite->position);
			});
			int space = (int)t->unit_type->space_provided;
			player::drop d;
			d.transport = f.get_unit_id(t).raw_value;
			for (unit_t* u : riders) {
				int need = (int)u->unit_type->space_required;
				if (need > space) continue;
				space -= need;
				d.passengers.push_back(f.get_unit_id(u).raw_value);
				if (space == 0) break;
			}
			if ((int)t->unit_type->space_provided - space < p.cfg.drops.min_space) return; // not worth a trip
			d.target = goal;
			d.landing = landing_spot(f, p, goal);
			d.started = frame;
			d.last_order = -10000;
			p.drops.push_back(d);
			ai_log(f, p, "drop", (int)d.passengers.size());
			if ((int)p.drops.size() >= p.cfg.drops.max) return;
		}
	}

	void command_army2(action_functions& f, player& p, snapshot& s, bool may_attack) {
		int frame = f.st.current_frame;
		if (unit_t* intruder = find_intruder(f, p, s)) {
			defend2(f, p, s, intruder);
			return;
		}
		a_vector<unit_t*> ground, air, support, transports;
		for (unit_t* u : s.army) {
			if (in_drop(p, f, u)) continue;
			auto t = u->unit_type->id;
			if (is_transport(t)) transports.push_back(u);
			else if (is_support(t)) support.push_back(u);
			else if (!f.unit_can_attack(u) && !f.unit_is(u, UnitTypes::Terran_Medic)) support.push_back(u);
			else if (f.u_flying(u)) air.push_back(u);
			else ground.push_back(u);
		}
		// Idle transports wait at home.
		auto home = [&](const a_vector<unit_t*>& units) {
			a_vector<unit_t*> stray;
			for (unit_t* u : units) {
				if (p.colony_mode && guards_colony(f, s, u)) continue;
				if (is_idle(u) && dist2(u->sprite->position, p.rally) > 192 * 192) stray.push_back(u);
			}
			if (!stray.empty()) order_units(f, p, stray, Orders::Move, p.rally, nullptr);
		};
		home(transports);

		if (!may_attack) {
			a_vector<unit_t*> detachment;
			if (p.fortifying) detachment = help_allies(f, p, s);
			a_vector<unit_t*> rest;
			for (auto* list : {&ground, &air, &support}) {
				for (unit_t* u : *list) {
					if (std::find(detachment.begin(), detachment.end(), u) == detachment.end()) rest.push_back(u);
				}
			}
			home(rest);
			run_drops(f, p, s, nullptr, false);
			return;
		}

		unit_t* any_target = target_building(f, p, p.home, false);
		unit_t* ground_target = target_building(f, p, p.rally, true);
		bool can_drop = !free_transports(f, p, s).empty() || !p.drops.empty();
		// Who can join the next wave: flyers, and walkers when there is a
		// base to walk to (or a transport to carry them).
		int ready = (int)air.size() + (ground_target ? (int)ground.size() : can_drop ? (int)ground.size() / 2 : 0);
		if (!p.attacking) {
			bool go = ready >= p.wave_size && any_target && frame >= p.hold_until;
			if (any_target && ready > 0) {
				auto r = fire(f, p, &s, botscript::h_wave, {ready});
				if (r.value) go = r.v != 0;
			}
			if (frame < p.hold_until) go = false; // steered from outside: that comes first
			if (go) {
				p.attacking = true;
				p.last_attack_order = -10000;
				ai_log(f, p, "wave", ready);
			} else {
				home(ground);
				home(air);
				home(support);
				run_drops(f, p, s, nullptr, false);
				return;
			}
		}
		auto& c = p.cfg.army;
		if (ready < std::max(c.wave_end_min, p.wave_size / c.wave_end_div) && p.drops.empty()) {
			p.attacking = false;
			p.wave_size = std::min(c.wave_max, p.wave_size + c.wave_grow);
			return;
		}
		if (!any_target) return;
		bool refresh = frame - p.last_attack_order > c.attack_refresh;
		if (refresh) p.last_attack_order = frame;
		a_vector<unit_t*> go_air, go_ground, waiting;
		for (unit_t* u : air) {
			if (refresh || is_idle(u) || u->order_type->id == Orders::Move) go_air.push_back(u);
		}
		for (unit_t* u : ground) {
			if (!refresh && !is_idle(u) && u->order_type->id != Orders::Move) continue;
			if (f.unit_is(u, UnitTypes::Terran_Siege_Tank_Siege_Mode) || f.u_burrowed(u)) continue; // abilities move these
			unit_t* t = target_building(f, p, u->sprite->position, true);
			if (t) {
				go_ground.push_back(u);
				// Walkers already on an enemy island fight there.
				if (!ground_target || !f.is_reachable(u->sprite->position, ground_target->sprite->position)) {
					order_units(f, p, {u}, Orders::AttackMove, t->sprite->position, nullptr);
					go_ground.pop_back();
				}
			} else {
				waiting.push_back(u);
			}
		}
		if (!go_air.empty()) order_units(f, p, go_air, Orders::AttackMove, any_target->sprite->position, nullptr);
		if (!go_ground.empty() && ground_target) order_units(f, p, go_ground, Orders::AttackMove, ground_target->sprite->position, nullptr);
		home(waiting);
		// Casters keep up with the army (the biggest group of fighters).
		const a_vector<unit_t*>& lead = go_air.size() > go_ground.size() ? air : ground;
		if (!lead.empty()) {
			xy sum;
			for (unit_t* u : lead) sum += u->sprite->position;
			xy center = sum / (int)lead.size();
			a_vector<unit_t*> follow;
			for (unit_t* u : support) {
				if (!f.u_flying(u) && !f.is_reachable(u->sprite->position, center)) continue;
				if ((refresh || is_idle(u)) && dist2(u->sprite->position, center) > 160 * 160) follow.push_back(u);
			}
			if (!follow.empty()) order_units(f, p, follow, Orders::Move, center, nullptr);
		}
		// Walkers that can't get there go by air.
		run_drops(f, p, s, any_target, !ground_target || p.some_island);
	}

	// --- abilities ---------------------------------------------------------------

	// Enemy units by area, rebuilt for each player's turn.
	struct enemy_grid {
		int cols = 0, rows = 0;
		a_vector<a_vector<unit_t*>> cells;
		static const int cell = 256;
		void build(ai_system& ai, action_functions& f, player& p) {
			cols = (int)f.game_st.map_width / cell + 1;
			rows = (int)f.game_st.map_height / cell + 1;
			cells.assign((size_t)(cols * rows), {});
			for (int o = 0; o != 8; ++o) {
				if (!ai.is_enemy(f, p.owner, o)) continue;
				for (unit_t* u : ptr(f.st.player_units.at(o))) {
					if (f.unit_dead(u) || !u->sprite || f.us_hidden(u) || f.u_hallucination(u)) continue;
					xy at = u->sprite->position;
					cells[(size_t)(std::min(rows - 1, at.y / cell) * cols + std::min(cols - 1, at.x / cell))].push_back(u);
				}
			}
		}
		template<typename F>
		void near(xy at, int r, F&& fn) const {
			int x0 = std::max(0, (at.x - r) / cell), x1 = std::min(cols - 1, (at.x + r) / cell);
			int y0 = std::max(0, (at.y - r) / cell), y1 = std::min(rows - 1, (at.y + r) / cell);
			for (int y = y0; y <= y1; ++y) {
				for (int x = x0; x <= x1; ++x) {
					for (unit_t* u : cells[(size_t)(y * cols + x)]) {
						if (dist2(u->sprite->position, at) <= r * r) fn(u);
					}
				}
			}
		}
	};

	std::array<const order_type_t*, (size_t)TechTypes::None> tech_orders{};
	bool tech_orders_ready = false;

	const order_type_t* tech_order(action_functions& f, TechTypes t) {
		if (!tech_orders_ready) {
			tech_orders_ready = true;
			for (auto& o : f.st.global->order_types.vec) {
				size_t i = (size_t)o.tech_type;
				if (i < tech_orders.size() && !tech_orders[i]) tech_orders[i] = &o;
			}
		}
		return (size_t)t < tech_orders.size() ? tech_orders[(size_t)t] : nullptr;
	}

	bool can_cast(action_functions& f, player& p, unit_t* u, TechTypes t) {
		const tech_type_t* tech = f.get_tech_type(t);
		if (!f.unit_can_use_tech(u, tech, p.owner)) return false;
		return u->energy >= fp8::integer(tech->energy_cost);
	}

	bool cast(action_functions& f, player& p, unit_t* u, TechTypes t, xy pos, unit_t* target) {
		if (!can_cast(f, p, u, t)) return false;
		const order_type_t* o = tech_order(f, t);
		if (!o || !select(f, p, u)) return false;
		if (!f.action_order(p.owner, o, pos, target, target ? target->unit_type : nullptr, false)) return false;
		mark_cast(u, f.st.current_frame);
		ai_log(f, p, "cast", (int)t);
		return true;
	}

	// BROOD_AI_LOG=<file>: what the computer players do with their units
	// (spells, nukes, drops), appended to that file. For testing.
	static FILE* log_file() {
		static FILE* file = [] {
			const char* path = std::getenv("BROOD_AI_LOG");
			return path ? std::fopen(path, "a") : nullptr;
		}();
		return file;
	}
	void ai_log(action_functions& f, const player& p, const char* what, int detail) {
		if (FILE* out = log_file()) {
			std::fprintf(out, "ai %d f%d %s %d\n", p.owner, f.st.current_frame, what, detail);
			std::fflush(out);
		}
	}

	void mark_cast(const unit_t* u, int frame) {
		if (cast_frame.size() <= u->index) cast_frame.resize(u->index + 1, -100000);
		cast_frame[u->index] = frame;
	}

	bool cast_recently(const unit_t* u, int frame, int frames) const {
		return u->index < cast_frame.size() && frame - cast_frame[u->index] < frames;
	}

	// The spot near `at` (within `search`) where enemy units passing `filter`
	// are thickest (within `radius` of it). Returns its total value and the
	// unit at the center.
	template<typename F>
	std::pair<unit_t*, int> best_cluster(const enemy_grid& g, xy at, int search, int radius, F&& filter) {
		a_vector<unit_t*> cand;
		g.near(at, search, [&](unit_t* u) {
			if (filter(u)) cand.push_back(u);
		});
		unit_t* best = nullptr;
		int best_v = 0;
		for (unit_t* c : cand) {
			int v = 0;
			for (unit_t* o : cand) {
				if (dist2(o->sprite->position, c->sprite->position) <= radius * radius) v += value_of(o) + 25;
			}
			if (v > best_v) {
				best = c;
				best_v = v;
			}
		}
		return {best, best_v};
	}

	// Value of our own units within `radius` of `at` (spells hit them too).
	int own_value_near(action_functions& f, player& p, xy at, int radius) {
		int v = 0;
		for (unit_t* u : ptr(f.st.player_units.at(p.owner))) {
			if (f.unit_dead(u) || !u->sprite || f.ut_building(u)) continue;
			if (dist2(u->sprite->position, at) <= radius * radius) v += value_of(u) + 25;
		}
		return v;
	}

	static bool is_defense_building(UnitTypes t) {
		return t == UnitTypes::Terran_Bunker || t == UnitTypes::Terran_Missile_Turret || t == UnitTypes::Protoss_Photon_Cannon ||
		       t == UnitTypes::Zerg_Sunken_Colony || t == UnitTypes::Zerg_Spore_Colony;
	}

	void use_abilities(action_functions& f, player& p, snapshot& s, bool attacking) {
		int frame = f.st.current_frame;
		enemy_grid g;
		g.build(*this, f, p);
		auto enemy_near = [&](xy at, int r, bool ground_only) {
			bool any = false;
			g.near(at, r, [&](unit_t* e) {
				if (any || f.ut_building(e) && !is_defense_building(e->unit_type->id)) return;
				if (ground_only && f.u_flying(e)) return;
				if (f.ut_worker(e)) return;
				any = true;
			});
			return any;
		};
		auto unit_value_ok = [&](unit_t* e) { return !f.ut_building(e) && !f.ut_worker(e); };

		// Nukes: a ghost walks to the biggest enemy base it can reach.
		bool nuke_ready = false;
		for (unit_t* b : s.buildings) {
			if (f.unit_is(b, UnitTypes::Terran_Nuclear_Silo) && b->building.silo.ready) nuke_ready = true;
		}

		for (unit_t* u : s.army) {
			if (cast_recently(u, frame, 24)) continue;
			xy at = u->sprite->position;
			switch (u->unit_type->id) {
			case UnitTypes::Terran_Marine:
			case UnitTypes::Terran_Firebat:
				if (u->stim_timer == 0 && u->hp > u->unit_type->hitpoints / 2 && f.unit_can_use_tech(u, f.get_tech_type(TechTypes::Stim_Packs), p.owner) && enemy_near(at, 192, false)) {
					if (select(f, p, u) && f.action_stim_pack(p.owner)) {
						mark_cast(u, frame);
						ai_log(f, p, "stim", 0);
					}
				}
				break;
			case UnitTypes::Terran_Siege_Tank_Tank_Mode:
				if (!f.player_has_researched(p.owner, TechTypes::Tank_Siege_Mode)) break;
				if (enemy_near(at, 384, true) || (!p.attacking && is_idle(u) && dist2(at, p.rally) < 256 * 256)) {
					if (select(f, p, u) && f.action_siege(p.owner, false)) {
						mark_cast(u, frame + 24 * 3);
						ai_log(f, p, "siege", 0);
					}
				}
				break;
			case UnitTypes::Terran_Siege_Tank_Siege_Mode:
				if (!enemy_near(at, 448, true) && (p.attacking || dist2(at, p.rally) > 320 * 320)) {
					if (select(f, p, u) && f.action_unsiege(p.owner, false)) mark_cast(u, frame + 24 * 3);
				}
				break;
			case UnitTypes::Terran_Vulture: {
				if (f.unit_spider_mine_count(u) == 0 || !can_cast(f, p, u, TechTypes::Spider_Mines)) break;
				unit_t* near_enemy = nullptr;
				g.near(at, 320, [&](unit_t* e) {
					if (!near_enemy && !f.u_flying(e) && !f.ut_building(e)) near_enemy = e;
				});
				if (near_enemy) {
					cast(f, p, u, TechTypes::Spider_Mines, at + (near_enemy->sprite->position - at) / 3, nullptr);
				} else if (is_idle(u) && dist2(at, p.rally) < 320 * 320 && f.unit_spider_mine_count(u) >= 2) {
					// A minefield in front of the base.
					// (Integer offsets only: the simulation must come out the same everywhere.)
					static const int dx[8] = {128, 90, 0, -90, -128, -90, 0, 90}, dy[8] = {0, 90, 128, 90, 0, -90, -128, -90};
					int k = (int)(p.next() % 8);
					xy off(dx[k], dy[k]);
					cast(f, p, u, TechTypes::Spider_Mines, f.restrict_pos_to_map_bounds(p.rally + off), nullptr);
				}
				break;
			}
			case UnitTypes::Terran_Wraith:
			case UnitTypes::Terran_Ghost: {
				bool ghost = f.unit_is(u, UnitTypes::Terran_Ghost);
				TechTypes cloak = ghost ? TechTypes::Personnel_Cloaking : TechTypes::Cloaking_Field;
				if (!f.u_cloaked(u) && can_cast(f, p, u, cloak) && enemy_near(at, 320, false)) {
					if (select(f, p, u) && f.action_cloak(p.owner)) {
						mark_cast(u, frame);
						ai_log(f, p, "cloak", 0);
						break;
					}
				}
				if (!ghost) break;
				if (can_cast(f, p, u, TechTypes::Lockdown)) {
					unit_t* best = nullptr;
					g.near(at, 288, [&](unit_t* e) {
						if (f.ut_mechanical(e) && !f.ut_building(e) && value_of(e) >= p.cfg.spells.lockdown && !e->lockdown_timer && (!best || value_of(e) > value_of(best))) best = e;
					});
					if (best && cast(f, p, u, TechTypes::Lockdown, best->sprite->position, best)) break;
				}
				if (nuke_ready && frame - p.last_nuke > p.cfg.spells.nuke_interval && (is_idle(u) || u->order_type->id == Orders::Move)) {
					// The enemy base with the most buildings the ghost can walk to.
					unit_t* best = nullptr;
					int best_v = 0;
					for (int o = 0; o != 8; ++o) {
						if (!is_enemy(f, p.owner, o)) continue;
						for (unit_t* b : ptr(f.st.player_units.at(o))) {
							if (f.unit_dead(b) || !b->sprite || !f.ut_building(b) || !f.ut_resource_depot(b)) continue;
							if (!f.is_reachable(at, b->sprite->position)) continue;
							int v = 0;
							for (unit_t* n : ptr(f.st.player_units.at(o))) {
								if (!f.unit_dead(n) && n->sprite && dist2(n->sprite->position, b->sprite->position) < 256 * 256) v += value_of(n);
							}
							v -= dist2(b->sprite->position, at) / 4096;
							if (!best || v > best_v) {
								best = b;
								best_v = v;
							}
						}
					}
					if (best && select(f, p, u) && f.action_order(p.owner, f.get_order_type(Orders::NukePaint), best->sprite->position, nullptr, nullptr, false)) {
						p.last_nuke = frame;
						ai_log(f, p, "nuke", (int)best->unit_type->id);
						mark_cast(u, frame + 24 * 30);
					}
				}
				break;
			}
			case UnitTypes::Terran_Battlecruiser:
				if (can_cast(f, p, u, TechTypes::Yamato_Gun)) {
					unit_t* best = nullptr;
					g.near(at, 320, [&](unit_t* e) {
						if (f.ut_worker(e)) return;
						int v = value_of(e) + (is_defense_building(e->unit_type->id) ? p.cfg.spells.yamato_defense_bonus : 0);
						if (v >= p.cfg.spells.yamato && (!best || v > value_of(best))) best = e;
					});
					if (best) cast(f, p, u, TechTypes::Yamato_Gun, best->sprite->position, best);
				}
				break;
			case UnitTypes::Terran_Science_Vessel: {
				if (can_cast(f, p, u, TechTypes::Irradiate)) {
					unit_t* best = nullptr;
					int best_v = 0;
					g.near(at, 320, [&](unit_t* e) {
						if (!f.ut_organic(e) || f.ut_building(e) || f.ut_worker(e)) return;
						int v = value_of(e);
						g.near(e->sprite->position, 64, [&](unit_t* n) {
							if (n != e && f.ut_organic(n) && !f.ut_building(n)) v += value_of(n);
						});
						if (v >= p.cfg.spells.irradiate && v > best_v) {
							best = e;
							best_v = v;
						}
					});
					if (best && cast(f, p, u, TechTypes::Irradiate, best->sprite->position, best)) break;
				}
				if (can_cast(f, p, u, TechTypes::EMP_Shockwave)) {
					auto c = best_cluster(g, at, 320, 96, [&](unit_t* e) { return e->unit_type->has_shield && e->shield_points > fp8::integer(20); });
					if (c.first && c.second >= p.cfg.spells.emp && cast(f, p, u, TechTypes::EMP_Shockwave, c.first->sprite->position, nullptr)) break;
				}
				if (can_cast(f, p, u, TechTypes::Defensive_Matrix)) {
					for (unit_t* a : s.army) {
						if (a == u || dist2(a->sprite->position, at) > 256 * 256 || a->defensive_matrix_hp != fp8::zero()) continue;
						if (value_of(a) < p.cfg.spells.matrix || a->hp * 10 > a->unit_type->hitpoints * 7) continue;
						if (cast(f, p, u, TechTypes::Defensive_Matrix, a->sprite->position, a)) break;
					}
				}
				break;
			}
			case UnitTypes::Protoss_High_Templar:
				if (can_cast(f, p, u, TechTypes::Psionic_Storm)) {
					auto c = best_cluster(g, at, 320, 48, unit_value_ok);
					if (c.first && c.second >= p.cfg.spells.storm && own_value_near(f, p, c.first->sprite->position, 64) * 3 < c.second) {
						cast(f, p, u, TechTypes::Psionic_Storm, c.first->sprite->position, nullptr);
					}
				}
				break;
			case UnitTypes::Protoss_Arbiter:
				if (can_cast(f, p, u, TechTypes::Stasis_Field)) {
					auto c = best_cluster(g, at, 320, 64, unit_value_ok);
					if (c.first && c.second >= p.cfg.spells.stasis && own_value_near(f, p, c.first->sprite->position, 96) * 2 < c.second) {
						cast(f, p, u, TechTypes::Stasis_Field, c.first->sprite->position, nullptr);
					}
				}
				break;
			case UnitTypes::Protoss_Corsair:
				if (can_cast(f, p, u, TechTypes::Disruption_Web)) {
					auto c = best_cluster(g, at, 288, 64, [&](unit_t* e) { return !f.u_flying(e) && (is_defense_building(e->unit_type->id) || unit_value_ok(e)); });
					if (c.first && c.second >= p.cfg.spells.web) cast(f, p, u, TechTypes::Disruption_Web, c.first->sprite->position, nullptr);
				}
				break;
			case UnitTypes::Protoss_Carrier:
			case UnitTypes::Protoss_Reaver: {
				bool carrier = f.unit_is(u, UnitTypes::Protoss_Carrier);
				size_t have = carrier ? f.unit_interceptor_count(u) : f.unit_scarab_count(u);
				size_t max = carrier ? f.unit_max_interceptor_count(u) : f.unit_max_scarab_count(u);
				if (have + f.unit_queued_fighter_units(u) < max && u->build_queue.size() < 2 && f.st.current_minerals[p.owner] >= 50) {
					if (select(f, p, u)) f.action_train_fighter(p.owner);
				}
				break;
			}
			case UnitTypes::Zerg_Defiler: {
				if (u->energy < fp8::integer(100) && can_cast(f, p, u, TechTypes::Consume)) {
					for (unit_t* a : s.army) {
						if (f.unit_is(a, UnitTypes::Zerg_Zergling) && dist2(a->sprite->position, at) < 160 * 160) {
							if (cast(f, p, u, TechTypes::Consume, a->sprite->position, a)) break;
						}
					}
				}
				if (can_cast(f, p, u, TechTypes::Plague)) {
					auto c = best_cluster(g, at, 320, 64, [&](unit_t* e) { return !f.ut_worker(e); });
					if (c.first && c.second >= p.cfg.spells.plague && own_value_near(f, p, c.first->sprite->position, 64) * 3 < c.second) {
						if (cast(f, p, u, TechTypes::Plague, c.first->sprite->position, nullptr)) break;
					}
				}
				if (can_cast(f, p, u, TechTypes::Dark_Swarm)) {
					// Over our ground army where it fights.
					for (unit_t* a : s.army) {
						if (f.u_flying(a) || dist2(a->sprite->position, at) > 320 * 320) continue;
						if (!enemy_near(a->sprite->position, 224, false)) continue;
						if (own_value_near(f, p, a->sprite->position, 96) < p.cfg.spells.swarm) continue;
						if (cast(f, p, u, TechTypes::Dark_Swarm, a->sprite->position, nullptr)) break;
					}
				}
				break;
			}
			case UnitTypes::Zerg_Queen: {
				if (can_cast(f, p, u, TechTypes::Spawn_Broodlings)) {
					unit_t* best = nullptr;
					g.near(at, 288, [&](unit_t* e) {
						if (f.u_flying(e) || f.ut_building(e) || f.ut_robotic(e) || f.ut_worker(e)) return;
						if (value_of(e) >= p.cfg.spells.broodlings && (!best || value_of(e) > value_of(best))) best = e;
					});
					if (best && cast(f, p, u, TechTypes::Spawn_Broodlings, best->sprite->position, best)) break;
				}
				if (can_cast(f, p, u, TechTypes::Ensnare)) {
					auto c = best_cluster(g, at, 288, 64, [&](unit_t* e) { return !f.ut_building(e) && !f.ut_worker(e); });
					if (c.first && c.second >= p.cfg.spells.ensnare) cast(f, p, u, TechTypes::Ensnare, c.first->sprite->position, nullptr);
				}
				break;
			}
			case UnitTypes::Zerg_Lurker:
				if (!f.u_burrowed(u)) {
					if (enemy_near(at, 224, true) || (!p.attacking && is_idle(u) && dist2(at, p.rally) < 256 * 256)) {
						if (select(f, p, u) && f.action_burrow(p.owner, false)) {
							mark_cast(u, frame + 24 * 2);
							ai_log(f, p, "burrow", 0);
						}
					}
				} else if (!enemy_near(at, 320, true) && (p.attacking || dist2(at, p.rally) > 320 * 320)) {
					if (select(f, p, u) && f.action_unburrow(p.owner)) mark_cast(u, frame + 24 * 2);
				}
				break;
			default:
				break;
			}
		}
		(void)attacking;

		// Comsats scan cloaked attackers no detector of ours sees.
		if (p.race == race_t::terran && p.enemy_cloaked > 0 && frame >= p.next_scan) {
			p.next_scan = frame + 24 * 3;
			for (unit_t* c : s.buildings) {
				if (!f.unit_is(c, UnitTypes::Terran_Comsat_Station) || !can_cast(f, p, c, TechTypes::Scanner_Sweep)) continue;
				unit_t* hidden = nullptr;
				for (unit_t* a : s.army) {
					g.near(a->sprite->position, 288, [&](unit_t* e) {
						if (!hidden && (f.u_cloaked(e) || f.u_burrowed(e)) && f.unit_can_attack(e)) hidden = e;
					});
					if (hidden) break;
				}
				if (hidden && cast(f, p, c, TechTypes::Scanner_Sweep, hidden->sprite->position, nullptr)) p.next_scan = frame + 24 * 8;
				break;
			}
		}
	}

	// --- expanding, also to other islands ---------------------------------------

	bool site_taken(action_functions& f, xy site) {
		for (int owner = 0; owner != 8; ++owner) {
			for (unit_t* b : ptr(f.st.player_units.at(owner))) {
				if (!f.unit_dead(b) && f.ut_building(b) && dist2(site, b->sprite->position) < 448 * 448) return true;
			}
		}
		return false;
	}

	void maybe_expand2(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		int frame = f.st.current_frame;
		auto& c = p.cfg.expansion;
		int wanted_bases = 1;
		for (int t : c.base_times) wanted_bases += frame > t ? 1 : 0;
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
		if (p.human && p.modes != mode_all && frame > c.colonize_after) {
			// Colonizing picked for a human: a new base when the current ones
			// are well worked, money piles up, or every couple of minutes
			// (zerg drones turn into colonies, so workers stay few).
			bool saturated = (int)s.workers.size() >= std::max(1, owned_sites) * c.colonize_workers_per_base;
			bool due = frame >= p.next_base;
			for (unit_t* d : s.depots) {
				colony_count cc = count_colony(f, p, s, d);
				if (cc.ground + cc.air + cc.tanks < c.colonize_dig_in) due = false; // dig in first
			}
			wanted_bases = std::min(c.colonize_max_bases, owned_sites + (saturated || due || s.minerals >= c.colonize_minerals ? 1 : 0));
		}
		if (owned_sites >= wanted_bases) return;
		for (unit_t* w : s.workers) {
			if (building_order(w->order_type->id) && !w->build_queue.empty() && w->build_queue.front() == ut) return;
		}
		for (auto& d : p.drops) {
			if (d.expand) return; // a worker is on its way
		}
		if (!affordable(ut, minerals, gas)) {
			minerals -= ut->mineral_cost;
			return;
		}
		// The nearest free site; ones a worker can walk to first.
		xy target;
		bool found = false, walk = false;
		int best = 0;
		for (xy site : sites) {
			if (site_taken(f, site)) continue;
			bool reach = f.is_reachable(p.home, site);
			int d = dist2(site, p.home) + (reach ? 0 : 1 << 28);
			if (!found || d < best) {
				target = site;
				best = d;
				found = true;
				walk = reach;
			}
		}
		if (!found) return;
		// The builder: a ferried worker already there, or one that can walk.
		unit_t* builder = nullptr;
		if (unit_t* e = p.expander ? resolve(f, p.expander) : nullptr) {
			if (f.ut_worker(e) && f.is_reachable(e->sprite->position, target)) builder = e;
		}
		if (!builder) {
			p.expander = 0;
			int bd = 0;
			for (unit_t* w : s.workers) {
				auto id = w->order_type->id;
				if (building_order(id) || is_gas_order(id) || id == Orders::ConstructingBuilding) continue;
				if (!f.is_reachable(w->sprite->position, target)) continue;
				int d = dist2(w->sprite->position, target);
				if (!builder || d < bd) {
					builder = w;
					bd = d;
				}
			}
		}
		if (!builder) {
			// Across the water: a transport takes a worker there.
			(void)walk;
			auto transports = free_transports(f, p, s);
			if (transports.empty()) return;
			unit_t* t = transports.front();
			unit_t* w = pick_builder(f, s, t->sprite->position);
			if (!w) return;
			player::drop d;
			d.transport = f.get_unit_id(t).raw_value;
			d.passengers.push_back(f.get_unit_id(w).raw_value);
			d.target = target;
			d.landing = target;
			for (int r : {0, 64, 128, 192}) {
				xy at = f.restrict_pos_to_map_bounds(target + (p.home - target) * r / std::max(1, f.xy_length(p.home - target)));
				if (f.is_walkable(at)) {
					d.landing = at;
					break;
				}
			}
			d.started = frame;
			d.last_order = -10000;
			d.expand = true;
			p.drops.push_back(d);
			ai_log(f, p, "expand-drop", 0);
			return;
		}
		if (!f.player_position_is_explored(p.owner, target)) {
			if (frame - p.expand_worker_frame > 24 * 30 && select(f, p, builder)) {
				f.action_order(p.owner, f.get_order_type(Orders::Move), target, nullptr, nullptr, false);
				p.expand_worker_frame = frame;
			}
			return;
		}
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
		if (f.action_build(p.owner, build_order_for(f, builder), ut, tile)) {
			minerals -= ut->mineral_cost;
			p.expander = 0;
			p.next_base = frame + c.next_base_delay;
		}
	}

	// Minerals piling up (gas is what runs short): more production for units
	// that cost none, a hatchery for more larvae.
	void spend_surplus(action_functions& f, player& p, snapshot& s, int& minerals, int& gas) {
		auto& c = p.cfg.economy;
		if (minerals < c.surplus_minerals || s.workers.empty()) return;
		UnitTypes extra = p.race == race_t::terran ? UnitTypes::Terran_Barracks
		                  : p.race == race_t::protoss ? UnitTypes::Protoss_Gateway
		                                              : UnitTypes::Zerg_Hatchery;
		// A big surplus also digs in: defences at every base.
		if (minerals >= c.surplus_fortify) fortify(f, p, s, minerals, gas);
		// On an island more barracks or gateways only make walkers that
		// wait at home (and take the room depots need).
		if (p.island && p.race != race_t::zerg) return;
		if (s.planned[(size_t)extra] >= c.max_extra_production) return;
		if (s.planned[(size_t)extra] > s.done[(size_t)extra]) return; // one at a time
		const unit_type_t* ut = f.get_unit_type(extra);
		if (!f.unit_can_build(s.workers.front(), ut)) return;
		if (place(f, p, s, extra)) {
			minerals -= ut->mineral_cost;
			gas -= ut->gas_cost;
		} else if (p.race == race_t::protoss && s.planned[(size_t)UnitTypes::Protoss_Pylon] < c.max_pylons &&
		           s.planned[(size_t)UnitTypes::Protoss_Pylon] == s.done[(size_t)UnitTypes::Protoss_Pylon]) {
			// No powered room left: another pylon makes some.
			if (place(f, p, s, UnitTypes::Protoss_Pylon)) minerals -= 100;
		}
	}

	// --- bot profiles: tables and scripts (botscript.h) --------------------------

	static const ai_tables& default_tables() {
		static const ai_tables t;
		return t;
	}

	// A table of the profile's variant in use, else of its unnamed variant,
	// else the standard one.
	template<typename H, typename T>
	const T& table_of(const player& p, int variant, H has, T ai_tables::*field) const {
		size_t r = (size_t)p.race;
		if (auto* pr = profile_of(p)) {
			for (int v : {variant, 0}) {
				if (v < 0 || (size_t)v >= pr->tables.size()) continue;
				auto& t = pr->tables[(size_t)v];
				if ((t.*has)[r]) return (t.t.*field);
			}
		}
		return default_tables().*field;
	}
	const a_vector<plan_step>& plan_of(const player& p) const {
		return table_of(p, p.plan_variant, &botscript::profile::variant_tables::plan, &ai_tables::plan)[(size_t)p.race];
	}
	const a_vector<research2_step>& research_of(const player& p) const {
		return table_of(p, p.research_variant, &botscript::profile::variant_tables::research, &ai_tables::research)[(size_t)p.race];
	}
	const a_vector<mix_row>& mix_of(const player& p) const {
		if (p.island) return table_of(p, p.mix_variant, &botscript::profile::variant_tables::mix_island, &ai_tables::mix_island)[(size_t)p.race];
		return table_of(p, p.mix_variant, &botscript::profile::variant_tables::mix_ground, &ai_tables::mix_ground)[(size_t)p.race];
	}

	// What a script sees and does, for one player. `f` is null at the start
	// of the game (the profile's set statements), when only a few facts mean
	// anything.
	struct script_host : botscript::host {
		ai_system& ai;
		action_functions* f;
		player& p;
		snapshot* s;
		snapshot own;
		bool have_snapshot = false;
		assessment a;
		bool have_assessment = false;

		script_host(ai_system& ai, action_functions* f, player& p, snapshot* s) : ai(ai), f(f), p(p), s(s) {}

		int32_t* globals() override { return p.vars.data(); }
		ai_tunables& tunables() override { return p.cfg; }
		void warn(const char* message) override {
			auto* pr = ai.profile_of(p);
			std::string text = std::string("bot profile ") + (pr ? pr->name : "?") + ", player " + std::to_string(p.owner) + ": " + message;
			if (FILE* out = log_file()) std::fprintf(out, "ai %d script %s\n", p.owner, text.c_str());
			static int shown = 0;
			if (shown < 20) {
				++shown;
				std::fprintf(stderr, "%s\n", text.c_str());
			}
		}

		snapshot& snap() {
			if (s) return *s;
			if (!have_snapshot) {
				own = ai.take_snapshot(*f, p);
				have_snapshot = true;
			}
			return own;
		}
		const assessment* assessed() {
			if (!f || !ai.allies) return nullptr;
			if (!have_assessment) {
				a = ai.assess(*f, p);
				have_assessment = true;
			}
			return &a;
		}
		static bool valid(int32_t q) { return q >= 0 && q < 8; }

		int32_t builtin(int id, const int32_t* x, int n) override {
			(void)n;
			using namespace botscript;
			// Facts that need no game (also at the start).
			switch (id) {
			case b_me: return p.owner;
			case b_race: return (int)p.race;
			case b_trust: return p.trust;
			case b_random: {
				int64_t lo = std::min(x[0], x[1]), hi = std::max(x[0], x[1]);
				uint32_t span = (uint32_t)(hi - lo + 1);
				uint32_t r = (p.next() << 15) | p.next();
				return span == 0 ? (int32_t)r : (int32_t)(lo + (int64_t)(r % span));
			}
			case b_min: return std::min(x[0], x[1]);
			case b_max: return std::max(x[0], x[1]);
			case b_abs: return x[0] < 0 ? botscript::wrap(-(int64_t)x[0]) : x[0];
			case b_clamp: return std::max(x[1], std::min(x[2], x[0]));
			case b_use_plan: p.plan_variant = x[0]; return 0;
			case b_use_research: p.research_variant = x[0]; return 0;
			case b_use_mix: p.mix_variant = x[0]; return 0;
			case b_print:
				if (FILE* out = log_file()) std::fprintf(out, "ai %d f%d print %d\n", p.owner, f ? f->st.current_frame : 0, x[0]);
				return 0;
			default: break;
			}
			if (!f) return 0;
			state& st = f->st;
			auto* al = ai.allies;
			switch (id) {
			case b_time: return st.current_frame / 24;
			case b_frame: return st.current_frame;
			case b_minerals: return st.current_minerals[p.owner];
			case b_gas: return st.current_gas[p.owner];
			case b_supply: return snap().supply_used;
			case b_supply_max: return snap().supply_max;
			case b_workers: return (int32_t)snap().workers.size();
			case b_bases: return (int32_t)snap().depots.size();
			case b_army: return (int32_t)snap().army.size();
			case b_army_value: {
				int v = 0;
				for (unit_t* u : snap().army) v += value_of(u);
				return v;
			}
			case b_wave_size: return p.wave_size;
			case b_attacking: return p.attacking;
			case b_losing: return p.losing;
			case b_attacker: return p.attacker;
			case b_island: return p.island;
			case b_some_island: return p.some_island;
			case b_enemy_air: return p.enemy_air;
			case b_enemy_cloaked: return p.enemy_cloaked;
			case b_defensive: return p.fortifying;
			case b_count: return x[0] >= 0 && x[0] < (int32_t)UnitTypes::None ? ai.army_count(snap(), (UnitTypes)x[0]) : 0;
			case b_done: return x[0] >= 0 && x[0] < (int32_t)UnitTypes::None ? snap().done[(size_t)x[0]] : 0;
			case b_researched: return x[0] >= 0 && x[0] < (int32_t)TechTypes::None && f->player_has_researched(p.owner, (TechTypes)x[0]);
			case b_upgrade_level: return x[0] >= 0 && x[0] < (int32_t)UpgradeTypes::None ? f->player_upgrade_level(p.owner, (UpgradeTypes)x[0]) : 0;
			case b_alive:
				if (!valid(x[0])) return 0;
				return al ? al->active(st, x[0]) : st.players[(size_t)x[0]].controller == player_t::controller_occupied && st.players[(size_t)x[0]].victory_state == 0;
			case b_human: return valid(x[0]) && al && al->human[(size_t)x[0]];
			case b_ally:
				if (!valid(x[0]) || x[0] == p.owner) return 0;
				return al ? al->same_group(x[0], p.owner) : st.alliances[p.owner][(size_t)x[0]] == 2;
			case b_enemy: return valid(x[0]) && ai.is_enemy(*f, p.owner, x[0]);
			case b_race_of: return valid(x[0]) ? (int)st.players[(size_t)x[0]].race : -1;
			case b_army_of: return valid(x[0]) && assessed() ? assessed()->army[(size_t)x[0]] : 0;
			case b_economy_of: return valid(x[0]) && assessed() ? assessed()->economy[(size_t)x[0]] : 0;
			case b_strength: return valid(x[0]) && assessed() ? ai.strength(*assessed(), al->members(al->group[(size_t)x[0]])) : 0;
			case b_utility:
				if (!valid(x[0]) || !assessed() || x[0] == p.owner || al->same_group(x[0], p.owner)) return 0;
				return ai.alliance_utility(*f, p, *assessed(), al->members(al->group[(size_t)x[0]]));
			case b_distance:
				if (!valid(x[0]) || !assessed()) return 0;
				return f->xy_length(assessed()->base[(size_t)x[0]] - assessed()->base[(size_t)p.owner]);
			case b_mining: return valid(x[0]) && al ? al->mineral_rate[(size_t)x[0]] + al->gas_rate[(size_t)x[0]] : 0;
			case b_lost_to: return valid(x[0]) ? p.pressure[(size_t)x[0]] : 0;
			case b_group_size: return valid(x[0]) && al ? (int32_t)al->members(al->group[(size_t)x[0]]).size() : 0;
			case b_vassal: return valid(x[0]) && al && al->vassal(x[0]);
			case b_lord: return valid(x[0]) && al ? al->lord[(size_t)x[0]] : -1;
			// Actions.
			case b_attack:
				if (!p.attacking && !snap().army.empty()) {
					p.attacking = true;
					p.last_attack_order = -10000;
				}
				return 0;
			case b_retreat: p.attacking = false; return 0;
			case b_set_wave: p.wave_size = std::max(1, x[0]); return 0;
			case b_focus: p.focus = valid(x[0]) && x[0] != p.owner ? x[0] : -1; return 0;
			default: break;
			}
			// Diplomacy: computer players only (auto-play doesn't negotiate).
			if (!al || p.human || !al->active(st, p.owner) || al->vassal(p.owner)) return 0;
			switch (id) {
			case b_invite:
				if (valid(x[0]) && x[0] != p.owner && al->merge_allowed(st, p.owner, x[0]) && al->invite(st, p.owner, x[0])) {
					p.asked_at[(size_t)x[0]] = st.current_frame + 1;
					return 1;
				}
				return 0;
			case b_leave: return al->leave(st, p.owner);
			case b_surrender_to:
				return valid(x[0]) && al->surrender_allowed(st, p.owner, x[0]) && al->surrender_frame[(size_t)x[0]][(size_t)p.owner] < 0 &&
				       al->offer_surrender(st, p.owner, x[0]);
			case b_set_open: al->set_open(st, p.owner, x[0] != 0); return 0;
			default: return 0;
			}
		}
	};

	// Runs a profile's function for player p (nothing without a profile).
	botscript::result run_script(action_functions* f, player& p, snapshot* s, int fn, const int32_t* args, int argc) {
		auto* pr = profile_of(p);
		if (!pr || fn < 0) return {};
		script_host h(*this, f, p, s);
		return botscript::run(*pr, fn, args, argc, h);
	}

	// Fires an event; the result has a value when the script decided.
	botscript::result fire(action_functions& f, player& p, snapshot* s, botscript::handler_id id, std::initializer_list<int32_t> args = {}) {
		auto* pr = profile_of(p);
		if (!pr || !pr->has(id)) return {};
		a_vector<int32_t> a(args);
		return run_script(&f, p, s, pr->handler[(size_t)id], a.data(), (int)a.size());
	}

	// --- version 2's turn ----------------------------------------------------------

	void think2(action_functions& f, player& p) {
		snapshot s = take_snapshot(f, p);
		if (s.depots.empty() && s.workers.empty() && s.army.empty()) return;
		if (!s.depots.empty() && p.rally == p.home) p.rally = rally_point(f, p);
		update_intel(f, p);
		fire(f, p, &s, botscript::h_think);

		bool resources = p.modes & mode_resources, building = p.modes & mode_building;
		bool attacking = p.modes & mode_attacking, colonizing = p.modes & mode_colonizing;
		bool fortifying = !p.human && allies && allies->defensive_for(p.owner);
		if (fortifying) attacking = false;
		if (!fortifying && p.fortifying) {
			p.detached.clear();
			p.guard_ally = -1;
		}
		p.fortifying = fortifying;
		unit_t* intruder = p.human ? find_intruder(f, p, s) : nullptr;
		if (intruder || (p.human && find_intruder(f, p, s, p.cfg.defense.warning_range))) p.threat_until = f.st.current_frame + p.cfg.defense.threat_hold;
		bool threatened = f.st.current_frame < p.threat_until;
		if (resources || f.st.current_frame < p.militia_until + 24 * 30) manage_workers(f, p, s);
		if (resources) balance_workers(f, p, s);

		int minerals = s.minerals - s.reserved_minerals, gas = s.gas - s.reserved_gas;
		if (allies && !p.human) {
			auto mates = allies->pool(p.owner);
			int computers = 0;
			for (int m : mates) {
				for (auto& o : players) {
					if (o.owner == m && !o.human) ++computers;
				}
			}
			if (computers < (int)mates.size()) {
				minerals = minerals * computers / (int)mates.size();
				gas = gas * computers / (int)mates.size();
			}
		}

		bool supply_ordered = keep_supply(f, p, s, minerals, gas);
		if (resources || colonizing) train_workers(f, p, s, minerals, gas);
		p.colony_mode = colonizing && !attacking;
		if (colonizing && !p.colony_mode) build_defenses(f, p, s, minerals, gas);
		if (p.colony_mode) {
			// Auto-play never trains fighting units without the attacking
			// mode: the colonies get buildings only.
			if (!p.human) colony_units(f, p, s, minerals, gas);
			maybe_expand2(f, p, s, minerals, gas);
			colony_defense(f, p, s, minerals, gas);
		}
		// Allies guarding (defensive mode) keep an army before the tech.
		if (fortifying && (int)s.army.size() < p.cfg.army.defensive_army) train_army2(f, p, s, minerals, gas);
		if (!p.human || building) air_defense(f, p, s, minerals, gas);
		if (building && !supply_ordered) follow_plan(f, p, s, minerals, gas);
		if (building) manage_addons(f, p, s, minerals, gas);
		if (colonizing && !p.colony_mode) maybe_expand2(f, p, s, minerals, gas);
		if (building) research2(f, p, s, minerals, gas);
		if (building && (!p.human || attacking)) spend_surplus(f, p, s, minerals, gas);
		if (fortifying) fortify(f, p, s, minerals, gas);
		if (attacking || fortifying) {
			arm_silos(f, p, s, minerals, gas);
			morph_units(f, p, s, minerals, gas);
			train_army2(f, p, s, minerals, gas);
		}
		if (attacking || threatened || !s.army.empty()) command_army2(f, p, s, attacking);
		if (!p.human || attacking) use_abilities(f, p, s, attacking);
	}

};

} // namespace bw_ai

#endif // BW_AI_H
