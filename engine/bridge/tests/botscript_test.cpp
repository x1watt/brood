/* engine/bridge/tests/botscript_test.cpp
 *
 * The bot profile language on its own (botscript.h): parsing, errors with
 * their place, arithmetic, control flow, functions, the step budget,
 * profiles extending others, tables, and the tunables scripts set. No game
 * data needed. */

#include "botscript.h"

#include <cstdio>
#include <cstdlib>
#include <dirent.h>
#include <fstream>
#include <sstream>
#include <sys/stat.h>

using namespace botscript;

static int failures = 0;
#define CHECK(cond, ...)                                       \
	do {                                                       \
		if (!(cond)) {                                         \
			std::printf("botscript_test: FAIL %s:%d: ", __FILE__, __LINE__); \
			std::printf(__VA_ARGS__);                          \
			std::printf("\n");                                 \
			++failures;                                        \
		}                                                      \
	} while (0)

struct test_host : host {
	int32_t g[max_globals]{};
	ai_tunables t;
	a_vector<std::string> calls;
	std::string warned;
	int32_t builtin(int id, const int32_t* a, int n) override {
		std::string c = builtins()[id].name;
		for (int i = 0; i != n; ++i) c += " " + std::to_string(a[i]);
		calls.push_back(c);
		switch (id) {
		case b_min: return std::min(a[0], a[1]);
		case b_max: return std::max(a[0], a[1]);
		case b_minerals: return 500;
		case b_time: return 300;
		default: return 0;
		}
	}
	int32_t* globals() override { return g; }
	ai_tunables& tunables() override { return t; }
	void warn(const char* m) override { warned = m; }
};

static std::shared_ptr<const profile> build(const bundle& b, const char* dir, std::string* message = nullptr) {
	std::string m;
	auto p = compile(b, dir, m);
	if (message) *message = m;
	else if (!p) std::printf("botscript_test: compile error: %s\n", m.c_str());
	return p;
}

static result call(const profile& p, const char* name, test_host& h, a_vector<int32_t> args = {}) {
	for (size_t i = 0; i != p.functions.size(); ++i) {
		if (p.functions[i].name == name) return run(p, (int)i, args.data(), (int)args.size(), h);
	}
	std::printf("botscript_test: no function %s\n", name);
	++failures;
	return {};
}

static void start(const profile& p, test_host& h) {
	for (int f : p.init) run(p, f, nullptr, 0, h);
}

static void expect_error(const char* text, const char* fragment) {
	std::string m;
	auto p = build({{"x/profile.bot", text}}, "x", &m);
	CHECK(!p, "expected an error containing '%s' for: %s", fragment, text);
	CHECK(m.find(fragment) != std::string::npos, "error '%s' lacks '%s'", m.c_str(), fragment);
}

// The .bot files under `root` (the repo's assets/bots), by relative path.
static void read_tree(const std::string& root, const std::string& rel, bundle& out) {
	DIR* d = opendir((root + "/" + rel).c_str());
	if (!d) return;
	while (dirent* e = readdir(d)) {
		std::string name = e->d_name;
		if (name == "." || name == "..") continue;
		std::string path = rel.empty() ? name : rel + "/" + name;
		struct stat st;
		if (stat((root + "/" + path).c_str(), &st) != 0) continue;
		if (S_ISDIR(st.st_mode)) {
			read_tree(root, path, out);
		} else if (path.size() > 4 && path.compare(path.size() - 4, 4, ".bot") == 0) {
			std::ifstream in(root + "/" + path);
			std::stringstream text;
			text << in.rdbuf();
			out[path] = text.str();
		}
	}
	closedir(d);
}

static bool same(const plan_step& a, const plan_step& b) { return a.type == b.type && a.count == b.count && a.supply == b.supply && a.where == b.where; }
static bool same(const research2_step& a, const research2_step& b) {
	return a.building == b.building && a.is_tech == b.is_tech && a.id == b.id && a.supply == b.supply && a.where == b.where;
}
static bool same(const mix_row& a, const mix_row& b) {
	return a.type == b.type && a.share == b.share && a.cap == b.cap && a.aa_mul == b.aa_mul && a.aa_div == b.aa_div && a.late == b.late &&
	       a.cloak == b.cloak && a.some_island == b.some_island;
}
template<typename T>
static bool same_rows(const a_vector<T>& a, const a_vector<T>& b) {
	if (a.size() != b.size()) return false;
	for (size_t i = 0; i != a.size(); ++i) {
		if (!same(a[i], b[i])) return false;
	}
	return true;
}

// The shipped profiles compile, and "standard" is exactly the built-in player.
static void shipped_profiles() {
#ifdef BOTS_DIR
	bundle files;
	read_tree(BOTS_DIR, "", files);
	CHECK(files.count("standard/profile.bot"), "no standard profile in %s", BOTS_DIR);
	for (auto& f : files) {
		size_t slash = f.first.find('/');
		if (f.first.substr(slash) != "/profile.bot") continue;
		std::string dir = f.first.substr(0, slash);
		std::string m;
		auto p = compile(files, dir, m);
		CHECK(p, "profile %s: %s", dir.c_str(), m.c_str());
		if (p) {
			test_host h;
			start(*p, h);
			CHECK(h.warned.empty(), "profile %s warns at the start: %s", dir.c_str(), h.warned.c_str());
		}
	}
	std::string m;
	auto p = compile(files, "standard", m);
	if (!p) return;
	test_host h;
	start(*p, h);
	ai_tunables defaults;
	CHECK(std::memcmp(&h.t, &defaults, sizeof(defaults)) == 0, "standard's numbers differ from the defaults");
	auto& names = bw_ai::tunable_names();
	for (auto& n : names) {
		int a = bw_ai::tunable_at(h.t, n.offset), b = bw_ai::tunable_at(defaults, n.offset);
		CHECK(a == b, "standard sets %s = %d, the default is %d", n.name, a, b);
	}
	ai_tables d;
	auto& t = p->tables[0];
	for (int r = 0; r != 3; ++r) {
		CHECK(t.plan[r] && same_rows(t.t.plan[r], d.plan[r]), "standard plan %d", r);
		CHECK(t.research[r] && same_rows(t.t.research[r], d.research[r]), "standard research %d", r);
		CHECK(t.mix_ground[r] && same_rows(t.t.mix_ground[r], d.mix_ground[r]), "standard ground mix %d", r);
		CHECK(t.mix_island[r] && same_rows(t.t.mix_island[r], d.mix_island[r]), "standard island mix %d", r);
	}
#endif
}

int main() {
	shipped_profiles();
	// Arithmetic, precedence, wrapping, division by zero.
	{
		auto p = build({{"x/profile.bot", R"(
			int f() { return 2 + 3 * 4 - 10 / 3 % 2; }
			int g() { return -(7 / 0) + 5 % 0 + (2147483647 + 1 < 0); }
			int h() { return 1 < 2 && 2 < 3 || 0; }
			int k() { return 0 && nope() || 4 > 3 ? 10 : 20; }
			int nope() { return 1 / 0; }
		)"}}, "x");
		CHECK(p, "compiles");
		if (p) {
			test_host h;
			CHECK(call(*p, "f", h).v == 13, "precedence");
			CHECK(call(*p, "g", h).v == 1, "wrap/div0");
			CHECK(call(*p, "h", h).v == 1, "logic");
			CHECK(call(*p, "k", h).v == 10, "ternary/short circuit");
		}
	}
	// Loops, break/continue, locals, functions, recursion, globals.
	{
		auto p = build({{"x/profile.bot", R"(
			var total = 5;
			int sum(int n) { int s = 0; for (int i = 1; i <= n; i++) { if (i % 2 == 0) continue; s += i; } return s; }
			int fact(int n) { if (n <= 1) return 1; return n * fact(n - 1); }
			int loop() { int i = 0; while (true) { i++; if (i == 7) break; } return i; }
			void bump() { total += 3; }
			int forever() { while (1) { } return 0; }
			int deep(int n) { return deep(n + 1); }
			on think { bump(); if (minerals >= 500) print(min(3, 9)); }
		)"}}, "x");
		CHECK(p, "compiles");
		if (p) {
			test_host h;
			start(*p, h);
			CHECK(h.g[0] == 5, "global init %d", h.g[0]);
			CHECK(call(*p, "sum", h, {10}).v == 25, "for/continue");
			CHECK(call(*p, "fact", h, {6}).v == 720, "recursion");
			CHECK(call(*p, "loop", h).v == 7, "while/break");
			result r = run(*p, p->handler[h_think], nullptr, 0, h);
			CHECK(r.ok && !r.value && h.g[0] == 8, "think ran (total %d)", h.g[0]);
			CHECK(!h.calls.empty() && h.calls.back() == "print 3", "builtin call: %s", h.calls.empty() ? "" : h.calls.back().c_str());
			r = call(*p, "forever", h);
			CHECK(!r.ok && h.warned.find("steps") != std::string::npos, "step budget");
			r = call(*p, "deep", h, {0});
			CHECK(!r.ok && h.warned.find("deep") != std::string::npos, "depth limit");
		}
	}
	// Handlers returning a value or none (the default decision).
	{
		auto p = build({{"x/profile.bot", R"(
			on invite(from) { if (from == 3) return true; if (from == 4) return false; }
		)"}}, "x");
		CHECK(p, "compiles");
		if (p) {
			test_host h;
			int32_t a = 3;
			result r = run(*p, p->handler[h_invite], &a, 1, h);
			CHECK(r.value && r.v == 1, "accept");
			a = 4;
			r = run(*p, p->handler[h_invite], &a, 1, h);
			CHECK(r.value && r.v == 0, "decline");
			a = 5;
			r = run(*p, p->handler[h_invite], &a, 1, h);
			CHECK(!r.value, "default");
		}
	}
	// Tunables: time in seconds, divisors kept positive.
	{
		auto p = build({{"x/profile.bot", R"(
			set army.wave_first = 6;
			set expansion.base1 = 8 * MINUTE;
			set army.wave_end_div = 0;
			int late() { return army.late_game; }
		)"}}, "x");
		CHECK(p, "compiles");
		if (p) {
			test_host h;
			start(*p, h);
			CHECK(h.t.army.wave_first == 6, "set");
			CHECK(h.t.expansion.base_times[0] == 24 * 60 * 8, "seconds to frames %d", h.t.expansion.base_times[0]);
			CHECK(h.t.army.wave_end_div == 1, "divisor kept positive");
			CHECK(call(*p, "late", h).v == 14 * 60, "frames to seconds");
		}
	}
	// Extends, include, overrides, tables and variants.
	{
		bundle b = {
			{"base/profile.bot", R"(
				profile "Base" { description "the base"; }
				include "lib/util.bot";
				const N = 2;
				int helper() { return 1; }
				int value() { return helper() * N; }
				plan terran { build terran_barracks 1 at 10; build terran_factory 1 at 14 island; }
				mix terran ground { terran_marine share 30; terran_goliath share 4 cap 30 aa 1/2 late 8; }
			)"},
			{"lib/util.bot", "int twice(int x) { return x * 2; }"},
			{"kid/profile.bot", R"(
				profile "Kid" { extends "base"; description "a kid"; }
				int helper() { return 5; }
				plan terran { build terran_barracks 3 at twice(5); }
				plan terran "late" { build terran_starport 2 at 40 ground; }
				research protoss { upgrade singularity_charge by protoss_cybernetics_core at 20 ground; tech psionic_storm by protoss_templar_archives at 48; }
				on think { use_plan("late"); }
			)"},
		};
		std::string m;
		auto p = build(b, "kid", &m);
		CHECK(!p && m.find("twice") != std::string::npos && m.find("constant") != std::string::npos, "a call is no constant: %s", m.c_str());
		b["kid/profile.bot"].replace(b["kid/profile.bot"].find("twice(5)"), 8, "5 * N");
		p = build(b, "kid");
		CHECK(p, "compiles");
		if (p) {
			test_host h;
			CHECK(p->name == "Kid" && p->description == "a kid", "metadata of the outer profile: %s", p->name.c_str());
			CHECK(p->files.size() == 3, "files %d", (int)p->files.size());
			CHECK(call(*p, "value", h).v == 10, "late binding of overridden helper");
			auto& t = p->tables[0];
			CHECK(t.plan[1] && t.t.plan[1].size() == 1 && t.t.plan[1][0].count == 3 && t.t.plan[1][0].supply == 10, "plan replaced");
			CHECK(t.mix_ground[1] && t.t.mix_ground[1].size() == 2 && t.t.mix_ground[1][1].aa_div == 2 && t.t.mix_ground[1][1].late == 8, "mix");
			CHECK(!t.plan[0] && !t.research[1], "untouched tables");
			CHECK(t.research[2] && t.t.research[2].size() == 2 && t.t.research[2][1].is_tech, "research");
			CHECK(p->variants.size() == 2 && p->variants[1] == "late" && p->tables[1].plan[1], "variant");
			result r = run(*p, p->handler[h_think], nullptr, 0, h);
			CHECK(r.ok && h.calls.back() == "use_plan 1", "variant name argument: %s", h.calls.back().c_str());
		}
	}
	// Errors name the place.
	expect_error("int f() { return 1 }", "profile.bot:1:20: expected ';'");
	expect_error("on think { x = 1; }", "unknown name 'x'");
	expect_error("on thinking { }", "no event 'thinking'");
	expect_error("on invite { }", "takes 1 parameter");
	expect_error("int f() { return g(); }", "g() is never defined");
	expect_error("set army.wave = 3;", "no number 'army.wave'");
	expect_error("set army.wave_max = minerals;", "means nothing at the start");
	expect_error("plan terran { build terran_marinez 1 at 3; }", "no unit type 'terran_marinez'");
	expect_error("const A = minerals;", "not a constant");
	expect_error("void f() { return 3; }", "returns no value");
	expect_error("on think { attack(1); }", "takes 0 argument");
	expect_error("on think { int a = attack(); }", "gives no value");
	expect_error("/* open", "comment never closed");
	expect_error("profile \"A\" { extends \"x\"; }", "extends itself");
	expect_error("include \"nothere.bot\";", "no file 'nothere.bot'");
	{
		std::string m;
		CHECK(!build({}, "none", &m) && m.find("no such profile") != std::string::npos, "missing profile: %s", m.c_str());
	}
	// The bundle format.
	{
		bundle b = parse_bundle("a/profile.bot\x1Fon think { }\x1E" "lib/x.bot\x1F" "const X = 1;\x1E");
		CHECK(b.size() == 2 && b["lib/x.bot"] == "const X = 1;", "bundle");
	}
	if (failures) {
		std::printf("botscript_test: %d failure(s)\n", failures);
		return 1;
	}
	std::printf("botscript_test: OK\n");
	return 0;
}
