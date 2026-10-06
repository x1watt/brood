// engine/bridge/src/bw_ai_params.h
//
// The computer player's tunables: every number that shapes how it plays
// (build plan, research, army mix, attack waves, defences, expansions,
// drops, spells, diplomacy) gathered in one plain struct, so a bot profile
// can change them without touching bw_ai.h. The defaults are the standard
// player's (version 2). Version 1's own build order, waves and expansions
// stay in bw_ai.h as they were, for the saved games made with it.
//
// Only behaviour lives here. Geometry that makes placement and pathing work
// (building clearance, search rings, resource cluster radius) stays in code.
// Times are in frames (24 per second); values are mineral + gas cost unless
// a comment says otherwise. Everything is an integer: the computer players
// must decide the same on every machine.

#ifndef BW_AI_PARAMS_H
#define BW_AI_PARAMS_H

#include "bwgame.h"

#include <array>
#include <cstddef>

namespace bw_ai {

using namespace bwgame;

// Where a plan row applies.
enum where_t : int {
	where_any = 0,    // every map
	where_ground = 1, // enemy bases can be reached on the ground
	where_island = 2, // they can't
};

struct plan_step {
	UnitTypes type;
	int count;  // wanted total (including ones in progress)
	int supply; // start once this much supply is in use
	int where;
};

struct research2_step {
	UnitTypes building;
	bool is_tech;
	int id; // TechTypes or UpgradeTypes
	int supply;
	int where;
};

// One unit type of the army's mix. Its share is `share`, or `late` in the
// late game, or `cloak` while enemies field cloaked units (-1: unchanged),
// plus aa * aa_mul / aa_div, where aa grows with the enemies' air force.
struct mix_row {
	UnitTypes type;
	int share;
	int cap; // at most this many (0: no cap)
	int aa_mul = 0, aa_div = 1;
	int late = -1;
	int cloak = -1;
	bool some_island = false; // only while some enemy base can't be walked to
};

// The numbers: plain data, kept per player (a profile's script may change
// them during the game, so saved games copy them with the player).
struct ai_tunables {
	struct personality_t {
		int trust_min = 0, trust_span = 100; // trust is trust_min + random(trust_span)
	} personality;

	struct economy_t {
		int workers_per_base = 16;
		int workers_per_refinery = 3;
		int max_workers = 60;
		int miners_per_patch = 2;    // spread across bases above this
		int balance_interval = 24 * 10;
		int zerg_drones_first = 12;  // drones before the army competes for larvae
		int zerg_drone_lead = 10;    // then drones may lead army * 2 by this much
		int supply_margin = 2;       // free supply kept ahead of use...
		int supply_margin_per_producer = 3; // ...plus this per production building
		int supply_double_margin = 12; // two supply buildings at once above this margin
		int gas_everywhere_after = 24 * 60 * 6; // a refinery at every base
		int surplus_minerals = 900;  // more production buildings from here
		int surplus_fortify = 1500;  // and defences at every base
		int max_extra_production = 8;
		int max_pylons = 40;
	} economy;

	struct expansion_t {
		// Bases wanted from these times on (one more each).
		std::array<int, 4> base_times{{24 * 60 * 6, 24 * 60 * 12, 24 * 60 * 18, 24 * 60 * 26}};
		// Auto-play colonizing for a human: a new base when the bases have
		// this many workers each, money piles up, or after next_base_delay.
		int colonize_after = 24 * 60 * 3;
		int colonize_workers_per_base = 14;
		int colonize_minerals = 500;
		int colonize_max_bases = 6;
		int colonize_dig_in = 4; // defences a colony has before the next one
		int next_base_delay = 24 * 150;
	} expansion;

	struct army_t {
		int wave_first = 8;   // units in the first attack wave
		int wave_grow = 4;    // added after each wave
		int wave_max = 48;
		int wave_end_div = 4; // a wave ends below wave_size / this...
		int wave_end_min = 2; // ...or this many units
		int attack_refresh = 24 * 20; // orders the whole wave again
		int rally_distance = 288;     // from the main base toward the map center
		int defensive_army = 8;       // allies guarding keep this many before the tech
		int min_minerals = 25;        // no unit training below this
		int late_game = 24 * 60 * 14; // mix rows switch to `late`
		int aa_per = 200, aa_max = 24; // aa = min(aa_max, enemy air / aa_per)
		int starved_gas = 75, starved_minerals = 400; // short of gas, minerals piling up:
		int starved_factor = 3;       // units without gas count this much more
		int morph_min = 2;            // lurkers etc. without a cap: half the source, at least this
		int archon_energy = 50;       // high templar below this merge
	} army;

	struct defense_t {
		int intruder_range = 512;  // an enemy this close to a building is an attack
		int warning_range = 1100;  // an armed force this close warns auto-play
		int threat_hold = 24 * 90;
		int militia_all = 12;      // workers that fight with no army...
		int militia_some = 6;      // ...or with too small a one
		int militia_time = 24 * 20;
		int expansion_defenses = 2; // when colonizing with attacking on
		int fortify_main_ground = 4, fortify_main_air = 3; // defensive mode
		int fortify_ground = 2, fortify_air = 2;
		int fortify = 0; // 1: fortify every base as in defensive mode (a strategy's choice)
		int colony_ground = 8, colony_air = 3; // colonizing without attacking
		int colony_rich = 400;     // minerals that double colony_ground
		int colony_mobile = 6;     // mobile units guarding colonies (not Terran)
		int colony_tanks = 3;      // siege tanks per Terran colony
		int marines_per_bunker = 4, colony_marines = 4;
		int air_trigger = 300;     // enemy air value that calls for anti-air
		int air_island_after = 24 * 60 * 4;
		int air_per = 500, air_max = 6, air_island_min = 2; // anti-air per base
		int max_comsats = 2;
		int silos = 1, silos_late = 2, silos_late_after = 24 * 60 * 30;
	} defense;

	struct help_t { // defensive mode: helping allies under attack
		int range = 448;      // an armed enemy this close to an ally's building
		int fresh = 24 * 4;   // how long a sighting counts
		int whole_army = 6;   // armies up to this size go whole, bigger ones half
		int refresh = 24 * 3;
		int guard_radius = 224;
	} help;

	struct drops_t {
		int max = 4;
		int min_space = 4;          // a transport goes with at least this much aboard
		int load_time = 24 * 30;    // leaves with what is aboard after this
		int give_up = 24 * 40;      // nobody boarded
		int overlords = 3;          // overlords used as transports
	} drops;

	struct spells_t { // the least value a spell must hit (or protect)
		int lockdown = 200;
		int nuke_interval = 24 * 50;
		int yamato = 200, yamato_defense_bonus = 200;
		int irradiate = 200;
		int emp = 500;
		int matrix = 150;
		int storm = 350;
		int stasis = 700;
		int web = 400;
		int plague = 600;
		int swarm = 300; // our own army under the swarm
		int broodlings = 150;
		int ensnare = 400;
	} spells;

	struct diplomacy_t {
		int open_trust = 30;       // at least this trusting: open to invitations
		int closed_trust = 60;     // dominant and below this: keep to yourself
		int first_invite = 24 * 60 * 3, first_invite_spread = 24 * 60;
		int open_check = 24 * 60;
		// Utility of an alliance with a group (alliance_utility).
		int trust_center = 50, trust_div = 2;
		int closeness_div = 4;
		int peace = 55;            // with whoever is beating us at home
		int helper = 40;           // a group strong enough to help us
		int dominant_pct = 160, dominant = 35; // we are this much stronger than anyone: need no one
		int dead_weight_ratio = 3, dead_weight = 15;
		int beating_value = 400, beating = 20; // winning a fight against them
		int common_enemy_pct = 130, common_enemy = 25;
		int mining_max = 25, mining_scale = 20;
		int strong_ally = 10;      // they are more than twice as strong
		// Losing at home: invaders' value, how much stronger than the
		// defenders (percent), recent losses.
		int losing_threat = 300, losing_pct = 130, losing_losses = 150;
		int outmatched_pct = 130;  // someone this much stronger: look for friends
		int accept_open = 35, accept_closed = 55, accept_noise = 20;
		// Surrenders offered to us: tribute vs the score for conquest.
		int tribute_rate = 5, tribute_army_div = 2, tribute_trust = 20, conquest_pct = 60;
		// Offering to surrender.
		int refused_window = 24 * 120, hopeless_after = 24 * 75, surrender_retry = 24 * 60;
		// Turning on a weaker ally once no meaningful enemy is left.
		int betray_after = 24 * 60 * 8, betray_check = 24 * 60;
		int betray_edge = 140;     // percent stronger, plus trust
		int betray_outside = 4;    // everyone outside times this is weaker than us
		// Invitations.
		int invite_losing = 24 * 15, invite_interval = 24 * 45, invite_spread = 45; // seconds
		int no_pester = 24 * 60;
		int invite_utility = 40;
	} diplomacy;
};

// The tables, indexed by race_t (zerg, terran, protoss): shared by every
// player of a profile.
struct ai_tables {
	std::array<a_vector<plan_step>, 3> plan;
	std::array<a_vector<research2_step>, 3> research;
	std::array<a_vector<mix_row>, 3> mix_ground, mix_island;

	ai_tables() {
		plan = {zerg_plan(), terran_plan(), protoss_plan()};
		research = {zerg_research(), terran_research(), protoss_research()};
		mix_ground = {zerg_ground(), terran_ground(), protoss_ground()};
		mix_island = {zerg_island(), terran_island(), protoss_island()};
	}

private:
	static a_vector<plan_step> terran_plan() {
		using U = UnitTypes;
		return {
			{U::Terran_Barracks, 1, 10, 0},
			{U::Terran_Refinery, 1, 12, 0},
			{U::Terran_Factory, 1, 14, 2},
			{U::Terran_Starport, 1, 17, 2},
			{U::Terran_Barracks, 2, 15, 1},
			{U::Terran_Academy, 1, 18, 1},
			{U::Terran_Engineering_Bay, 1, 20, 2},
			{U::Terran_Factory, 1, 22, 1},
			{U::Terran_Starport, 2, 26, 2},
			{U::Terran_Engineering_Bay, 1, 26, 1},
			{U::Terran_Barracks, 3, 30, 1},
			{U::Terran_Armory, 1, 32, 2},
			{U::Terran_Refinery, 2, 34, 0},
			{U::Terran_Starport, 1, 38, 1},
			{U::Terran_Science_Facility, 1, 40, 2},
			{U::Terran_Armory, 1, 44, 1},
			{U::Terran_Academy, 1, 44, 2},
			{U::Terran_Factory, 2, 48, 1},
			{U::Terran_Starport, 3, 50, 2},
			{U::Terran_Science_Facility, 1, 56, 1},
			{U::Terran_Barracks, 4, 64, 1},
			{U::Terran_Starport, 4, 70, 2},
			{U::Terran_Starport, 2, 80, 1},
			{U::Terran_Science_Facility, 2, 84, 0},
			{U::Terran_Factory, 3, 90, 1},
			{U::Terran_Barracks, 5, 110, 1},
			{U::Terran_Starport, 5, 120, 2},
		};
	}
	static a_vector<plan_step> protoss_plan() {
		using U = UnitTypes;
		return {
			{U::Protoss_Gateway, 1, 10, 0},
			{U::Protoss_Assimilator, 1, 12, 0},
			{U::Protoss_Cybernetics_Core, 1, 14, 0},
			{U::Protoss_Stargate, 1, 18, 2},
			{U::Protoss_Gateway, 2, 16, 1},
			{U::Protoss_Forge, 1, 20, 2},
			{U::Protoss_Robotics_Facility, 1, 22, 1},
			{U::Protoss_Forge, 1, 26, 1},
			{U::Protoss_Stargate, 2, 26, 2},
			{U::Protoss_Gateway, 3, 28, 1},
			{U::Protoss_Assimilator, 2, 32, 0},
			{U::Protoss_Fleet_Beacon, 1, 34, 2},
			{U::Protoss_Citadel_of_Adun, 1, 34, 1},
			{U::Protoss_Robotics_Support_Bay, 1, 38, 1},
			{U::Protoss_Robotics_Facility, 1, 40, 2},
			{U::Protoss_Observatory, 1, 42, 0},
			{U::Protoss_Templar_Archives, 1, 46, 1},
			{U::Protoss_Stargate, 3, 50, 2},
			{U::Protoss_Gateway, 4, 50, 1},
			{U::Protoss_Citadel_of_Adun, 1, 56, 2},
			{U::Protoss_Stargate, 1, 60, 1},
			{U::Protoss_Templar_Archives, 1, 60, 2},
			{U::Protoss_Gateway, 5, 66, 1},
			{U::Protoss_Arbiter_Tribunal, 1, 70, 2},
			{U::Protoss_Fleet_Beacon, 1, 76, 1},
			{U::Protoss_Stargate, 4, 80, 2},
			{U::Protoss_Arbiter_Tribunal, 1, 90, 1},
			{U::Protoss_Stargate, 2, 100, 1},
			{U::Protoss_Gateway, 6, 110, 1},
		};
	}
	static a_vector<plan_step> zerg_plan() {
		using U = UnitTypes;
		return {
			{U::Zerg_Spawning_Pool, 1, 9, 0},
			{U::Zerg_Extractor, 1, 11, 0},
			{U::Zerg_Hatchery, 2, 13, 1},
			{U::Zerg_Lair, 1, 14, 2},
			{U::Zerg_Hydralisk_Den, 1, 18, 1},
			{U::Zerg_Spire, 1, 20, 2},
			{U::Zerg_Evolution_Chamber, 1, 22, 0},
			{U::Zerg_Hatchery, 2, 24, 2},
			{U::Zerg_Lair, 1, 28, 1},
			{U::Zerg_Hydralisk_Den, 1, 30, 2},
			{U::Zerg_Extractor, 2, 32, 0},
			{U::Zerg_Spire, 1, 34, 1},
			{U::Zerg_Queens_Nest, 1, 36, 0},
			{U::Zerg_Hatchery, 3, 40, 1},
			{U::Zerg_Hive, 1, 44, 2},
			{U::Zerg_Evolution_Chamber, 2, 50, 1},
			{U::Zerg_Greater_Spire, 1, 50, 2},
			{U::Zerg_Hive, 1, 56, 1},
			{U::Zerg_Hatchery, 3, 60, 2},
			{U::Zerg_Defiler_Mound, 1, 64, 1},
			{U::Zerg_Ultralisk_Cavern, 1, 70, 1},
			{U::Zerg_Defiler_Mound, 1, 70, 2},
			{U::Zerg_Greater_Spire, 1, 80, 1},
			{U::Zerg_Hatchery, 4, 90, 0},
		};
	}

	static a_vector<research2_step> terran_research() {
		using U = UnitTypes;
		using T = TechTypes;
		using G = UpgradeTypes;
		return {
			{U::Terran_Academy, true, (int)T::Stim_Packs, 20, 1},
			{U::Terran_Machine_Shop, true, (int)T::Tank_Siege_Mode, 24, 0},
			{U::Terran_Academy, false, (int)G::U_238_Shells, 26, 1},
			{U::Terran_Control_Tower, true, (int)T::Cloaking_Field, 30, 2},
			{U::Terran_Machine_Shop, true, (int)T::Spider_Mines, 30, 1},
			{U::Terran_Engineering_Bay, false, (int)G::Terran_Infantry_Weapons, 34, 1},
			{U::Terran_Armory, false, (int)G::Terran_Ship_Weapons, 36, 2},
			{U::Terran_Armory, false, (int)G::Terran_Vehicle_Weapons, 50, 1},
			{U::Terran_Physics_Lab, true, (int)T::Yamato_Gun, 50, 0},
			{U::Terran_Science_Facility, true, (int)T::Irradiate, 56, 0},
			{U::Terran_Armory, false, (int)G::Terran_Ship_Plating, 56, 2},
			{U::Terran_Engineering_Bay, false, (int)G::Terran_Infantry_Armor, 60, 1},
			{U::Terran_Machine_Shop, false, (int)G::Charon_Boosters, 64, 0},
			{U::Terran_Covert_Ops, true, (int)T::Personnel_Cloaking, 70, 0},
			{U::Terran_Covert_Ops, true, (int)T::Lockdown, 76, 0},
			{U::Terran_Science_Facility, true, (int)T::EMP_Shockwave, 80, 0},
			{U::Terran_Armory, false, (int)G::Terran_Vehicle_Plating, 90, 1},
			{U::Terran_Control_Tower, true, (int)T::Cloaking_Field, 90, 1},
			{U::Terran_Armory, false, (int)G::Terran_Ship_Weapons, 100, 1},
		};
	}
	static a_vector<research2_step> protoss_research() {
		using U = UnitTypes;
		using T = TechTypes;
		using G = UpgradeTypes;
		return {
			{U::Protoss_Cybernetics_Core, false, (int)G::Singularity_Charge, 20, 1},
			{U::Protoss_Cybernetics_Core, false, (int)G::Protoss_Air_Weapons, 26, 2},
			{U::Protoss_Forge, false, (int)G::Protoss_Ground_Weapons, 30, 1},
			{U::Protoss_Fleet_Beacon, false, (int)G::Carrier_Capacity, 36, 0},
			{U::Protoss_Citadel_of_Adun, false, (int)G::Leg_Enhancements, 38, 1},
			{U::Protoss_Robotics_Support_Bay, false, (int)G::Reaver_Capacity, 42, 0},
			{U::Protoss_Robotics_Support_Bay, false, (int)G::Gravitic_Drive, 46, 2},
			{U::Protoss_Templar_Archives, true, (int)T::Psionic_Storm, 48, 0},
			{U::Protoss_Cybernetics_Core, false, (int)G::Protoss_Air_Armor, 56, 2},
			{U::Protoss_Forge, false, (int)G::Protoss_Ground_Armor, 60, 1},
			{U::Protoss_Arbiter_Tribunal, true, (int)T::Stasis_Field, 72, 0},
			{U::Protoss_Cybernetics_Core, false, (int)G::Protoss_Air_Weapons, 80, 1},
			{U::Protoss_Forge, false, (int)G::Protoss_Plasma_Shields, 100, 0},
		};
	}
	static a_vector<research2_step> zerg_research() {
		using U = UnitTypes;
		using T = TechTypes;
		using G = UpgradeTypes;
		return {
			{U::Zerg_Spawning_Pool, false, (int)G::Metabolic_Boost, 14, 1},
			{U::Zerg_Spire, false, (int)G::Zerg_Flyer_Attacks, 26, 2},
			{U::Zerg_Hydralisk_Den, false, (int)G::Grooved_Spines, 22, 1},
			{U::Zerg_Hydralisk_Den, false, (int)G::Muscular_Augments, 26, 1},
			{U::Zerg_Evolution_Chamber, false, (int)G::Zerg_Missile_Attacks, 30, 1},
			{U::Zerg_Lair, false, (int)G::Ventral_Sacs, 34, 2},
			{U::Zerg_Hydralisk_Den, true, (int)T::Lurker_Aspect, 38, 1},
			{U::Zerg_Spire, false, (int)G::Zerg_Flyer_Carapace, 40, 2},
			{U::Zerg_Queens_Nest, true, (int)T::Spawn_Broodlings, 46, 0},
			{U::Zerg_Lair, false, (int)G::Pneumatized_Carapace, 50, 0},
			{U::Zerg_Evolution_Chamber, false, (int)G::Zerg_Carapace, 50, 1},
			{U::Zerg_Queens_Nest, true, (int)T::Ensnare, 56, 0},
			{U::Zerg_Defiler_Mound, true, (int)T::Plague, 66, 0},
			{U::Zerg_Defiler_Mound, true, (int)T::Consume, 70, 0},
			{U::Zerg_Lair, false, (int)G::Ventral_Sacs, 70, 1},
			{U::Zerg_Spawning_Pool, false, (int)G::Adrenal_Glands, 72, 1},
			{U::Zerg_Ultralisk_Cavern, false, (int)G::Chitinous_Plating, 76, 1},
			{U::Zerg_Ultralisk_Cavern, false, (int)G::Anabolic_Synthesis, 80, 1},
			{U::Zerg_Spire, false, (int)G::Zerg_Flyer_Attacks, 80, 1},
			{U::Zerg_Evolution_Chamber, false, (int)G::Zerg_Melee_Attacks, 84, 1},
		};
	}

	// Mix rows: {type, share, cap, aa_mul, aa_div, late, cloak, some_island}.
	static a_vector<mix_row> terran_ground() {
		using U = UnitTypes;
		return {
			{U::Terran_Marine, 30, 0},
			{U::Terran_Medic, 5, 12},
			{U::Terran_Firebat, 4, 10},
			{U::Terran_Vulture, 8, 16},
			{U::Terran_Siege_Tank_Tank_Mode, 14, 0},
			{U::Terran_Goliath, 4, 30, 1, 1},
			{U::Terran_Science_Vessel, 3, 4},
			{U::Terran_Battlecruiser, 2, 0, 0, 1, 8},
			{U::Terran_Ghost, 2, 3},
			{U::Terran_Wraith, 2, 6},
			{U::Terran_Valkyrie, 0, 8, 1, 2},
			{U::Terran_Dropship, 2, 2, 0, 1, -1, -1, true},
		};
	}
	static a_vector<mix_row> terran_island() {
		using U = UnitTypes;
		return {
			{U::Terran_Wraith, 10, 0},
			{U::Terran_Battlecruiser, 16, 0},
			{U::Terran_Valkyrie, 2, 12, 1, 1},
			{U::Terran_Science_Vessel, 2, 3},
			{U::Terran_Dropship, 3, 3},
			{U::Terran_Marine, 8, 16},
			{U::Terran_Siege_Tank_Tank_Mode, 4, 6},
			{U::Terran_Goliath, 3, 16, 1, 2},
			{U::Terran_Ghost, 1, 2},
		};
	}
	static a_vector<mix_row> protoss_ground() {
		using U = UnitTypes;
		return {
			{U::Protoss_Zealot, 16, 0},
			{U::Protoss_Dragoon, 18, 0, 1, 1},
			{U::Protoss_High_Templar, 4, 6},
			{U::Protoss_Dark_Templar, 3, 4},
			{U::Protoss_Reaver, 3, 4},
			{U::Protoss_Observer, 2, 3, 0, 1, -1, 3},
			{U::Protoss_Shuttle, 2, 2},
			{U::Protoss_Carrier, 2, 0, 0, 1, 8},
			{U::Protoss_Arbiter, 1, 1},
			{U::Protoss_Corsair, 1, 12, 1, 1},
		};
	}
	static a_vector<mix_row> protoss_island() {
		using U = UnitTypes;
		return {
			{U::Protoss_Scout, 4, 8},
			{U::Protoss_Corsair, 4, 16, 1, 1},
			{U::Protoss_Carrier, 18, 0},
			{U::Protoss_Arbiter, 1, 2},
			{U::Protoss_Shuttle, 3, 3},
			{U::Protoss_Reaver, 2, 3},
			{U::Protoss_Zealot, 5, 10},
			{U::Protoss_Dragoon, 5, 10},
			{U::Protoss_Observer, 1, 2, 0, 1, -1, 2},
			{U::Protoss_High_Templar, 1, 2},
		};
	}
	static a_vector<mix_row> zerg_ground() {
		using U = UnitTypes;
		return {
			{U::Zerg_Zergling, 20, 0},
			{U::Zerg_Hydralisk, 18, 0},
			{U::Zerg_Lurker, 6, 8},
			{U::Zerg_Mutalisk, 10, 0},
			{U::Zerg_Ultralisk, 0, 8, 0, 1, 6},
			{U::Zerg_Defiler, 2, 2},
			{U::Zerg_Queen, 1, 2},
			{U::Zerg_Scourge, 0, 12, 1, 1},
			{U::Zerg_Guardian, 0, 10, 0, 1, 5},
			{U::Zerg_Devourer, 0, 6, 1, 3},
		};
	}
	static a_vector<mix_row> zerg_island() {
		using U = UnitTypes;
		return {
			{U::Zerg_Mutalisk, 18, 0},
			{U::Zerg_Scourge, 3, 16, 1, 1},
			{U::Zerg_Guardian, 10, 0},
			{U::Zerg_Devourer, 2, 10, 1, 2},
			{U::Zerg_Queen, 1, 2},
			{U::Zerg_Defiler, 1, 1},
			{U::Zerg_Hydralisk, 6, 12},
			{U::Zerg_Zergling, 6, 16},
		};
	}
};

// The numbers by the names scripts use ("army.wave_max"), with the factor
// between the script's unit and the stored one: scripts count time in
// seconds, the tunables in frames.
struct tunable_name {
	const char* name;
	size_t offset;
	int scale;
};

inline const a_vector<tunable_name>& tunable_names() {
	static const a_vector<tunable_name> names = {
		{"personality.trust_min", offsetof(ai_tunables, personality) + offsetof(ai_tunables::personality_t, trust_min), 1},
		{"personality.trust_span", offsetof(ai_tunables, personality) + offsetof(ai_tunables::personality_t, trust_span), 1},
		{"economy.workers_per_base", offsetof(ai_tunables, economy) + offsetof(ai_tunables::economy_t, workers_per_base), 1},
		{"economy.workers_per_refinery", offsetof(ai_tunables, economy) + offsetof(ai_tunables::economy_t, workers_per_refinery), 1},
		{"economy.max_workers", offsetof(ai_tunables, economy) + offsetof(ai_tunables::economy_t, max_workers), 1},
		{"economy.miners_per_patch", offsetof(ai_tunables, economy) + offsetof(ai_tunables::economy_t, miners_per_patch), 1},
		{"economy.balance_interval", offsetof(ai_tunables, economy) + offsetof(ai_tunables::economy_t, balance_interval), 24},
		{"economy.zerg_drones_first", offsetof(ai_tunables, economy) + offsetof(ai_tunables::economy_t, zerg_drones_first), 1},
		{"economy.zerg_drone_lead", offsetof(ai_tunables, economy) + offsetof(ai_tunables::economy_t, zerg_drone_lead), 1},
		{"economy.supply_margin", offsetof(ai_tunables, economy) + offsetof(ai_tunables::economy_t, supply_margin), 1},
		{"economy.supply_margin_per_producer", offsetof(ai_tunables, economy) + offsetof(ai_tunables::economy_t, supply_margin_per_producer), 1},
		{"economy.supply_double_margin", offsetof(ai_tunables, economy) + offsetof(ai_tunables::economy_t, supply_double_margin), 1},
		{"economy.gas_everywhere_after", offsetof(ai_tunables, economy) + offsetof(ai_tunables::economy_t, gas_everywhere_after), 24},
		{"economy.surplus_minerals", offsetof(ai_tunables, economy) + offsetof(ai_tunables::economy_t, surplus_minerals), 1},
		{"economy.surplus_fortify", offsetof(ai_tunables, economy) + offsetof(ai_tunables::economy_t, surplus_fortify), 1},
		{"economy.max_extra_production", offsetof(ai_tunables, economy) + offsetof(ai_tunables::economy_t, max_extra_production), 1},
		{"economy.max_pylons", offsetof(ai_tunables, economy) + offsetof(ai_tunables::economy_t, max_pylons), 1},
		{"expansion.base1", offsetof(ai_tunables, expansion) + offsetof(ai_tunables::expansion_t, base_times) + 0 * sizeof(int), 24},
		{"expansion.base2", offsetof(ai_tunables, expansion) + offsetof(ai_tunables::expansion_t, base_times) + 1 * sizeof(int), 24},
		{"expansion.base3", offsetof(ai_tunables, expansion) + offsetof(ai_tunables::expansion_t, base_times) + 2 * sizeof(int), 24},
		{"expansion.base4", offsetof(ai_tunables, expansion) + offsetof(ai_tunables::expansion_t, base_times) + 3 * sizeof(int), 24},
		{"expansion.colonize_after", offsetof(ai_tunables, expansion) + offsetof(ai_tunables::expansion_t, colonize_after), 24},
		{"expansion.colonize_workers_per_base", offsetof(ai_tunables, expansion) + offsetof(ai_tunables::expansion_t, colonize_workers_per_base), 1},
		{"expansion.colonize_minerals", offsetof(ai_tunables, expansion) + offsetof(ai_tunables::expansion_t, colonize_minerals), 1},
		{"expansion.colonize_max_bases", offsetof(ai_tunables, expansion) + offsetof(ai_tunables::expansion_t, colonize_max_bases), 1},
		{"expansion.colonize_dig_in", offsetof(ai_tunables, expansion) + offsetof(ai_tunables::expansion_t, colonize_dig_in), 1},
		{"expansion.next_base_delay", offsetof(ai_tunables, expansion) + offsetof(ai_tunables::expansion_t, next_base_delay), 24},
		{"army.wave_first", offsetof(ai_tunables, army) + offsetof(ai_tunables::army_t, wave_first), 1},
		{"army.wave_grow", offsetof(ai_tunables, army) + offsetof(ai_tunables::army_t, wave_grow), 1},
		{"army.wave_max", offsetof(ai_tunables, army) + offsetof(ai_tunables::army_t, wave_max), 1},
		{"army.wave_end_div", offsetof(ai_tunables, army) + offsetof(ai_tunables::army_t, wave_end_div), 1},
		{"army.wave_end_min", offsetof(ai_tunables, army) + offsetof(ai_tunables::army_t, wave_end_min), 1},
		{"army.attack_refresh", offsetof(ai_tunables, army) + offsetof(ai_tunables::army_t, attack_refresh), 24},
		{"army.rally_distance", offsetof(ai_tunables, army) + offsetof(ai_tunables::army_t, rally_distance), 1},
		{"army.defensive_army", offsetof(ai_tunables, army) + offsetof(ai_tunables::army_t, defensive_army), 1},
		{"army.min_minerals", offsetof(ai_tunables, army) + offsetof(ai_tunables::army_t, min_minerals), 1},
		{"army.late_game", offsetof(ai_tunables, army) + offsetof(ai_tunables::army_t, late_game), 24},
		{"army.aa_per", offsetof(ai_tunables, army) + offsetof(ai_tunables::army_t, aa_per), 1},
		{"army.aa_max", offsetof(ai_tunables, army) + offsetof(ai_tunables::army_t, aa_max), 1},
		{"army.starved_gas", offsetof(ai_tunables, army) + offsetof(ai_tunables::army_t, starved_gas), 1},
		{"army.starved_minerals", offsetof(ai_tunables, army) + offsetof(ai_tunables::army_t, starved_minerals), 1},
		{"army.starved_factor", offsetof(ai_tunables, army) + offsetof(ai_tunables::army_t, starved_factor), 1},
		{"army.morph_min", offsetof(ai_tunables, army) + offsetof(ai_tunables::army_t, morph_min), 1},
		{"army.archon_energy", offsetof(ai_tunables, army) + offsetof(ai_tunables::army_t, archon_energy), 1},
		{"defense.intruder_range", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, intruder_range), 1},
		{"defense.warning_range", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, warning_range), 1},
		{"defense.threat_hold", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, threat_hold), 24},
		{"defense.militia_all", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, militia_all), 1},
		{"defense.militia_some", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, militia_some), 1},
		{"defense.militia_time", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, militia_time), 24},
		{"defense.expansion_defenses", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, expansion_defenses), 1},
		{"defense.fortify_main_ground", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, fortify_main_ground), 1},
		{"defense.fortify_main_air", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, fortify_main_air), 1},
		{"defense.fortify_ground", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, fortify_ground), 1},
		{"defense.fortify_air", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, fortify_air), 1},
		{"defense.fortify", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, fortify), 1},
		{"defense.colony_ground", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, colony_ground), 1},
		{"defense.colony_air", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, colony_air), 1},
		{"defense.colony_rich", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, colony_rich), 1},
		{"defense.colony_mobile", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, colony_mobile), 1},
		{"defense.colony_tanks", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, colony_tanks), 1},
		{"defense.marines_per_bunker", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, marines_per_bunker), 1},
		{"defense.colony_marines", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, colony_marines), 1},
		{"defense.air_trigger", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, air_trigger), 1},
		{"defense.air_island_after", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, air_island_after), 24},
		{"defense.air_per", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, air_per), 1},
		{"defense.air_max", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, air_max), 1},
		{"defense.air_island_min", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, air_island_min), 1},
		{"defense.max_comsats", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, max_comsats), 1},
		{"defense.silos", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, silos), 1},
		{"defense.silos_late", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, silos_late), 1},
		{"defense.silos_late_after", offsetof(ai_tunables, defense) + offsetof(ai_tunables::defense_t, silos_late_after), 24},
		{"help.range", offsetof(ai_tunables, help) + offsetof(ai_tunables::help_t, range), 1},
		{"help.fresh", offsetof(ai_tunables, help) + offsetof(ai_tunables::help_t, fresh), 24},
		{"help.whole_army", offsetof(ai_tunables, help) + offsetof(ai_tunables::help_t, whole_army), 1},
		{"help.refresh", offsetof(ai_tunables, help) + offsetof(ai_tunables::help_t, refresh), 24},
		{"help.guard_radius", offsetof(ai_tunables, help) + offsetof(ai_tunables::help_t, guard_radius), 1},
		{"drops.max", offsetof(ai_tunables, drops) + offsetof(ai_tunables::drops_t, max), 1},
		{"drops.min_space", offsetof(ai_tunables, drops) + offsetof(ai_tunables::drops_t, min_space), 1},
		{"drops.load_time", offsetof(ai_tunables, drops) + offsetof(ai_tunables::drops_t, load_time), 24},
		{"drops.give_up", offsetof(ai_tunables, drops) + offsetof(ai_tunables::drops_t, give_up), 24},
		{"drops.overlords", offsetof(ai_tunables, drops) + offsetof(ai_tunables::drops_t, overlords), 1},
		{"spells.lockdown", offsetof(ai_tunables, spells) + offsetof(ai_tunables::spells_t, lockdown), 1},
		{"spells.nuke_interval", offsetof(ai_tunables, spells) + offsetof(ai_tunables::spells_t, nuke_interval), 24},
		{"spells.yamato", offsetof(ai_tunables, spells) + offsetof(ai_tunables::spells_t, yamato), 1},
		{"spells.yamato_defense_bonus", offsetof(ai_tunables, spells) + offsetof(ai_tunables::spells_t, yamato_defense_bonus), 1},
		{"spells.irradiate", offsetof(ai_tunables, spells) + offsetof(ai_tunables::spells_t, irradiate), 1},
		{"spells.emp", offsetof(ai_tunables, spells) + offsetof(ai_tunables::spells_t, emp), 1},
		{"spells.matrix", offsetof(ai_tunables, spells) + offsetof(ai_tunables::spells_t, matrix), 1},
		{"spells.storm", offsetof(ai_tunables, spells) + offsetof(ai_tunables::spells_t, storm), 1},
		{"spells.stasis", offsetof(ai_tunables, spells) + offsetof(ai_tunables::spells_t, stasis), 1},
		{"spells.web", offsetof(ai_tunables, spells) + offsetof(ai_tunables::spells_t, web), 1},
		{"spells.plague", offsetof(ai_tunables, spells) + offsetof(ai_tunables::spells_t, plague), 1},
		{"spells.swarm", offsetof(ai_tunables, spells) + offsetof(ai_tunables::spells_t, swarm), 1},
		{"spells.broodlings", offsetof(ai_tunables, spells) + offsetof(ai_tunables::spells_t, broodlings), 1},
		{"spells.ensnare", offsetof(ai_tunables, spells) + offsetof(ai_tunables::spells_t, ensnare), 1},
		{"diplomacy.open_trust", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, open_trust), 1},
		{"diplomacy.closed_trust", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, closed_trust), 1},
		{"diplomacy.first_invite", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, first_invite), 24},
		{"diplomacy.first_invite_spread", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, first_invite_spread), 24},
		{"diplomacy.open_check", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, open_check), 24},
		{"diplomacy.trust_center", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, trust_center), 1},
		{"diplomacy.trust_div", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, trust_div), 1},
		{"diplomacy.closeness_div", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, closeness_div), 1},
		{"diplomacy.peace", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, peace), 1},
		{"diplomacy.helper", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, helper), 1},
		{"diplomacy.dominant_pct", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, dominant_pct), 1},
		{"diplomacy.dominant", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, dominant), 1},
		{"diplomacy.dead_weight_ratio", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, dead_weight_ratio), 1},
		{"diplomacy.dead_weight", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, dead_weight), 1},
		{"diplomacy.beating_value", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, beating_value), 1},
		{"diplomacy.beating", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, beating), 1},
		{"diplomacy.common_enemy_pct", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, common_enemy_pct), 1},
		{"diplomacy.common_enemy", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, common_enemy), 1},
		{"diplomacy.mining_max", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, mining_max), 1},
		{"diplomacy.mining_scale", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, mining_scale), 1},
		{"diplomacy.strong_ally", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, strong_ally), 1},
		{"diplomacy.losing_threat", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, losing_threat), 1},
		{"diplomacy.losing_pct", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, losing_pct), 1},
		{"diplomacy.losing_losses", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, losing_losses), 1},
		{"diplomacy.outmatched_pct", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, outmatched_pct), 1},
		{"diplomacy.accept_open", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, accept_open), 1},
		{"diplomacy.accept_closed", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, accept_closed), 1},
		{"diplomacy.accept_noise", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, accept_noise), 1},
		{"diplomacy.tribute_rate", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, tribute_rate), 1},
		{"diplomacy.tribute_army_div", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, tribute_army_div), 1},
		{"diplomacy.tribute_trust", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, tribute_trust), 1},
		{"diplomacy.conquest_pct", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, conquest_pct), 1},
		{"diplomacy.refused_window", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, refused_window), 24},
		{"diplomacy.hopeless_after", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, hopeless_after), 24},
		{"diplomacy.surrender_retry", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, surrender_retry), 24},
		{"diplomacy.betray_after", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, betray_after), 24},
		{"diplomacy.betray_check", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, betray_check), 24},
		{"diplomacy.betray_edge", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, betray_edge), 1},
		{"diplomacy.betray_outside", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, betray_outside), 1},
		{"diplomacy.invite_losing", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, invite_losing), 24},
		{"diplomacy.invite_interval", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, invite_interval), 24},
		{"diplomacy.invite_spread", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, invite_spread), 1},
		{"diplomacy.no_pester", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, no_pester), 24},
		{"diplomacy.invite_utility", offsetof(ai_tunables, diplomacy) + offsetof(ai_tunables::diplomacy_t, invite_utility), 1},
	};
	return names;
}

inline int& tunable_at(ai_tunables& t, size_t offset) {
	return *reinterpret_cast<int*>(reinterpret_cast<char*>(&t) + offset);
}

} // namespace bw_ai

#endif // BW_AI_PARAMS_H
