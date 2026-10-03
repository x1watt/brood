// engine/bridge/src/bw_alliances.h
//
// In-game alliances, a mechanic of this project (Brood War itself only has
// allied/enemy flags). Players form groups by inviting and accepting; a
// group shares:
//   - one treasury: every member sees and spends the same minerals and gas,
//   - its technology: researched techs and upgrade levels,
//   - control: a member may command the others' units (see bw_bridge.cpp),
//   - points: everything any member mines is credited to every member.
// It also keeps the military side of the score: what each player destroyed
// (Brood War's destroy_score per unit type) and who killed whose units, which
// the computer players use to notice they are losing a fight.
// Members are allied in OpenBW's sense too (st.alliances = 2 both ways and
// shared vision), so melee victory is shared. A group can never hold every
// player still in the game, otherwise the game would end at once.
//
// Everything here is driven by logged bridge commands and deterministic
// computer decisions, so saved games replay it exactly.

#ifndef BW_ALLIANCES_H
#define BW_ALLIANCES_H

#include "bwgame.h"
#include "actions.h"

#include <algorithm>
#include <array>
#include <cstdint>

namespace bw_alliances {

using namespace bwgame;

static const int max_players = 8;

enum event_kind : int32_t {
	event_invited = 1, // a invited b
	event_declined,    // b declined a's invitation
	event_formed,      // b joined a's alliance
	event_left,        // a left its alliance
	event_open,        // a is open to alliances now
	event_closed,      // a no longer accepts alliances
};

struct event {
	int32_t frame;
	int32_t kind;
	int32_t a;
	int32_t b;
};

struct alliance_system {
	std::array<int, max_players> group{};       // group id: the slot of its founder
	std::array<bool, max_players> open{};       // accepting invitations
	std::array<bool, max_players> playing{};    // part of this game
	// invite_frame[to][from]: frame `from` invited `to`, -1 for none.
	std::array<std::array<int, max_players>, max_players> invite_frame{};
	std::array<int, max_players> synced_minerals{};
	std::array<int, max_players> synced_gas{};
	std::array<int, max_players> gathered_seen{};
	std::array<int64_t, max_players> points{};
	std::array<int64_t, max_players> own_points{}; // mined by this player alone
	std::array<int64_t, max_players> kill_score{};   // destroy_score of enemy units and buildings
	std::array<int, max_players> units_killed{};
	std::array<int, max_players> buildings_razed{};
	std::array<int, max_players> units_lost{};
	// Mineral + gas value of units each player lost to each other player:
	// value_lost_to[victim][killer].
	std::array<std::array<int, max_players>, max_players> value_lost_to{};
	a_vector<event> events;                      // for the UI, drained by polling

	void reset(state& st, const std::array<int, max_players>& team_of_slot) {
		for (int p = 0; p != max_players; ++p) {
			group[p] = p;
			open[p] = false;
			playing[p] = st.players[p].controller == player_t::controller_occupied;
			for (auto& f : invite_frame[p]) f = -1;
			synced_minerals[p] = st.current_minerals[p];
			synced_gas[p] = st.current_gas[p];
			gathered_seen[p] = st.total_minerals_gathered[p] + st.total_gas_gathered[p];
			points[p] = 0;
			own_points[p] = 0;
			kill_score[p] = 0;
			units_killed[p] = 0;
			buildings_razed[p] = 0;
			units_lost[p] = 0;
			value_lost_to[p] = {};
		}
		events.clear();
		// Teams chosen before the game start as alliances.
		for (int a = 0; a != max_players; ++a) {
			if (!playing[a] || team_of_slot[a] == 0) continue;
			for (int b = 0; b != a; ++b) {
				if (playing[b] && team_of_slot[b] == team_of_slot[a]) {
					group[a] = group[b];
					break;
				}
			}
		}
		// A team's treasury starts as the sum of its members' money.
		for (int g = 0; g != max_players; ++g) {
			if (members(g).size() < 2) continue;
			int m = 0, gas = 0;
			for (int p : members(g)) {
				m += st.current_minerals[p];
				gas += st.current_gas[p];
			}
			for (int p : members(g)) set_money(st, p, m, gas);
		}
		apply_relations(st);
	}

	bool active(const state& st, int p) const {
		return p >= 0 && p < max_players && playing[p] && st.players[p].controller == player_t::controller_occupied &&
		       st.players[p].victory_state == 0;
	}

	a_vector<int> members(int g) const {
		a_vector<int> r;
		for (int p = 0; p != max_players; ++p) {
			if (playing[p] && group[p] == g) r.push_back(p);
		}
		return r;
	}

	bool same_group(int a, int b) const {
		return a >= 0 && b >= 0 && a < max_players && b < max_players && group[a] == group[b];
	}

	// Whether `owner` may command `other`'s units.
	bool can_control(const state& st, int owner, int other) const {
		if (owner == other) return true;
		return same_group(owner, other) && active(st, owner) && active(st, other);
	}

	// Merging a's and b's groups must leave someone to fight.
	bool merge_allowed(const state& st, int a, int b) const {
		if (!active(st, a) || !active(st, b) || same_group(a, b)) return false;
		for (int p = 0; p != max_players; ++p) {
			if (active(st, p) && group[p] != group[a] && group[p] != group[b]) return true;
		}
		return false;
	}

	void set_money(state& st, int p, int minerals, int gas) {
		st.current_minerals[p] = minerals;
		st.current_gas[p] = gas;
		synced_minerals[p] = minerals;
		synced_gas[p] = gas;
	}

	void push_event(const state& st, int kind, int a, int b) {
		if (events.size() >= 256) events.erase(events.begin());
		events.push_back({(int32_t)st.current_frame, kind, a, b});
	}

	// OpenBW's view: same group = allied with shared vision, others enemies.
	void apply_relations(state& st) {
		action_state scratch;
		action_functions f(st, scratch);
		for (int a = 0; a != max_players; ++a) {
			if (!playing[a]) continue;
			std::array<int, 12> rel = st.alliances[a];
			uint32_t vision = 1u << a;
			for (int b = 0; b != max_players; ++b) {
				if (b == a || !playing[b]) continue;
				bool allied = group[a] == group[b];
				rel[b] = allied ? 2 : 0;
				if (allied) vision |= 1u << b;
			}
			// Also drops attack orders aimed at new allies.
			f.action_set_alliances(a, rel);
			st.shared_vision[a] = (st.shared_vision[a] & ~0xffu) | vision;
		}
	}

	// --- commands -------------------------------------------------------------

	bool set_open(state& st, int p, bool on) {
		if (!active(st, p) || open[p] == on) return false;
		open[p] = on;
		push_event(st, on ? event_open : event_closed, p, -1);
		return true;
	}

	bool invite(state& st, int from, int to) {
		if (from == to || !merge_allowed(st, from, to)) return false;
		if (invite_frame[to][from] >= 0) return false;
		// An invitation answers one already received.
		if (invite_frame[from][to] >= 0) return respond(st, from, to, true);
		invite_frame[to][from] = st.current_frame;
		push_event(st, event_invited, from, to);
		return true;
	}

	bool respond(state& st, int p, int from, bool accept) {
		if (p < 0 || p >= max_players || from < 0 || from >= max_players) return false;
		if (invite_frame[p][from] < 0) return false;
		invite_frame[p][from] = -1;
		if (!accept || !merge_allowed(st, from, p)) {
			push_event(st, event_declined, from, p);
			return true;
		}
		sync(st);
		int ga = group[from], gb = group[p];
		// One treasury from two.
		a_vector<int> a_members = members(ga), b_members = members(gb);
		int minerals = st.current_minerals[a_members.front()] + st.current_minerals[b_members.front()];
		int gas = st.current_gas[a_members.front()] + st.current_gas[b_members.front()];
		for (int m : b_members) group[m] = ga;
		for (int m : members(ga)) set_money(st, m, minerals, gas);
		// Invitations between the new partners are settled.
		for (int x : members(ga)) {
			for (int y : members(ga)) invite_frame[x][y] = -1;
		}
		push_event(st, event_formed, from, p);
		apply_relations(st);
		share_technology(st);
		return true;
	}

	bool leave(state& st, int p) {
		if (!active(st, p)) return false;
		a_vector<int> mates = members(group[p]);
		if (mates.size() < 2) return false;
		sync(st);
		a_vector<int> rest;
		for (int m : mates) {
			if (m != p) rest.push_back(m);
		}
		// Group ids are a member's slot: if the founder leaves, the next
		// member's slot names what remains.
		int remaining = group[p] == p ? rest.front() : group[p];
		for (int m : rest) group[m] = remaining;
		group[p] = p;
		// The leaver takes an equal share of the treasury.
		int minerals = st.current_minerals[p], gas = st.current_gas[p];
		int share_m = minerals / (int)mates.size(), share_g = gas / (int)mates.size();
		set_money(st, p, share_m, share_g);
		for (int m : rest) set_money(st, m, minerals - share_m, gas - share_g);
		for (int x = 0; x != max_players; ++x) {
			invite_frame[p][x] = -1;
			invite_frame[x][p] = -1;
		}
		push_event(st, event_left, p, -1);
		apply_relations(st);
		return true;
	}

	// Takes a player who is out of the game out of its group.
	void drop(state& st, int p) {
		a_vector<int> mates = members(group[p]);
		if (mates.size() < 2) return;
		int remaining = -1;
		for (int m : mates) {
			if (m != p) {
				remaining = group[p] == p ? m : group[p];
				break;
			}
		}
		for (int m : mates) {
			if (m != p) group[m] = remaining;
		}
		group[p] = p;
		synced_minerals[p] = st.current_minerals[p];
		synced_gas[p] = st.current_gas[p];
	}

	// A unit died (OpenBW's on_kill_unit): credit whoever attacked it last.
	void on_kill(const unit_t* u) {
		int victim = u->owner, killer = u->last_attacking_player;
		if (victim < 0 || victim >= max_players) return;
		if (u->unit_type->id == UnitTypes::Zerg_Larva || u->unit_type->id == UnitTypes::Zerg_Egg) return;
		bool building = (u->unit_type->group_flags & GroupFlags::Building) != 0;
		if (!building) ++units_lost[victim];
		if (killer < 0 || killer >= max_players || killer == victim) return;
		kill_score[killer] += u->unit_type->destroy_score;
		if (building) ++buildings_razed[killer];
		else ++units_killed[killer];
		value_lost_to[victim][killer] += u->unit_type->mineral_cost + u->unit_type->gas_cost;
	}

	// --- per frame ------------------------------------------------------------

	// Folds every member's spending and income since the last sync into the
	// group's treasury and hands everyone the result.
	void sync(state& st) {
		std::array<bool, max_players> done{};
		for (int p = 0; p != max_players; ++p) {
			if (!playing[p] || done[(size_t)group[p]]) continue;
			int g = group[p];
			done[(size_t)g] = true;
			a_vector<int> mates = members(g);
			if (mates.size() < 2) {
				synced_minerals[p] = st.current_minerals[p];
				synced_gas[p] = st.current_gas[p];
				continue;
			}
			int base_m = synced_minerals[mates.front()], base_g = synced_gas[mates.front()];
			int m = base_m, gas = base_g;
			for (int q : mates) {
				m += st.current_minerals[q] - synced_minerals[q];
				gas += st.current_gas[q] - synced_gas[q];
			}
			// Two members spending the last minerals in the same frame:
			// the treasury can't go below zero.
			for (int q : mates) set_money(st, q, std::max(0, m), std::max(0, gas));
		}
	}

	// Researched techs and upgrade levels: the best in the group for all.
	void share_technology(state& st) {
		action_state scratch;
		action_functions f(st, scratch);
		std::array<bool, max_players> done{};
		for (int p = 0; p != max_players; ++p) {
			if (!playing[p] || done[(size_t)group[p]]) continue;
			done[(size_t)group[p]] = true;
			a_vector<int> mates = members(group[p]);
			if (mates.size() < 2) continue;
			std::array<bool, max_players> upgraded{};
			for (size_t t = 0; t != (size_t)TechTypes::None; ++t) {
				bool any = false;
				for (int q : mates) any |= st.tech_researched[q][(TechTypes)t];
				if (!any) continue;
				for (int q : mates) st.tech_researched[q][(TechTypes)t] = true;
			}
			for (size_t u = 0; u != (size_t)UpgradeTypes::None; ++u) {
				int best = 0;
				for (int q : mates) best = std::max(best, st.upgrade_levels[q][(UpgradeTypes)u]);
				for (int q : mates) {
					if (st.upgrade_levels[q][(UpgradeTypes)u] < best) {
						st.upgrade_levels[q][(UpgradeTypes)u] = best;
						upgraded[(size_t)q] = true;
					}
				}
			}
			for (int q : mates) {
				if (upgraded[(size_t)q]) f.apply_upgrades_to_player_units(q);
			}
		}
	}

	// Points: everything mined, credited to the whole group.
	void score(state& st) {
		std::array<int64_t, max_players> group_gain{};
		std::array<int64_t, max_players> gain{};
		for (int p = 0; p != max_players; ++p) {
			if (!playing[p]) continue;
			int total = st.total_minerals_gathered[p] + st.total_gas_gathered[p];
			gain[(size_t)p] = total - gathered_seen[p];
			gathered_seen[p] = total;
			own_points[p] += gain[(size_t)p];
			group_gain[(size_t)group[p]] += gain[(size_t)p];
		}
		for (int p = 0; p != max_players; ++p) {
			if (active(st, p)) points[p] += group_gain[(size_t)group[p]];
		}
	}

	void after_frame(state& st) {
		// A defeated player drops out of its group.
		for (int p = 0; p != max_players; ++p) {
			if (playing[p] && !active(st, p) && members(group[p]).size() > 1) drop(st, p);
		}
		sync(st);
		score(st);
		if (st.current_frame % 8 == 0) share_technology(st);
	}
};

} // namespace bw_alliances

#endif // BW_ALLIANCES_H
