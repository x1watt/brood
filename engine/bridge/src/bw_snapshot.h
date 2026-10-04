// engine/bridge/src/bw_snapshot.h
//
// Saved games as the game's state itself, so loading one is immediate
// instead of replaying every command from the start.
//
// The simulation keeps its objects (units, bullets, sprites, images, orders)
// in pools of fixed-size chunks, paths and thingies in lists of nodes, and
// links them with pointers. A snapshot stores:
//   - the plain part of the state, field by field;
//   - every pool chunk as raw bytes, and every path and thingy;
//   - where each memory region (pool chunks, path and thingy nodes, and the
//     game's data tables: unit, weapon, flingy, sprite, image and order
//     types, graphics, iscript scripts, map regions, triggers) was;
//   - every intrusive list as the indices of its members, in order.
// Loading starts the same map with the same setup (bw_bridge_new_game), gives
// the pools the same chunks, copies the bytes back, moves every known pointer
// field from its old region to the same offset in the new one (the way
// OpenBW's own state_copier remaps pointers between two states) and rebuilds
// the lists. Links of objects that aren't in a list are cleared: OpenBW tells
// membership by a non-null link.
//
// The bridge's own state follows: computer players, alliances, selections,
// control groups and the command log (later saves still carry the whole log).
//
// Snapshots only load into the same build on the same kind of machine (the
// header records the sizes of the structures); anything else is refused and
// the caller replays the command log instead.

#ifndef BW_SNAPSHOT_H
#define BW_SNAPSHOT_H

#include "bwgame.h"
#include "actions.h"
#include "bw_ai.h"
#include "bw_alliances.h"

#include <algorithm>
#include <cstring>
#include <type_traits>

namespace bw_snapshot {

using namespace bwgame;

static const uint32_t magic = 0x50534242; // "BBSP"
static const uint32_t format_version = 1;

struct writer {
	a_vector<uint8_t> out;
	void bytes(const void* p, size_t n) {
		const uint8_t* b = (const uint8_t*)p;
		out.insert(out.end(), b, b + n);
	}
	template<typename T>
	void pod(const T& v) {
		static_assert(std::is_trivially_copyable<T>::value, "plain data only");
		bytes(&v, sizeof(T));
	}
	template<typename T>
	void vec(const a_vector<T>& v) {
		pod((uint64_t)v.size());
		if (!v.empty()) bytes(v.data(), v.size() * sizeof(T));
	}
};

struct reader {
	const uint8_t* p;
	const uint8_t* end;
	bool ok = true;
	reader(const uint8_t* data, size_t n) : p(data), end(data + n) {}
	void bytes(void* dst, size_t n) {
		if (!ok || (size_t)(end - p) < n) {
			ok = false;
			if (n) std::memset(dst, 0, n);
			return;
		}
		std::memcpy(dst, p, n);
		p += n;
	}
	template<typename T>
	void pod(T& v) {
		static_assert(std::is_trivially_copyable<T>::value, "plain data only");
		bytes(&v, sizeof(T));
	}
	template<typename T>
	T get() {
		T v{};
		pod(v);
		return v;
	}
	size_t count(size_t limit = 1u << 26) {
		uint64_t n = get<uint64_t>();
		if (n > limit) ok = false;
		return ok ? (size_t)n : 0;
	}
	template<typename T>
	void vec(a_vector<T>& v) {
		size_t n = count();
		v.resize(n);
		if (n) bytes(v.data(), n * sizeof(T));
	}
};

// The memory regions pointers may point into, in a fixed order.
template<typename F>
void each_region(state& st, F&& f) {
	for (auto& c : st.units_container.list) f(c.data(), sizeof(c));
	for (auto& c : st.bullets_container.list) f(c.data(), sizeof(c));
	for (auto& c : st.sprites_container.list) f(c.data(), sizeof(c));
	for (auto& c : st.images_container.list) f(c.data(), sizeof(c));
	for (auto& c : st.orders_container.list) f(c.data(), sizeof(c));
	for (auto& v : st.paths) f(&v, sizeof(v));
	for (auto& v : st.thingies) f(&v, sizeof(v));
	auto table = [&](const auto& vec) {
		if (!vec.empty()) f(vec.data(), vec.size() * sizeof(vec[0]));
		else f(nullptr, 0);
	};
	const global_state& g = *st.global;
	table(g.flingy_types.vec);
	table(g.sprite_types.vec);
	table(g.image_types.vec);
	table(g.order_types.vec);
	table(g.grps);
	game_state& gs = *st.game;
	table(gs.unit_types.vec);
	table(gs.weapon_types.vec);
	table(gs.upgrade_types.vec);
	table(gs.tech_types.vec);
	table(gs.regions.regions);
	table(gs.triggers);
	// iscript scripts live in hash map nodes: by id.
	a_vector<std::pair<int, const iscript_t::script*>> scripts;
	for (auto& v : g.iscript.scripts) scripts.emplace_back(v.first, &v.second);
	std::sort(scripts.begin(), scripts.end(), [](auto& a, auto& b) { return a.first < b.first; });
	for (auto& v : scripts) f(v.second, sizeof(*v.second));
}

struct region {
	uintptr_t from;
	size_t size;
	uintptr_t to;
};

// Moves pointers from the saved state's regions to the new state's.
struct relocator {
	a_vector<region> regions; // sorted by `from`
	size_t misses = 0;
	template<typename T>
	void operator()(T*& p) {
		if (!p) return;
		uintptr_t a = (uintptr_t)p;
		auto i = std::upper_bound(regions.begin(), regions.end(), a, [](uintptr_t a, const region& r) { return a < r.from; });
		if (i != regions.begin()) {
			--i;
			if (a < i->from + i->size) {
				p = (T*)(i->to + (a - i->from));
				return;
			}
		}
		++misses;
		p = nullptr;
	}
};

// --- the plain part of the state -----------------------------------------------

using lurker_hits_t = decltype(state_base_copyable::recent_lurker_hits);

static void lurker_hits(writer& w, const lurker_hits_t& v) {
	for (auto& hits : v) {
		w.pod((uint64_t)hits.size());
		for (auto& h : hits) {
			w.pod((uint64_t)h.first);
			w.pod((uint64_t)h.second);
		}
	}
}

static void lurker_hits(reader& r, lurker_hits_t& v) {
	for (auto& hits : v) {
		size_t n = r.count(16);
		hits.clear();
		for (size_t i = 0; i != n; ++i) {
			size_t a = (size_t)r.get<uint64_t>(), b = (size_t)r.get<uint64_t>();
			hits.emplace_back(a, b);
		}
	}
}

template<typename io_T>
void copyable_pod(io_T& io, state_base_copyable& c) {
	io.pod(c.update_tiles_countdown);
	io.pod(c.order_timer_counter);
	io.pod(c.secondary_order_timer_counter);
	io.pod(c.current_frame);
	io.pod(c.players);
	io.pod(c.alliances);
	io.pod(c.upgrade_levels);
	io.pod(c.upgrade_upgrading);
	io.pod(c.tech_researched);
	io.pod(c.tech_researching);
	io.pod(c.unit_counts);
	io.pod(c.completed_unit_counts);
	io.pod(c.factory_counts);
	io.pod(c.building_counts);
	io.pod(c.non_building_counts);
	io.pod(c.completed_factory_counts);
	io.pod(c.completed_building_counts);
	io.pod(c.completed_non_building_counts);
	io.pod(c.total_buildings_ever_completed);
	io.pod(c.total_non_buildings_ever_completed);
	io.pod(c.unit_score);
	io.pod(c.building_score);
	io.pod(c.supply_used);
	io.pod(c.supply_available);
	io.pod(c.shared_vision);
	io.vec(c.tiles);
	io.vec(c.tiles_mega_tile_index);
	io.pod(c.random_counts);
	io.pod(c.total_random_counts);
	io.pod(c.lcg_rand_state);
	io.pod(c.last_error);
	io.pod(c.trigger_timer);
	io.pod(c.trigger_wait_timers);
	io.pod(c.trigger_waiting);
	io.pod(c.active_orders_size);
	io.pod(c.active_bullets_size);
	io.pod(c.active_thingies_size);
	io.vec(c.repulse_field);
	io.pod(c.prev_bullet_heading_offset_clockwise);
	io.pod(c.current_minerals);
	io.pod(c.current_gas);
	io.pod(c.total_minerals_gathered);
	io.pod(c.total_gas_gathered);
	lurker_hits(io, c.recent_lurker_hits);
	io.pod(c.recent_lurker_hit_current_index);
	io.pod(c.update_psionic_matrix);
	io.pod(c.disruption_webbed_units);
	io.pod(c.cheats_enabled);
	io.pod(c.cheat_operation_cwal);
	io.vec(c.locations);
}

// Which lists a unit heads (decided by its type, as OpenBW's state_copier does).
struct unit_lists {
	bool fighters = false; // carrier or reaver: inside and outside units
	bool gatherers = false; // resource: workers waiting to gather
};

static unit_lists lists_of(state_functions& f, const unit_t* u) {
	unit_lists l;
	if (!u->unit_type) return l;
	if (f.unit_is_carrier(u) || f.unit_is_reaver(u)) l.fighters = true;
	if (f.ut_resource(u)) l.gatherers = true;
	return l;
}

// --- saving ---------------------------------------------------------------------

struct header {
	uint32_t magic, version;
	uint32_t pointer_size;
	uint32_t sizes[12];
};

static header make_header() {
	header h{};
	h.magic = magic;
	h.version = format_version;
	h.pointer_size = sizeof(void*);
	uint32_t s[12] = {(uint32_t)sizeof(unit_t), (uint32_t)sizeof(bullet_t), (uint32_t)sizeof(sprite_t), (uint32_t)sizeof(image_t),
	                  (uint32_t)sizeof(order_t), (uint32_t)sizeof(thingy_t), (uint32_t)sizeof(path_t), (uint32_t)sizeof(state_base_copyable),
	                  (uint32_t)sizeof(bw_ai::player_state), (uint32_t)sizeof(bw_alliances::alliance_state), (uint32_t)max_units,
	                  (uint32_t)max_selection};
	std::memcpy(h.sizes, s, sizeof(s));
	return h;
}

struct bridge_parts {
	action_state* action_st;
	std::array<std::array<a_vector<unit_id>, 10>, 8>* groups;
	bw_ai::ai_system* ai;
	bw_alliances::alliance_system* alliances;
	std::array<int, 12>* outcome;
	a_vector<int32_t>* cmd_log;
	bool* legacy_ids;
	bool* alliances_on;
};

static void save(state& st, const bridge_parts& b, writer& w) {
	state_functions f(st);
	w.pod(make_header());
	// Sizes of the pools and lists.
	w.pod((uint64_t)st.units_container.size);
	w.pod((uint64_t)st.bullets_container.size);
	w.pod((uint64_t)st.sprites_container.size);
	w.pod((uint64_t)st.images_container.size);
	w.pod((uint64_t)st.orders_container.size);
	w.pod((uint64_t)st.paths.size());
	w.pod((uint64_t)st.thingies.size());
	// Where every region was.
	a_vector<uintptr_t> bases;
	each_region(st, [&](const void* p, size_t n) { bases.push_back((uintptr_t)p); });
	w.pod((uint64_t)bases.size());
	for (uintptr_t a : bases) w.pod((uint64_t)a);

	copyable_pod(w, st);
	// Running triggers point at triggers: by index.
	for (auto& list : st.running_triggers) {
		w.pod((uint64_t)list.size());
		for (auto& t : list) {
			w.pod(t.actions);
			w.pod((int64_t)(t.t ? t.t - st.game->triggers.data() : -1));
			w.pod(t.flags);
			w.pod((uint64_t)t.current_action_index);
		}
	}

	// The pools, raw.
	for (auto& c : st.units_container.list) w.bytes(c.data(), sizeof(c));
	for (auto& c : st.bullets_container.list) w.bytes(c.data(), sizeof(c));
	for (auto& c : st.sprites_container.list) w.bytes(c.data(), sizeof(c));
	for (auto& c : st.images_container.list) w.bytes(c.data(), sizeof(c));
	for (auto& c : st.orders_container.list) w.bytes(c.data(), sizeof(c));
	for (auto& t : st.thingies) w.bytes(&t, sizeof(t));
	// Build queues point into themselves (static_vector): by type.
	for (auto& c : st.units_container.list) {
		for (auto& u : c) {
			for (auto* q : {&u.build_queue, &u.build_queue_limbo}) {
				w.pod((uint64_t)q->size());
				for (auto* t : *q) w.pod((int32_t)t->id);
			}
		}
	}

	// Paths (they hold vectors).
	for (auto& p : st.paths) {
		w.pod(p.delay);
		w.pod(p.creation_frame);
		w.pod(p.state_flags);
		w.pod((uint64_t)p.long_path.size());
		for (auto* r : p.long_path) w.pod((uint64_t)(uintptr_t)r);
		w.pod((uint64_t)p.full_long_path_size);
		w.pod((uint64_t)p.short_path.size());
		for (auto& v : p.short_path) w.pod(v);
		w.pod((uint64_t)p.current_long_path_index);
		w.pod((uint64_t)p.current_short_path_index);
		w.pod(p.source);
		w.pod(p.destination);
		w.pod(p.next);
		w.pod(p.last_collision_unit);
		w.pod(p.last_collision_speed);
		w.pod(p.slide_free_direction);
	}

	// Lists, as indices.
	auto list = [&](const auto& l, auto&& index) {
		uint64_t n = 0;
		for (auto& v : l) {
			(void)v;
			++n;
		}
		w.pod(n);
		for (auto& v : l) w.pod((uint64_t)index(&v));
	};
	auto by_index = [](const auto* v) { return v->index; };
	a_unordered_map<const void*, size_t> ordinal;
	{
		size_t i = 0;
		for (auto& v : st.paths) ordinal[&v] = i++;
		i = 0;
		for (auto& v : st.thingies) ordinal[&v] = i++;
	}
	auto by_ordinal = [&](const void* v) { return ordinal.at(v); };

	list(st.visible_units, by_index);
	list(st.hidden_units, by_index);
	list(st.map_revealer_units, by_index);
	list(st.dead_units, by_index);
	for (auto& l : st.player_units) list(l, by_index);
	list(st.cloaked_units, by_index);
	list(st.psionic_matrix_units, by_index);
	list(st.units_container.free_list, by_index);
	list(st.active_bullets, by_index);
	list(st.bullets_container.free_list, by_index);
	w.pod((uint64_t)st.sprites_on_tile_line.size());
	for (auto& l : st.sprites_on_tile_line) list(l, by_index);
	list(st.sprites_container.free_list, by_index);
	list(st.images_container.free_list, by_index);
	list(st.orders_container.free_list, by_index);
	list(st.free_paths, by_ordinal);
	list(st.active_thingies, by_ordinal);
	list(st.free_thingies, by_ordinal);
	// Lists inside units and sprites.
	auto each_unit = [&](auto&& fn) {
		for (auto& c : st.units_container.list) {
			for (auto& u : c) fn(&u);
		}
	};
	each_unit([&](unit_t* u) {
		list(u->order_queue, by_index);
		unit_lists l = lists_of(f, u);
		if (l.fighters) {
			list(u->carrier.inside_units, by_index);
			list(u->carrier.outside_units, by_index);
		}
		if (l.gatherers) list(u->building.resource.gather_queue, by_index);
	});
	for (auto& c : st.sprites_container.list) {
		for (auto& s : c) list(s.images, by_index);
	}
	// The unit finder and two loose pointers.
	auto unit_ref = [](const unit_t* u) { return u ? (int64_t)u->index : (int64_t)-1; };
	for (auto* v : {&st.unit_finder_x, &st.unit_finder_y}) {
		w.pod((uint64_t)v->size());
		for (auto& e : *v) {
			w.pod(unit_ref(e.u));
			w.pod(e.value);
		}
	}
	w.pod(unit_ref(st.consider_collision_with_unit_bug));
	w.pod(unit_ref(st.prev_bullet_source_unit));

	// Creep: its entries, and its lists by entry index.
	auto& cl = st.creep_life;
	w.pod(cl.recede_timer);
	w.pod(cl.check_dead_unit_timer);
	w.pod((uint64_t)cl.entry_container.size());
	for (auto& e : cl.entry_container) {
		w.pod(e.tile_pos);
		w.pod((uint64_t)e.n_neighboring_creep_tiles);
	}
	auto by_entry = [&](const auto* e) { return (size_t)(e - cl.entry_container.data()); };
	for (auto& l : cl.lists) list(l, by_entry);
	w.pod(cl.lists_size);
	list(cl.free_list, by_entry);
	w.pod((uint64_t)cl.free_list_size);
	for (auto& l : cl.table.buckets) list(l, by_entry);

	// --- the bridge ---
	auto& a = *b.action_st;
	w.pod(a.player_id);
	w.pod((uint64_t)a.actions_data_position);
	w.pod(a.next_action_frame);
	for (auto& sel : a.selection) {
		w.pod((uint64_t)sel.size());
		for (unit_t* u : sel) w.pod(unit_ref(u));
	}
	for (auto& groups : a.control_groups) {
		for (auto& g : groups) {
			w.pod((uint64_t)g.size());
			for (auto& id : g) w.pod(id);
		}
	}
	for (auto& groups : *b.groups) {
		for (auto& g : groups) w.vec(g);
	}
	// Computer players.
	auto& ai = *b.ai;
	w.pod((uint64_t)ai.players.size());
	for (auto& p : ai.players) {
		w.pod((const bw_ai::player_state&)p);
		w.vec(p.detached);
		w.pod((uint64_t)p.drops.size());
		for (auto& d : p.drops) {
			w.pod(d.transport);
			w.vec(d.passengers);
			w.pod(d.landing);
			w.pod(d.target);
			w.pod(d.phase);
			w.pod(d.started);
			w.pod(d.last_order);
			w.pod(d.expand);
		}
	}
	w.vec(ai.sites);
	w.pod(ai.sites_ready);
	w.vec(ai.human_frame);
	w.pod(ai.version);
	w.vec(ai.cast_frame);
	// Alliances, outcomes, the log.
	w.pod((const bw_alliances::alliance_state&)*b.alliances);
	w.pod(*b.outcome);
	w.vec(*b.cmd_log);
	w.pod(*b.legacy_ids);
	w.pod(*b.alliances_on);
}

// --- loading ---------------------------------------------------------------------

// Returns an error message, or null. `st` must be a fresh game of the same
// map and setup. On failure the game is left unusable: the caller starts it
// again and replays the log.
static const char* load(state& st, const bridge_parts& b, const uint8_t* data, size_t len) {
	state_functions f(st);
	reader r(data, len);
	header want = make_header(), h{};
	r.pod(h);
	if (!r.ok || h.magic != magic) return "not a snapshot";
	if (std::memcmp(&h, &want, sizeof(h)) != 0) return "made by another build";

	auto grow = [&](auto& c, size_t n) {
		while (c.size < n) c.grow(false);
		return c.size == n;
	};
	size_t n_units = r.count(), n_bullets = r.count(), n_sprites = r.count(), n_images = r.count(), n_orders = r.count();
	size_t n_paths = r.count(), n_thingies = r.count();
	if (!r.ok) return "truncated";
	if (!grow(st.units_container, n_units) || !grow(st.bullets_container, n_bullets) || !grow(st.sprites_container, n_sprites) ||
	    !grow(st.images_container, n_images) || !grow(st.orders_container, n_orders))
		return "pools larger than saved";
	if (st.paths.size() > n_paths || st.thingies.size() > n_thingies) return "lists larger than saved";
	while (st.paths.size() < n_paths) st.paths.emplace_back();
	while (st.thingies.size() < n_thingies) st.thingies.emplace_back();

	relocator reloc;
	{
		size_t n = r.count();
		a_vector<std::pair<uintptr_t, size_t>> now;
		each_region(st, [&](const void* p, size_t size) { now.emplace_back((uintptr_t)p, size); });
		if (n != now.size()) return "different regions";
		for (size_t i = 0; i != n; ++i) {
			uintptr_t from = (uintptr_t)r.get<uint64_t>();
			if (now[i].second) reloc.regions.push_back({from, now[i].second, now[i].first});
		}
		std::sort(reloc.regions.begin(), reloc.regions.end(), [](auto& a, auto& b) { return a.from < b.from; });
	}

	copyable_pod(r, st);
	for (auto& list : st.running_triggers) {
		size_t n = r.count();
		list.resize(n);
		for (auto& t : list) {
			r.pod(t.actions);
			int64_t i = r.get<int64_t>();
			t.t = i >= 0 && (size_t)i < st.game->triggers.size() ? &st.game->triggers[(size_t)i] : nullptr;
			r.pod(t.flags);
			t.current_action_index = (size_t)r.get<uint64_t>();
		}
	}

	for (auto& c : st.units_container.list) r.bytes(c.data(), sizeof(c));
	for (auto& c : st.bullets_container.list) r.bytes(c.data(), sizeof(c));
	for (auto& c : st.sprites_container.list) r.bytes(c.data(), sizeof(c));
	for (auto& c : st.images_container.list) r.bytes(c.data(), sizeof(c));
	for (auto& c : st.orders_container.list) r.bytes(c.data(), sizeof(c));
	for (auto& t : st.thingies) r.bytes(&t, sizeof(t));
	for (auto& c : st.units_container.list) {
		for (auto& u : c) {
			for (auto* q : {&u.build_queue, &u.build_queue_limbo}) {
				new (q) std::remove_pointer_t<decltype(q)>();
				size_t n = r.count(5);
				for (size_t i = 0; i != n; ++i) {
					int32_t id = r.get<int32_t>();
					if (id < 0 || id >= (int32_t)UnitTypes::None) return "bad unit type";
					q->push_back(f.get_unit_type((UnitTypes)id));
				}
			}
		}
	}
	if (!r.ok) return "truncated";

	// Pointers to their new places; links cleared (lists are rebuilt below).
	auto clear_link = [](auto& link) { link = {}; };
	for (auto& c : st.units_container.list) {
		for (auto& u : c) {
			clear_link(u.link);
			reloc(u.sprite);
			reloc(u.move_target.unit);
			reloc(u.flingy_type);
			reloc(u.order_type);
			reloc(u.order_unit_type);
			reloc(u.order_target.unit);
			reloc(u.unit_type);
			clear_link(u.player_units_link);
			reloc(u.subunit);
			reloc(u.auto_target_unit);
			reloc(u.connected_unit);
			reloc(u.previous_unit_type);
			reloc(u.secondary_order_type);
			reloc(u.worker.powerup);
			reloc(u.worker.target_resource_unit);
			reloc(u.worker.gather_target);
			clear_link(u.worker.gather_link);
			reloc(u.building.addon);
			reloc(u.building.addon_build_type);
			reloc(u.building.researching_type);
			reloc(u.building.upgrading_type);
			reloc(u.building.rally.unit);
			reloc(u.current_build_unit);
			clear_link(u.cloaked_unit_link);
			reloc(u.path);
			reloc(u.irradiated_by);
			if (u.unit_type) {
				if (f.unit_is(&u, UnitTypes::Protoss_Interceptor) || f.unit_is(&u, UnitTypes::Protoss_Scarab)) {
					reloc(u.fighter.parent);
					clear_link(u.fighter.fighter_link);
				} else if (f.unit_is_ghost(&u)) {
					reloc(u.ghost.nuke_dot);
				}
				if (f.unit_is_nydus(&u)) {
					reloc(u.building.nydus.exit);
				} else if (f.unit_is(&u, UnitTypes::Terran_Nuclear_Silo)) {
					reloc(u.building.silo.nuke);
				} else if (f.unit_is(&u, UnitTypes::Protoss_Pylon)) {
					reloc(u.building.pylon.psi_field_sprite);
					clear_link(u.building.pylon.psionic_matrix_link);
				}
			}
		}
	}
	for (auto& c : st.bullets_container.list) {
		for (auto& v : c) {
			clear_link(v.link);
			reloc(v.sprite);
			reloc(v.move_target.unit);
			reloc(v.flingy_type);
			reloc(v.bullet_target);
			reloc(v.weapon_type);
			reloc(v.bullet_owner_unit);
			reloc(v.prev_bounce_unit);
		}
	}
	for (auto& c : st.sprites_container.list) {
		for (auto& v : c) {
			clear_link(v.link);
			reloc(v.sprite_type);
			reloc(v.main_image);
		}
	}
	for (auto& c : st.images_container.list) {
		for (auto& v : c) {
			clear_link(v.link);
			reloc(v.image_type);
			reloc(v.iscript_state.current_script);
			reloc(v.grp);
			reloc(v.sprite);
		}
	}
	for (auto& c : st.orders_container.list) {
		for (auto& v : c) {
			clear_link(v.link);
			reloc(v.order_type);
			reloc(v.target.unit);
			reloc(v.target.unit_type);
		}
	}
	for (auto& t : st.thingies) {
		clear_link(t.link);
		reloc(t.sprite);
	}

	for (auto& p : st.paths) {
		p.link = {};
		r.pod(p.delay);
		r.pod(p.creation_frame);
		r.pod(p.state_flags);
		size_t n = r.count(1 << 16);
		p.long_path.clear();
		for (size_t i = 0; i != n; ++i) {
			auto* region_ptr = (const regions_t::region*)(uintptr_t)r.get<uint64_t>();
			reloc(region_ptr);
			p.long_path.push_back(region_ptr);
		}
		p.full_long_path_size = (size_t)r.get<uint64_t>();
		n = r.count(1 << 16);
		p.short_path.clear();
		for (size_t i = 0; i != n; ++i) p.short_path.push_back(r.get<xy>());
		p.current_long_path_index = (size_t)r.get<uint64_t>();
		p.current_short_path_index = (size_t)r.get<uint64_t>();
		r.pod(p.source);
		r.pod(p.destination);
		r.pod(p.next);
		r.pod(p.last_collision_unit);
		r.pod(p.last_collision_speed);
		r.pod(p.slide_free_direction);
	}
	if (!r.ok) return "truncated";

	// Lists from indices.
	a_vector<path_t*> path_at;
	for (auto& p : st.paths) path_at.push_back(&p);
	a_vector<thingy_t*> thingy_at;
	for (auto& t : st.thingies) thingy_at.push_back(&t);
	bool bad = false;
	// Rebuilt in place: clear, then append (as OpenBW uses its lists).
	auto list = [&](auto& dst, auto&& get) {
		dst.clear();
		size_t n = r.count();
		for (size_t i = 0; i != n; ++i) {
			auto* v = get((size_t)r.get<uint64_t>());
			if (!v) {
				bad = true;
				continue;
			}
			dst.push_back(*v);
		}
	};
	auto unit_at = [&](size_t i) { return i < max_units ? st.units_container.try_get(i) : nullptr; };
	auto bullet_at = [&](size_t i) { return i < max_bullets ? st.bullets_container.try_get(i) : nullptr; };
	auto sprite_at = [&](size_t i) { return i < max_sprites ? st.sprites_container.try_get(i) : nullptr; };
	auto image_at = [&](size_t i) { return i < max_images ? st.images_container.try_get(i) : nullptr; };
	auto order_at = [&](size_t i) { return i < max_orders ? st.orders_container.try_get(i) : nullptr; };
	auto path_of = [&](size_t i) { return i < path_at.size() ? path_at[i] : nullptr; };
	auto thingy_of = [&](size_t i) { return i < thingy_at.size() ? thingy_at[i] : nullptr; };

	list(st.visible_units, unit_at);
	list(st.hidden_units, unit_at);
	list(st.map_revealer_units, unit_at);
	list(st.dead_units, unit_at);
	for (auto& l : st.player_units) list(l, unit_at);
	list(st.cloaked_units, unit_at);
	list(st.psionic_matrix_units, unit_at);
	list(st.units_container.free_list, unit_at);
	list(st.active_bullets, bullet_at);
	list(st.bullets_container.free_list, bullet_at);
	{
		size_t n = r.count();
		st.sprites_on_tile_line.resize(n);
		for (auto& l : st.sprites_on_tile_line) list(l, sprite_at);
	}
	list(st.sprites_container.free_list, sprite_at);
	list(st.images_container.free_list, image_at);
	list(st.orders_container.free_list, order_at);
	list(st.free_paths, path_of);
	list(st.active_thingies, thingy_of);
	list(st.free_thingies, thingy_of);
	for (auto& c : st.units_container.list) {
		for (auto& u : c) {
			list(u.order_queue, order_at);
			unit_lists l = lists_of(f, &u);
			if (l.fighters) {
				list(u.carrier.inside_units, unit_at);
				list(u.carrier.outside_units, unit_at);
			}
			if (l.gatherers) list(u.building.resource.gather_queue, unit_at);
		}
	}
	for (auto& c : st.sprites_container.list) {
		for (auto& s : c) list(s.images, image_at);
	}
	auto unit_ref = [&](int64_t i) -> unit_t* { return i < 0 ? nullptr : unit_at((size_t)i); };
	for (auto* v : {&st.unit_finder_x, &st.unit_finder_y}) {
		size_t n = r.count();
		v->resize(n);
		for (auto& e : *v) {
			e.u = unit_ref(r.get<int64_t>());
			r.pod(e.value);
		}
	}
	st.consider_collision_with_unit_bug = unit_ref(r.get<int64_t>());
	st.prev_bullet_source_unit = unit_ref(r.get<int64_t>());

	auto& cl = st.creep_life;
	r.pod(cl.recede_timer);
	r.pod(cl.check_dead_unit_timer);
	{
		size_t n = r.count(1 << 20);
		cl.entry_container.resize(n);
		for (auto& e : cl.entry_container) {
			e.hash_link = {};
			e.list_link = {};
			r.pod(e.tile_pos);
			e.n_neighboring_creep_tiles = (size_t)r.get<uint64_t>();
		}
	}
	auto entry_at = [&](size_t i) { return i < cl.entry_container.size() ? &cl.entry_container[i] : nullptr; };
	for (auto& l : cl.lists) list(l, entry_at);
	r.pod(cl.lists_size);
	list(cl.free_list, entry_at);
	cl.free_list_size = (size_t)r.get<uint64_t>();
	for (auto& l : cl.table.buckets) list(l, entry_at);
	if (!r.ok) return "truncated";
	if (bad) return "list member missing";
	if (reloc.misses) return "pointer outside every region";

	// --- the bridge ---
	auto& a = *b.action_st;
	r.pod(a.player_id);
	a.actions_data_position = (size_t)r.get<uint64_t>();
	r.pod(a.next_action_frame);
	for (auto& sel : a.selection) {
		size_t n = r.count(max_selection);
		sel.clear();
		for (size_t i = 0; i != n; ++i) {
			if (unit_t* u = unit_ref(r.get<int64_t>())) sel.push_back(u);
		}
	}
	for (auto& groups : a.control_groups) {
		for (auto& g : groups) {
			size_t n = r.count(max_selection);
			g.clear();
			for (size_t i = 0; i != n; ++i) g.push_back(r.get<unit_id>());
		}
	}
	for (auto& groups : *b.groups) {
		for (auto& g : groups) r.vec(g);
	}
	auto& ai = *b.ai;
	{
		size_t n = r.count(64);
		ai.players.clear();
		ai.players.resize(n);
		for (auto& p : ai.players) {
			r.pod((bw_ai::player_state&)p);
			r.vec(p.detached);
			size_t nd = r.count(64);
			p.drops.resize(nd);
			for (auto& d : p.drops) {
				r.pod(d.transport);
				r.vec(d.passengers);
				r.pod(d.landing);
				r.pod(d.target);
				r.pod(d.phase);
				r.pod(d.started);
				r.pod(d.last_order);
				r.pod(d.expand);
			}
		}
	}
	r.vec(ai.sites);
	r.pod(ai.sites_ready);
	r.vec(ai.human_frame);
	r.pod(ai.version);
	r.vec(ai.cast_frame);
	r.pod((bw_alliances::alliance_state&)*b.alliances);
	b.alliances->events.clear();
	r.pod(*b.outcome);
	r.vec(*b.cmd_log);
	r.pod(*b.legacy_ids);
	r.pod(*b.alliances_on);
	if (!r.ok) return "truncated";
	if (r.p != r.end) return "extra data";
	return nullptr;
}

} // namespace bw_snapshot

#endif // BW_SNAPSHOT_H
