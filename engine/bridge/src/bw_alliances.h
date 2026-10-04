// engine/bridge/src/bw_alliances.h
//
// In-game alliances, a mechanic of this project (Brood War itself only has
// allied/enemy flags). Players form groups by inviting and accepting; a
// group shares:
//   - a treasury, among the members who chose to share resources (each
//     player's switch; computer players start with it on, the human with
//     it off): they see and spend the same minerals and gas, the others
//     keep their own,
//   - its technology: researched techs and upgrade levels,
//   - defensive mode: when a human member switches it on, the alliance's
//     computer players stop attacking and fortify their bases (bw_ai.h),
//   - control: a member may command the others' units (see bw_bridge.cpp),
//   - points: everything any free member mines is credited to every free
//     member.
// Members are allied in OpenBW's sense too (st.alliances = 2 both ways and
// shared vision), so melee victory is shared. A group can never hold every
// player still in the game, otherwise the game would end at once. Every
// group of two or more carries a name (two words, picked by the UI from a
// code drawn here).
//
// Surrender: a player losing a war may offer to surrender to the player
// beating it. Accepted, it joins its conqueror's group for good: it can't
// leave, invite, be invited or take surrenders, and half of what it earns
// (mining and destroying) goes to its lord. If the lord surrenders or is
// conquered in turn, its vassals pass to the new conqueror.
//
// Also kept here: the military side of the score (Brood War's destroy_score
// credited to whoever attacked last), who killed whose units, who is
// fighting whom right now, and each player's army value and mining rate.
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
static const int name_words = 64; // per word list in the UI
static const int rate_window = 60; // seconds of history for mining rates

enum event_kind : int32_t {
	event_invited = 1,     // a invited b
	event_declined,        // b declined a's invitation
	event_formed,          // b joined a's alliance
	event_left,            // a left its alliance
	event_open,            // a is open to alliances now
	event_closed,          // a no longer accepts alliances
	event_surrender_offer, // a offered to surrender to b
	event_surrendered,     // a surrendered to b
	event_surrender_refused, // b refused a's surrender
	event_vassal_moved,    // a, a vassal, now serves b (its lord was conquered)
};

struct event {
	int32_t frame;
	int32_t kind;
	int32_t a;
	int32_t b;
};

using matrix = std::array<std::array<int, max_players>, max_players>;

struct alliance_system {
	std::array<int, max_players> group{};       // group id: the slot of one of its members
	std::array<bool, max_players> open{};       // accepting invitations
	std::array<bool, max_players> playing{};    // part of this game
	std::array<int, max_players> lord{};        // -1, or whom this player surrendered to
	matrix invite_frame{};                      // [to][from]: frame `from` invited `to`, -1 none
	matrix surrender_frame{};                   // [to][from]: frame `from` offered to surrender, -1 none
	std::array<int, max_players> last_declined{}; // last frame someone declined this player's invitation
	std::array<int, max_players> name_of_group{}; // by group id: name code, -1 for none
	uint32_t name_rng = 1;

	std::array<bool, max_players> share{}; // pools money with the group's other sharers
	std::array<bool, max_players> defensive{}; // this (human) player asks its allies to stay home
	std::array<int, max_players> synced_minerals{};
	std::array<int, max_players> synced_gas{};
	std::array<int, max_players> gathered_seen{};
	std::array<int64_t, max_players> points{};     // mining points (see score())
	std::array<int64_t, max_players> own_points{}; // mined by this player alone
	std::array<int64_t, max_players> kill_score{}; // destroy_score of enemy units and buildings
	std::array<int, max_players> units_killed{};
	std::array<int, max_players> buildings_razed{};
	std::array<int, max_players> units_lost{};
	// For the score screen: buildings lost, destroy score split into units
	// and buildings, and what each player spent (see sync()).
	std::array<int, max_players> buildings_lost{};
	std::array<int64_t, max_players> kill_units_score{};
	std::array<int64_t, max_players> kill_buildings_score{};
	std::array<int64_t, max_players> spent_minerals{};
	std::array<int64_t, max_players> spent_gas{};
	std::array<int, max_players> spend_seen_minerals{};
	std::array<int, max_players> spend_seen_gas{};
	matrix value_lost_to{}; // mineral + gas value lost: [victim][killer]
	matrix recent_lost{};   // the same, fading over about half a minute
	std::array<uint32_t, max_players> fighting{}; // players each one is clashing with now

	std::array<int, max_players> army_value{}; // mineral + gas value of combat units
	std::array<int, max_players> workers{};
	std::array<std::array<int, rate_window>, max_players> mineral_history{};
	std::array<std::array<int, rate_window>, max_players> gas_history{};
	std::array<int, max_players> mineral_rate{}; // per minute
	std::array<int, max_players> gas_rate{};
	int samples = 0;

	a_vector<event> events; // for the UI, drained by polling

	void reset(state& st, const std::array<int, max_players>& team_of_slot, const std::array<bool, max_players>& shares, uint32_t seed) {
		name_rng = seed * 2246822519u + 3266489917u;
		for (int p = 0; p != max_players; ++p) {
			group[p] = p;
			share[p] = shares[p];
			defensive[p] = false;
			open[p] = false;
			lord[p] = -1;
			playing[p] = st.players[p].controller == player_t::controller_occupied;
			for (auto& f : invite_frame[p]) f = -1;
			for (auto& f : surrender_frame[p]) f = -1;
			last_declined[p] = -100000;
			name_of_group[p] = -1;
			synced_minerals[p] = st.current_minerals[p];
			synced_gas[p] = st.current_gas[p];
			gathered_seen[p] = st.total_minerals_gathered[p] + st.total_gas_gathered[p];
			points[p] = own_points[p] = kill_score[p] = 0;
			units_killed[p] = buildings_razed[p] = units_lost[p] = 0;
			buildings_lost[p] = 0;
			kill_units_score[p] = kill_buildings_score[p] = spent_minerals[p] = spent_gas[p] = 0;
			spend_seen_minerals[p] = st.total_minerals_gathered[p];
			spend_seen_gas[p] = st.total_gas_gathered[p];
			value_lost_to[p] = {};
			recent_lost[p] = {};
			fighting[p] = 0;
			army_value[p] = workers[p] = mineral_rate[p] = gas_rate[p] = 0;
		}
		samples = 0;
		events.clear();
		// Teams chosen before the game start as alliances; the sharers' treasury
		// starts as the sum of their money.
		regroup(st, [&] {
			for (int a = 0; a != max_players; ++a) {
				if (!playing[a] || team_of_slot[a] == 0) continue;
				for (int b = 0; b != a; ++b) {
					if (playing[b] && team_of_slot[b] == team_of_slot[a]) {
						group[a] = group[b];
						break;
					}
				}
			}
		});
		for (int g = 0; g != max_players; ++g) {
			if (members(g).size() >= 2) name_group(g);
		}
		apply_relations(st);
	}

	bool active(const state& st, int p) const {
		return p >= 0 && p < max_players && playing[p] && st.players[p].controller == player_t::controller_occupied &&
		       st.players[p].victory_state == 0;
	}

	bool vassal(int p) const {
		return p >= 0 && p < max_players && lord[p] >= 0;
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

	// Someone outside the given groups (ids) is still in the game.
	bool someone_outside(const state& st, int g1, int g2, int also_excluded = -1) const {
		for (int p = 0; p != max_players; ++p) {
			if (!active(st, p) || group[p] == g1 || group[p] == g2) continue;
			if (also_excluded >= 0 && (p == also_excluded || lord[p] == also_excluded)) continue;
			return true;
		}
		return false;
	}

	// Merging a's and b's groups must leave someone to fight. Vassals don't
	// make alliances of their own.
	bool merge_allowed(const state& st, int a, int b) const {
		if (!active(st, a) || !active(st, b) || same_group(a, b) || vassal(a) || vassal(b)) return false;
		return someone_outside(st, group[a], group[b]);
	}

	// `from` (with its own vassals) joining `to`'s group must leave someone.
	bool surrender_allowed(const state& st, int from, int to) const {
		if (from == to || !active(st, from) || !active(st, to) || vassal(from) || vassal(to) || same_group(from, to)) return false;
		for (int p = 0; p != max_players; ++p) {
			if (!active(st, p) || p == from || lord[p] == from || group[p] == group[to]) continue;
			return true;
		}
		return false;
	}

	void set_money(state& st, int p, int minerals, int gas) {
		st.current_minerals[p] = minerals;
		st.current_gas[p] = gas;
		synced_minerals[p] = minerals;
		synced_gas[p] = gas;
	}

	// Who spends from the same money as p: the sharers of its group, or p alone.
	a_vector<int> pool(int p) const {
		if (!share[p]) return {p};
		a_vector<int> out;
		for (int m : members(group[p])) {
			if (share[m]) out.push_back(m);
		}
		return out;
	}

	// Changes groups or share switches (`change`) and moves the money along:
	// every treasury is split per head among its members first, and each
	// treasury afterwards is the sum of its members' heads. So joiners bring
	// their money, leavers take their share, and a player who stops sharing
	// keeps an equal part of what the sharers had.
	template<typename F>
	void regroup(state& st, F&& change) {
		sync(st);
		std::array<int, max_players> head_m{}, head_g{};
		for (int p = 0; p != max_players; ++p) {
			if (!playing[p]) continue;
			a_vector<int> mates = pool(p);
			int n = (int)mates.size();
			int m = st.current_minerals[p], g = st.current_gas[p];
			head_m[p] = m / n + (p == mates.front() ? m % n : 0);
			head_g[p] = g / n + (p == mates.front() ? g % n : 0);
		}
		change();
		std::array<bool, max_players> done{};
		for (int p = 0; p != max_players; ++p) {
			if (!playing[p] || done[p]) continue;
			a_vector<int> mates = pool(p);
			int m = 0, g = 0;
			for (int q : mates) {
				m += head_m[q];
				g += head_g[q];
				done[q] = true;
			}
			for (int q : mates) set_money(st, q, m, g);
		}
	}

	bool set_defensive(state& st, int p, bool on) {
		if (!active(st, p) || defensive[p] == on) return false;
		defensive[p] = on;
		return true;
	}

	// Whether p's alliance is in defensive mode: a member switched it on.
	bool defensive_for(int p) const {
		if (p < 0 || p >= max_players) return false;
		for (int m : members(group[p])) {
			if (defensive[m]) return true;
		}
		return false;
	}

	bool set_share(state& st, int p, bool on) {
		if (!active(st, p) || share[p] == on) return false;
		regroup(st, [&] { share[p] = on; });
		return true;
	}

	void push_event(const state& st, int kind, int a, int b) {
		if (events.size() >= 256) events.erase(events.begin());
		events.push_back({(int32_t)st.current_frame, kind, a, b});
	}

	void name_group(int g) {
		if (name_of_group[g] >= 0) return;
		name_rng = name_rng * 1103515245u + 12345u;
		int first = (int)((name_rng >> 16) % name_words);
		name_rng = name_rng * 1103515245u + 12345u;
		int second = (int)((name_rng >> 16) % name_words);
		name_of_group[g] = first * name_words + second;
	}

	// Keeps names attached to groups as their ids change and they grow or
	// shrink below two members.
	void tidy_names() {
		for (int g = 0; g != max_players; ++g) {
			int n = (int)members(g).size();
			if (n < 2) name_of_group[g] = -1;
			else name_group(g);
		}
	}

	void move_group(int from_id, int to_id) {
		if (from_id == to_id) return;
		if (name_of_group[to_id] < 0) name_of_group[to_id] = name_of_group[from_id];
		name_of_group[from_id] = -1;
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
		tidy_names();
	}

	void clear_offers(int p) {
		for (int x = 0; x != max_players; ++x) {
			invite_frame[p][x] = invite_frame[x][p] = -1;
			surrender_frame[p][x] = surrender_frame[x][p] = -1;
		}
	}

	// Moves `movers` (all in one group) into group `target`, pooling money.
	void join(state& st, const a_vector<int>& movers, int target) {
		int old = group[movers.front()];
		a_vector<int> stay;
		for (int m : members(old)) {
			if (std::find(movers.begin(), movers.end(), m) == movers.end()) stay.push_back(m);
		}
		// The movers take along their share of their old treasury.
		regroup(st, [&] {
			if (!stay.empty()) {
				int id = std::find(stay.begin(), stay.end(), old) != stay.end() ? old : stay.front();
				move_group(old, id);
				for (int m : stay) group[m] = id;
			}
			for (int m : movers) group[m] = target;
		});
	}

	// --- commands -------------------------------------------------------------

	bool set_open(state& st, int p, bool on) {
		if (!active(st, p) || vassal(p) || open[p] == on) return false;
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
			last_declined[from] = st.current_frame;
			push_event(st, event_declined, from, p);
			return true;
		}
		int ga = group[from], gb = group[p];
		a_vector<int> a_members = members(ga), b_members = members(gb);
		// The larger alliance's name lives on.
		if (name_of_group[ga] < 0 || (b_members.size() > a_members.size() && name_of_group[gb] >= 0)) name_of_group[ga] = name_of_group[gb];
		name_of_group[gb] = -1;
		// The two groups' sharers pool their treasuries.
		regroup(st, [&] {
			for (int m : b_members) group[m] = ga;
		});
		// Invitations between the new partners are settled.
		for (int x : members(ga)) {
			for (int y : members(ga)) invite_frame[x][y] = surrender_frame[x][y] = -1;
		}
		push_event(st, event_formed, from, p);
		apply_relations(st);
		share_technology(st);
		return true;
	}

	bool leave(state& st, int p) {
		if (!active(st, p) || vassal(p)) return false;
		a_vector<int> mates = members(group[p]);
		// A lord leaves with its vassals.
		a_vector<int> movers{p};
		for (int m : mates) {
			if (lord[m] == p) movers.push_back(m);
		}
		if (movers.size() >= mates.size()) return false;
		int old = group[p];
		a_vector<int> rest;
		for (int m : mates) {
			if (std::find(movers.begin(), movers.end(), m) == movers.end()) rest.push_back(m);
		}
		// Group ids are a member's slot. The leavers take their share of the
		// treasury.
		regroup(st, [&] {
			int remaining = std::find(rest.begin(), rest.end(), old) != rest.end() ? old : rest.front();
			move_group(old, remaining);
			for (int m : rest) group[m] = remaining;
			for (int m : movers) group[m] = p;
		});
		for (int m : movers) clear_offers(m);
		push_event(st, event_left, p, -1);
		apply_relations(st);
		return true;
	}

	bool offer_surrender(state& st, int from, int to) {
		if (!surrender_allowed(st, from, to) || surrender_frame[to][from] >= 0) return false;
		surrender_frame[to][from] = st.current_frame;
		push_event(st, event_surrender_offer, from, to);
		return true;
	}

	// `from` becomes `to`'s vassal, with its own vassals.
	void make_vassal(state& st, int from, int to) {
		a_vector<int> movers{from};
		for (int m = 0; m != max_players; ++m) {
			if (lord[m] == from) movers.push_back(m);
		}
		// They leave whatever alliance they were in.
		join(st, movers, group[to]);
		for (int m : movers) {
			lord[m] = to;
			open[m] = false;
			clear_offers(m);
		}
		for (int m : movers) {
			if (m != from) push_event(st, event_vassal_moved, m, to);
		}
		apply_relations(st);
		share_technology(st);
	}

	bool answer_surrender(state& st, int p, int from, bool accept) {
		if (p < 0 || p >= max_players || from < 0 || from >= max_players) return false;
		if (surrender_frame[p][from] < 0) return false;
		surrender_frame[p][from] = -1;
		if (!accept || !surrender_allowed(st, from, p)) {
			push_event(st, event_surrender_refused, from, p);
			return true;
		}
		push_event(st, event_surrendered, from, p);
		make_vassal(st, from, p);
		return true;
	}

	// Takes a player who is out of the game out of its group; its vassals
	// pass to whoever destroyed most of it, if that player is still in.
	void drop(state& st, int p) {
		a_vector<int> mates = members(group[p]);
		if (mates.size() >= 2) {
			int old = group[p];
			a_vector<int> rest;
			for (int m : mates) {
				if (m != p) rest.push_back(m);
			}
			int remaining = std::find(rest.begin(), rest.end(), old) != rest.end() ? old : rest.front();
			move_group(old, remaining);
			for (int m : rest) group[m] = remaining;
			group[p] = p;
			synced_minerals[p] = st.current_minerals[p];
			synced_gas[p] = st.current_gas[p];
		}
		lord[p] = -1;
		tidy_names();
		a_vector<int> vassals;
		for (int m = 0; m != max_players; ++m) {
			if (lord[m] == p && active(st, m)) vassals.push_back(m);
		}
		if (vassals.empty()) return;
		int conqueror = -1, best = 0;
		for (int k = 0; k != max_players; ++k) {
			if (!active(st, k) || lord[k] == p || same_group(k, vassals.front())) continue;
			if (value_lost_to[p][k] > best) {
				best = value_lost_to[p][k];
				conqueror = k;
			}
		}
		if (conqueror >= 0 && vassal(conqueror)) conqueror = lord[conqueror];
		for (int v : vassals) lord[v] = -1;
		if (conqueror < 0) return; // free again, still with their allies
		// They follow one another: the first takes the others along.
		for (int v : vassals) lord[v] = vassals.front();
		lord[vassals.front()] = -1;
		make_vassal(st, vassals.front(), conqueror);
		push_event(st, event_vassal_moved, vassals.front(), conqueror);
	}

	// A unit died (OpenBW's on_kill_unit): credit whoever attacked it last.
	void on_kill(const unit_t* u) {
		int victim = u->owner, killer = u->last_attacking_player;
		if (victim < 0 || victim >= max_players) return;
		if (u->unit_type->id == UnitTypes::Zerg_Larva || u->unit_type->id == UnitTypes::Zerg_Egg) return;
		bool building = (u->unit_type->group_flags & GroupFlags::Building) != 0;
		if (!building) ++units_lost[victim];
		else ++buildings_lost[victim];
		if (killer < 0 || killer >= max_players || killer == victim) return;
		int score = u->unit_type->destroy_score;
		if (building) kill_buildings_score[killer] += score;
		else kill_units_score[killer] += score;
		// A vassal's tribute: half to its lord.
		if (vassal(killer)) {
			kill_score[lord[killer]] += score - score / 2;
			score /= 2;
		}
		kill_score[killer] += score;
		if (building) ++buildings_razed[killer];
		else ++units_killed[killer];
		int value = u->unit_type->mineral_cost + u->unit_type->gas_cost;
		value_lost_to[victim][killer] += value;
		recent_lost[victim][killer] += std::max(25, value);
	}

	// --- per frame ------------------------------------------------------------

	// Folds every sharer's spending and income since the last sync into its
	// treasury and hands everyone the result.
	void sync(state& st) {
		// Spending since the last sync: money that left the player's purse
		// beyond what it mined (refunds count back).
		for (int p = 0; p != max_players; ++p) {
			if (!playing[p]) continue;
			int gm = st.total_minerals_gathered[p] - spend_seen_minerals[p];
			int gg = st.total_gas_gathered[p] - spend_seen_gas[p];
			spend_seen_minerals[p] = st.total_minerals_gathered[p];
			spend_seen_gas[p] = st.total_gas_gathered[p];
			spent_minerals[p] += synced_minerals[p] + gm - st.current_minerals[p];
			spent_gas[p] += synced_gas[p] + gg - st.current_gas[p];
		}
		std::array<bool, max_players> done{};
		for (int p = 0; p != max_players; ++p) {
			if (!playing[p] || done[(size_t)p]) continue;
			a_vector<int> mates = pool(p);
			for (int q : mates) done[(size_t)q] = true;
			if (mates.size() < 2) {
				synced_minerals[p] = st.current_minerals[p];
				synced_gas[p] = st.current_gas[p];
				continue;
			}
			int m = synced_minerals[mates.front()], gas = synced_gas[mates.front()];
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

	// Mining points. Free members of a group are each credited with all the
	// free members mined; a vassal keeps half of its own mining and pays the
	// other half to its lord.
	void score(state& st) {
		std::array<int64_t, max_players> group_gain{};
		std::array<int64_t, max_players> gain{};
		for (int p = 0; p != max_players; ++p) {
			if (!playing[p]) continue;
			int total = st.total_minerals_gathered[p] + st.total_gas_gathered[p];
			gain[(size_t)p] = total - gathered_seen[p];
			gathered_seen[p] = total;
			own_points[p] += gain[(size_t)p];
			if (!vassal(p)) group_gain[(size_t)group[p]] += gain[(size_t)p];
		}
		for (int p = 0; p != max_players; ++p) {
			if (!active(st, p)) continue;
			if (vassal(p)) {
				int64_t g = gain[(size_t)p];
				points[p] += g / 2;
				points[lord[p]] += g - g / 2;
			} else {
				points[p] += group_gain[(size_t)group[p]];
			}
		}
	}

	// Once a second: army values, mining rates and who is fighting whom.
	void survey(state& st) {
		action_state scratch;
		action_functions f(st, scratch);
		std::array<a_vector<xy>, max_players> bases;
		for (int p = 0; p != max_players; ++p) {
			army_value[p] = workers[p] = 0;
			if (!playing[p]) continue;
			for (unit_t* u : ptr(st.player_units.at(p))) {
				if (f.unit_dead(u) || !u->sprite) continue;
				if (f.ut_building(u)) bases[(size_t)p].push_back(u->sprite->position);
				else if (f.ut_worker(u)) ++workers[p];
				else if (f.u_completed(u) && !f.ut_turret(u) && u->unit_type->id != UnitTypes::Zerg_Larva && u->unit_type->id != UnitTypes::Zerg_Egg &&
				         u->unit_type->id != UnitTypes::Zerg_Overlord && u->unit_type->id != UnitTypes::Protoss_Interceptor &&
				         u->unit_type->id != UnitTypes::Protoss_Scarab) {
					army_value[p] += u->unit_type->mineral_cost + u->unit_type->gas_cost;
				}
			}
		}
		// Mining rate over the last minute (less at the start of the game).
		int slot = samples % rate_window;
		int span = std::min(samples, rate_window - 1);
		for (int p = 0; p != max_players; ++p) {
			if (!playing[p]) continue;
			int m = st.total_minerals_gathered[p], g = st.total_gas_gathered[p];
			mineral_history[p][(size_t)slot] = m;
			gas_history[p][(size_t)slot] = g;
			int then = (samples - span) % rate_window;
			if (span > 0) {
				mineral_rate[p] = (m - mineral_history[p][(size_t)then]) * 60 / span;
				gas_rate[p] = (g - gas_history[p][(size_t)then]) * 60 / span;
			}
		}
		++samples;
		// Clashes: recent kills either way, or an army at the other's buildings.
		for (int a = 0; a != max_players; ++a) {
			fighting[a] = 0;
			for (int b = 0; b != max_players; ++b) recent_lost[a][b] = recent_lost[a][b] * 15 / 16;
		}
		for (int a = 0; a != max_players; ++a) {
			for (int b = 0; b != max_players; ++b) {
				if (a == b || !active(st, a) || !active(st, b) || same_group(a, b)) continue;
				if (recent_lost[a][b] + recent_lost[b][a] >= 40) {
					fighting[a] |= 1u << b;
					fighting[b] |= 1u << a;
				}
			}
		}
		for (int b = 0; b != max_players; ++b) {
			if (!active(st, b)) continue;
			for (unit_t* u : ptr(st.player_units.at(b))) {
				if (f.unit_dead(u) || !u->sprite || f.ut_building(u) || f.ut_worker(u) || !f.unit_can_attack(u)) continue;
				for (int a = 0; a != max_players; ++a) {
					if (a == b || !active(st, a) || same_group(a, b) || (fighting[a] & (1u << b))) continue;
					for (xy pos : bases[(size_t)a]) {
						if (dist2(pos, u->sprite->position) < 320 * 320) {
							fighting[a] |= 1u << b;
							fighting[b] |= 1u << a;
							break;
						}
					}
				}
			}
		}
	}

	static int dist2(xy a, xy b) {
		int dx = a.x - b.x, dy = a.y - b.y;
		return dx * dx + dy * dy;
	}

	void after_frame(state& st) {
		// A defeated player drops out of its group.
		for (int p = 0; p != max_players; ++p) {
			if (playing[p] && !active(st, p) && (members(group[p]).size() > 1 || lord[p] >= 0 || has_vassals(p))) drop(st, p);
		}
		sync(st);
		score(st);
		if (st.current_frame % 8 == 0) share_technology(st);
		if (st.current_frame % 24 == 0) survey(st);
	}

	bool has_vassals(int p) const {
		for (int m = 0; m != max_players; ++m) {
			if (lord[m] == p) return true;
		}
		return false;
	}
};

} // namespace bw_alliances

#endif // BW_ALLIANCES_H
