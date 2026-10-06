// engine/bridge/src/botscript.h
//
// BotScript: the small C-like language of bot profiles (docs/bot_profiles.md).
// A profile is a folder of text files; profile.bot is its entry. This file
// compiles a profile into a table set (build and research plans, the
// army's mix), the code of its functions and event handlers, and runs that
// code on a little stack machine.
//
// Everything is a 32-bit integer (true is 1), arithmetic wraps, a division
// by zero gives 0, and every run has a step budget: the computer players
// must decide the same on every machine, and a script can never hang the
// game. Compiling stops at the first error, reported as file:line:col.
//
// The machine knows nothing about the game: builtins (facts and actions)
// are numbered here and answered by the host (bw_ai.h).

#ifndef BOTSCRIPT_H
#define BOTSCRIPT_H

#include "bw_ai_params.h"
#include "botscript_names.h"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace botscript {

using bw_ai::ai_tables;
using bw_ai::ai_tunables;
using bw_ai::mix_row;
using bw_ai::plan_step;
using bw_ai::research2_step;
using bwgame::UnitTypes;
using bwgame::a_vector;

// --- builtins ---------------------------------------------------------------------

// name, arguments, flags. Facts with no arguments can be written without
// parentheses ("minerals" or "minerals()").
enum : int {
	f_value = 1,  // gives a value
	f_bare = 2,   // may be written without parentheses
	f_init = 4,   // meaningful at the start (in set and var initializers)
	f_name = 8,   // its argument is a plan or mix name (a string)
};

#define BOTSCRIPT_BUILTINS(X)                                                                                                      \
	X(time, 0, f_value | f_bare | f_init)                                                                                         \
	X(frame, 0, f_value | f_bare | f_init)                                                                                        \
	X(me, 0, f_value | f_bare | f_init)                                                                                           \
	X(race, 0, f_value | f_bare | f_init)                                                                                         \
	X(trust, 0, f_value | f_bare)                                                                                        \
	X(minerals, 0, f_value | f_bare)                                                                                              \
	X(gas, 0, f_value | f_bare)                                                                                                   \
	X(supply, 0, f_value | f_bare)                                                                                                \
	X(supply_max, 0, f_value | f_bare)                                                                                            \
	X(workers, 0, f_value | f_bare)                                                                                               \
	X(bases, 0, f_value | f_bare)                                                                                                 \
	X(army, 0, f_value | f_bare)                                                                                                  \
	X(army_value, 0, f_value | f_bare)                                                                                            \
	X(wave_size, 0, f_value | f_bare)                                                                                             \
	X(attacking, 0, f_value | f_bare)                                                                                             \
	X(losing, 0, f_value | f_bare)                                                                                                \
	X(attacker, 0, f_value | f_bare)                                                                                              \
	X(island, 0, f_value | f_bare)                                                                                                \
	X(some_island, 0, f_value | f_bare)                                                                                           \
	X(enemy_air, 0, f_value | f_bare)                                                                                             \
	X(enemy_cloaked, 0, f_value | f_bare)                                                                                         \
	X(defensive, 0, f_value | f_bare)                                                                                             \
	X(count, 1, f_value)                                                                                                          \
	X(done, 1, f_value)                                                                                                           \
	X(researched, 1, f_value)                                                                                                     \
	X(upgrade_level, 1, f_value)                                                                                                  \
	X(alive, 1, f_value)                                                                                                          \
	X(human, 1, f_value)                                                                                                          \
	X(ally, 1, f_value)                                                                                                           \
	X(enemy, 1, f_value)                                                                                                          \
	X(race_of, 1, f_value)                                                                                                        \
	X(army_of, 1, f_value)                                                                                                        \
	X(economy_of, 1, f_value)                                                                                                     \
	X(strength, 1, f_value)                                                                                                       \
	X(utility, 1, f_value)                                                                                                        \
	X(distance, 1, f_value)                                                                                                       \
	X(mining, 1, f_value)                                                                                                         \
	X(lost_to, 1, f_value)                                                                                                        \
	X(group_size, 1, f_value)                                                                                                     \
	X(vassal, 1, f_value)                                                                                                         \
	X(lord, 1, f_value)                                                                                                           \
	X(random, 2, f_value | f_init)                                                                                                \
	X(min, 2, f_value | f_init)                                                                                                   \
	X(max, 2, f_value | f_init)                                                                                                   \
	X(abs, 1, f_value | f_init)                                                                                                   \
	X(clamp, 3, f_value | f_init)                                                                                                 \
	X(attack, 0, 0)                                                                                                               \
	X(retreat, 0, 0)                                                                                                              \
	X(set_wave, 1, 0)                                                                                                        \
	X(focus, 1, 0)                                                                                                                \
	X(invite, 1, 0)                                                                                                               \
	X(leave, 0, 0)                                                                                                                \
	X(surrender_to, 1, 0)                                                                                                         \
	X(set_open, 1, 0)                                                                                                             \
	X(use_plan, 1, f_name | f_init)                                                                                               \
	X(use_research, 1, f_name | f_init)                                                                                           \
	X(use_mix, 1, f_name | f_init)                                                                                                \
	X(print, 1, f_init)

enum builtin_id : int {
#define BOTSCRIPT_ID(name, argc, flags) b_##name,
	BOTSCRIPT_BUILTINS(BOTSCRIPT_ID)
#undef BOTSCRIPT_ID
	builtin_count
};

struct builtin_info {
	const char* name;
	int argc;
	int flags;
};

inline const builtin_info* builtins() {
	static const builtin_info table[] = {
#define BOTSCRIPT_INFO(name, argc, flags) {#name, argc, flags},
		BOTSCRIPT_BUILTINS(BOTSCRIPT_INFO)
#undef BOTSCRIPT_INFO
	};
	return table;
}

// Event handlers: name and parameters.
enum handler_id : int {
	h_think,           // every decision (about twice a second)
	h_invite,          // (from) answer an invitation: return true/false
	h_surrender_offer, // (from, tribute, conquest) accept a surrender
	h_surrender,       // (to) offer our surrender (losing at home)
	h_betray,          // (ally) turn on a weaker ally
	h_wave,            // (ready) send the next attack wave
	h_ally_attacked,   // (ally) send help (defensive mode)
	handler_count
};

inline const builtin_info* handlers() {
	static const builtin_info table[] = {
		{"think", 0, 0}, {"invite", 1, 0}, {"surrender_offer", 3, 0}, {"surrender", 1, 0},
		{"betray", 1, 0}, {"wave", 1, 0}, {"ally_attacked", 1, 0},
	};
	return table;
}

static const int max_globals = 64;
static const int step_budget = 100000;

// --- the compiled profile ---------------------------------------------------------

enum op : int32_t {
	op_push,  // value
	op_pop,
	op_ldl,   // local
	op_stl,   // local
	op_ldg,   // global
	op_stg,   // global
	op_ldp,   // tunable index
	op_stp,   // tunable index
	op_add, op_sub, op_mul, op_div, op_mod,
	op_neg, op_not,
	op_eq, op_ne, op_lt, op_le, op_gt, op_ge,
	op_jmp,   // target
	op_jz,    // target
	op_call,  // function, argc
	op_callb, // builtin, argc
	op_ret,   // with the value on the stack
	op_retv,  // without a value
};

struct function {
	std::string name;
	int params = 0;
	int locals = 0;
	int entry = -1;
	bool value = false; // declared int/bool (not void)
	std::string first_use; // where it was first called, for "never defined"
};

struct profile {
	std::string name, description, author;
	a_vector<std::string> files; // every file it was compiled from

	// Plan, research and mix tables by variant (0: the unnamed one) and
	// race; a missing table falls back to variant 0, then to the defaults.
	a_vector<std::string> variants{""};
	struct variant_tables {
		std::array<bool, 3> plan{}, research{}, mix_ground{}, mix_island{};
		ai_tables t;
	};
	a_vector<variant_tables> tables{variant_tables()};

	a_vector<int32_t> code;
	a_vector<function> functions;
	a_vector<int> init; // functions run in order when a player starts
	std::array<int, handler_count> handler;
	a_vector<std::string> globals;

	profile() { handler.fill(-1); }

	bool has(handler_id h) const { return handler[(size_t)h] >= 0; }
};

// --- the machine ------------------------------------------------------------------

struct host {
	virtual ~host() {}
	virtual int32_t builtin(int id, const int32_t* args, int n) = 0;
	virtual int32_t* globals() = 0;
	virtual ai_tunables& tunables() = 0;
	virtual void warn(const char* message) = 0;
};

struct result {
	bool ok = true;     // false: stopped (out of steps, too deep)
	bool value = false; // returned a value
	int32_t v = 0;
};

static inline int32_t wrap(int64_t v) {
	return (int32_t)(uint32_t)(uint64_t)v;
}

// Keeps divisors and moduli of the tunables at 1 or more, whatever a
// script sets.
inline void sanitize(ai_tunables& t) {
	int* positive[] = {
		&t.personality.trust_span, &t.economy.workers_per_refinery, &t.army.wave_end_div, &t.army.aa_per,
		&t.defense.air_per, &t.diplomacy.trust_div, &t.diplomacy.closeness_div, &t.diplomacy.tribute_army_div,
		&t.diplomacy.accept_noise, &t.diplomacy.invite_spread, &t.diplomacy.first_invite_spread,
	};
	for (int* v : positive) {
		if (*v < 1) *v = 1;
	}
}

// Runs function `fn` with `args`.
inline result run(const profile& pr, int fn, const int32_t* args, int argc, host& h) {
	result r;
	if (fn < 0 || (size_t)fn >= pr.functions.size()) return r;
	struct frame {
		int fn, pc, base;
	};
	static const int max_stack = 4096, max_depth = 64;
	int32_t stack[max_stack];
	int sp = 0;
	frame frames[max_depth];
	int depth = 0;
	const a_vector<int32_t>& code = pr.code;
	const auto& names = bw_ai::tunable_names();
	auto fail = [&](const char* why) {
		h.warn(why);
		r.ok = false;
		return r;
	};
	auto enter = [&](int f, int n) -> bool {
		const function& fd = pr.functions[(size_t)f];
		if (depth == max_depth) return false;
		if (sp + fd.locals - n + 16 > max_stack) return false;
		frames[depth++] = {f, fd.entry, sp - n};
		for (int i = n; i < fd.locals; ++i) stack[sp++] = 0;
		return true;
	};
	for (int i = 0; i != argc; ++i) stack[sp++] = args[i];
	if (!enter(fn, argc)) return fail("too deep");
	int steps = 0;
	int32_t* g = h.globals();
	while (true) {
		if (++steps > step_budget) return fail("ran out of steps (an endless loop?)");
		frame& fr = frames[depth - 1];
		int32_t o = code[(size_t)fr.pc++];
		switch (o) {
		case op_push: stack[sp++] = code[(size_t)fr.pc++]; break;
		case op_pop: --sp; break;
		case op_ldl: stack[sp++] = stack[fr.base + code[(size_t)fr.pc++]]; break;
		case op_stl: stack[fr.base + code[(size_t)fr.pc++]] = stack[--sp]; break;
		case op_ldg: stack[sp++] = g[code[(size_t)fr.pc++]]; break;
		case op_stg: g[code[(size_t)fr.pc++]] = stack[--sp]; break;
		case op_ldp: {
			auto& t = names[(size_t)code[(size_t)fr.pc++]];
			stack[sp++] = bw_ai::tunable_at(h.tunables(), t.offset) / t.scale;
			break;
		}
		case op_stp: {
			auto& t = names[(size_t)code[(size_t)fr.pc++]];
			bw_ai::tunable_at(h.tunables(), t.offset) = wrap((int64_t)stack[--sp] * t.scale);
			sanitize(h.tunables());
			break;
		}
		case op_neg: stack[sp - 1] = wrap(-(int64_t)stack[sp - 1]); break;
		case op_not: stack[sp - 1] = !stack[sp - 1]; break;
		case op_jmp: fr.pc = code[(size_t)fr.pc]; break;
		case op_jz: {
			int32_t target = code[(size_t)fr.pc++];
			if (!stack[--sp]) fr.pc = target;
			break;
		}
		case op_call: {
			int f = code[(size_t)fr.pc++], n = code[(size_t)fr.pc++];
			if (!enter(f, n)) return fail("too deep (recursion?)");
			break;
		}
		case op_callb: {
			int id = code[(size_t)fr.pc++], n = code[(size_t)fr.pc++];
			sp -= n;
			int32_t v = h.builtin(id, stack + sp, n);
			stack[sp++] = v;
			break;
		}
		case op_ret:
		case op_retv: {
			int32_t v = o == op_ret ? stack[sp - 1] : 0;
			sp = fr.base;
			--depth;
			if (depth == 0) {
				r.value = o == op_ret;
				r.v = v;
				return r;
			}
			stack[sp++] = v;
			break;
		}
		default: {
			int64_t b = stack[--sp], a = stack[sp - 1], v = 0;
			switch (o) {
			case op_add: v = a + b; break;
			case op_sub: v = a - b; break;
			case op_mul: v = a * b; break;
			case op_div: v = b == 0 ? 0 : a / b; break;
			case op_mod: v = b == 0 ? 0 : a % b; break;
			case op_eq: v = a == b; break;
			case op_ne: v = a != b; break;
			case op_lt: v = a < b; break;
			case op_le: v = a <= b; break;
			case op_gt: v = a > b; break;
			case op_ge: v = a >= b; break;
			default: return fail("bad code");
			}
			stack[sp - 1] = wrap(v);
			break;
		}
		}
	}
}

// --- the compiler -----------------------------------------------------------------

struct error {
	std::string message; // file:line:col: what
};

// The files of a bots folder, by path relative to it ("standard/profile.bot").
using bundle = std::map<std::string, std::string>;

// "path\x1F" text "\x1E", repeated: how the files cross the C API.
inline bundle parse_bundle(const char* data) {
	bundle b;
	if (!data) return b;
	const char* p = data;
	while (*p) {
		const char* sep = std::strchr(p, '\x1F');
		if (!sep) break;
		const char* end = std::strchr(sep + 1, '\x1E');
		if (!end) end = sep + 1 + std::strlen(sep + 1);
		b[std::string(p, sep)] = std::string(sep + 1, end);
		p = *end ? end + 1 : end;
	}
	return b;
}

class compiler {
public:
	compiler(const bundle& files) : files(files) {}

	// Compiles the profile in folder `dir` ("standard"); throws error.
	std::shared_ptr<profile> compile(const std::string& dir) {
		out = std::make_shared<profile>();
		std::string entry = dir + "/profile.bot";
		if (!files.count(entry)) throw error{entry + ": no such profile (its folder needs a profile.bot)"};
		extending.push_back(dir);
		compile_file(entry);
		for (auto& f : out->functions) {
			if (f.entry < 0) throw error{f.first_use + ": " + f.name + "() is never defined"};
		}
		if (out->name.empty()) out->name = dir;
		return out;
	}

private:
	const bundle& files;
	std::shared_ptr<profile> out;
	a_vector<std::string> extending; // profile folders being compiled (outermost first)
	a_vector<std::string> done_files;
	std::map<std::string, int32_t> consts;
	std::map<std::string, int> function_index;

	// --- lexing ---
	enum kind { t_eof, t_ident, t_number, t_string, t_punct };
	struct token {
		kind k = t_eof;
		std::string s;
		int32_t n = 0;
		int line = 0, col = 0;
	};
	std::string file;
	const std::string* src = nullptr;
	size_t pos = 0;
	int line = 1, col = 1;
	token tok;      // current
	token ahead;    // one more
	bool have_ahead = false;

	[[noreturn]] void fail_at(const token& t, const std::string& what) {
		throw error{file + ":" + std::to_string(t.line) + ":" + std::to_string(t.col) + ": " + what};
	}
	[[noreturn]] void fail(const std::string& what) { fail_at(tok, what); }
	std::string where(const token& t) const { return file + ":" + std::to_string(t.line) + ":" + std::to_string(t.col); }

	char peekc(size_t k = 0) const { return pos + k < src->size() ? (*src)[pos + k] : '\0'; }
	char getc() {
		char c = peekc();
		++pos;
		if (c == '\n') {
			++line;
			col = 1;
		} else {
			++col;
		}
		return c;
	}

	token lex() {
		while (true) {
			char c = peekc();
			if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
				getc();
			} else if (c == '/' && peekc(1) == '/') {
				while (peekc() && peekc() != '\n') getc();
			} else if (c == '/' && peekc(1) == '*') {
				token start;
				start.line = line;
				start.col = col;
				getc();
				getc();
				while (peekc() && !(peekc() == '*' && peekc(1) == '/')) getc();
				if (!peekc()) fail_at(start, "comment never closed");
				getc();
				getc();
			} else {
				break;
			}
		}
		token t;
		t.line = line;
		t.col = col;
		char c = peekc();
		if (!c) return t;
		if (std::isalpha((unsigned char)c) || c == '_') {
			t.k = t_ident;
			while (std::isalnum((unsigned char)peekc()) || peekc() == '_') t.s += getc();
			return t;
		}
		if (std::isdigit((unsigned char)c)) {
			t.k = t_number;
			int64_t v = 0;
			if (c == '0' && (peekc(1) == 'x' || peekc(1) == 'X')) {
				getc();
				getc();
				if (!std::isxdigit((unsigned char)peekc())) fail_at(t, "a hex number needs digits");
				while (std::isxdigit((unsigned char)peekc())) {
					char d = getc();
					v = v * 16 + (std::isdigit((unsigned char)d) ? d - '0' : (std::tolower((unsigned char)d) - 'a' + 10));
					if (v > 0xffffffffll) fail_at(t, "number too big");
				}
				t.n = wrap(v);
			} else {
				while (std::isdigit((unsigned char)peekc())) {
					v = v * 10 + (getc() - '0');
					if (v > 2147483647ll) fail_at(t, "number too big (the largest is 2147483647)");
				}
				t.n = (int32_t)v;
			}
			if (std::isalpha((unsigned char)peekc()) || peekc() == '_') fail_at(t, "a number runs into a name");
			return t;
		}
		if (c == '"') {
			t.k = t_string;
			getc();
			while (peekc() != '"') {
				if (!peekc() || peekc() == '\n') fail_at(t, "string never closed");
				char d = getc();
				if (d == '\\') {
					char e = getc();
					d = e == 'n' ? '\n' : e == 't' ? '\t' : e;
				}
				t.s += d;
			}
			getc();
			return t;
		}
		static const char* ops[] = {"&&", "||", "==", "!=", "<=", ">=", "+=", "-=", "*=", "/=", "%=", "++", "--"};
		for (const char* o : ops) {
			if (c == o[0] && peekc(1) == o[1]) {
				getc();
				getc();
				t.k = t_punct;
				t.s = o;
				return t;
			}
		}
		if (std::strchr("{}()[];,.=<>+-*/%!?:", c)) {
			t.k = t_punct;
			t.s = std::string(1, getc());
			return t;
		}
		fail_at(t, std::string("unexpected character '") + c + "'");
	}

	void next() {
		if (have_ahead) {
			tok = ahead;
			have_ahead = false;
		} else {
			tok = lex();
		}
	}
	const token& peek() {
		if (!have_ahead) {
			ahead = lex();
			have_ahead = true;
		}
		return ahead;
	}
	bool is(const char* p) const { return tok.k == t_punct && tok.s == p; }
	bool is_word(const char* w) const { return tok.k == t_ident && tok.s == w; }
	bool accept(const char* p) {
		if (!is(p)) return false;
		next();
		return true;
	}
	bool accept_word(const char* w) {
		if (!is_word(w)) return false;
		next();
		return true;
	}
	void expect(const char* p) {
		if (!accept(p)) fail(std::string("expected '") + p + "'" + found());
	}
	std::string found() const {
		if (tok.k == t_eof) return " at the end of the file";
		if (tok.k == t_string) return ", found a string";
		if (tok.k == t_number) return ", found " + std::to_string(tok.n);
		return ", found '" + tok.s + "'";
	}
	std::string ident(const char* what) {
		if (tok.k != t_ident) fail(std::string("expected ") + what + found());
		std::string s = tok.s;
		next();
		return s;
	}
	std::string string_lit(const char* what) {
		if (tok.k != t_string) fail(std::string("expected ") + what + " in quotes" + found());
		std::string s = tok.s;
		next();
		return s;
	}

	// --- files ---
	static std::string folder_of(const std::string& path) {
		size_t slash = path.rfind('/');
		return slash == std::string::npos ? "" : path.substr(0, slash + 1);
	}

	void compile_file(const std::string& path) {
		// Remember the lexer of the including file.
		std::string saved_file = file;
		const std::string* saved_src = src;
		size_t saved_pos = pos;
		int saved_line = line, saved_col = col;
		token saved_tok = tok, saved_ahead = ahead;
		bool saved_have = have_ahead;

		done_files.push_back(path);
		out->files.push_back(path);
		file = path;
		src = &files.at(path);
		pos = 0;
		line = col = 1;
		have_ahead = false;
		next();
		while (tok.k != t_eof) declaration();

		file = saved_file;
		src = saved_src;
		pos = saved_pos;
		line = saved_line;
		col = saved_col;
		tok = saved_tok;
		ahead = saved_ahead;
		have_ahead = saved_have;
	}

	bool top_level() const { return extending.size() == 1; }

	void do_extends() {
		token at = tok;
		std::string dir = string_lit("a profile folder");
		expect(";");
		for (auto& d : extending) {
			if (d == dir) fail_at(at, "profile '" + dir + "' extends itself");
		}
		std::string entry = dir + "/profile.bot";
		if (!files.count(entry)) fail_at(at, "no profile '" + dir + "' to extend");
		for (auto& f : done_files) {
			if (f == entry) fail_at(at, "profile '" + dir + "' is already part of this one");
		}
		extending.push_back(dir);
		compile_file(entry);
		extending.pop_back();
	}

	void do_include() {
		token at = tok;
		std::string name = string_lit("a file name");
		expect(";");
		std::string path = folder_of(file) + name;
		if (!files.count(path)) path = name;
		if (!files.count(path)) fail_at(at, "no file '" + name + "' to include");
		for (auto& f : done_files) {
			if (f == path) return; // once is enough
		}
		compile_file(path);
	}

	void declaration() {
		if (accept_word("profile")) {
			std::string name = string_lit("the profile's name");
			if (top_level()) out->name = name;
			expect("{");
			while (!accept("}")) {
				if (accept_word("extends")) {
					do_extends();
				} else if (accept_word("description")) {
					std::string d = string_lit("a description");
					if (top_level()) out->description = d;
					expect(";");
				} else if (accept_word("author")) {
					std::string a = string_lit("an author");
					if (top_level()) out->author = a;
					expect(";");
				} else {
					fail("expected extends, description or author" + found());
				}
			}
		} else if (accept_word("extends")) {
			do_extends();
		} else if (accept_word("include")) {
			do_include();
		} else if (accept_word("const")) {
			token at = tok;
			std::string name = ident("a constant's name");
			check_new_name(at, name);
			expect("=");
			consts[name] = const_expr();
			expect(";");
		} else if (accept_word("var")) {
			global_decl();
		} else if (is_word("set") || (tok.k == t_ident && resolve_builtin(tok.s) >= 0)) {
			// set army.wave_first = 6; or use_plan("rush"); at the start.
			init_statement();
		} else if (accept_word("on")) {
			handler_decl();
		} else if (is_word("int") || is_word("bool") || is_word("void")) {
			function_decl();
		} else if (accept_word("plan")) {
			plan_table();
		} else if (accept_word("research")) {
			research_table();
		} else if (accept_word("mix")) {
			mix_table();
		} else {
			fail("expected a declaration (profile, extends, include, const, var, set, on, a function, plan, research or mix)" + found());
		}
	}

	void check_new_name(const token& at, const std::string& name) {
		if (resolve_builtin(name) >= 0) fail_at(at, "'" + name + "' is a builtin");
		if (unit_id(name) >= 0 || tech_id(name) >= 0 || upgrade_id(name) >= 0) fail_at(at, "'" + name + "' is a unit, tech or upgrade name");
	}

	// --- names ---
	static int find(const char* const* table, int n, const std::string& s) {
		for (int i = 0; i != n; ++i) {
			if (s == table[i]) return i;
		}
		return -1;
	}
	static int unit_id(const std::string& s) { return find(unit_names, unit_names_count, s); }
	static int tech_id(const std::string& s) { return find(tech_names, tech_names_count, s); }
	static int upgrade_id(const std::string& s) { return find(upgrade_names, upgrade_names_count, s); }
	static int resolve_builtin(const std::string& s) {
		for (int i = 0; i != builtin_count; ++i) {
			if (s == builtins()[i].name) return i;
		}
		return -1;
	}
	static int race_id(const std::string& s) { return s == "zerg" ? 0 : s == "terran" ? 1 : s == "protoss" ? 2 : -1; }
	static int tunable(const std::string& s) {
		auto& names = bw_ai::tunable_names();
		for (size_t i = 0; i != names.size(); ++i) {
			if (s == names[i].name) return (int)i;
		}
		return -1;
	}
	bool named_constant(const std::string& s, int32_t& v) {
		auto c = consts.find(s);
		if (c != consts.end()) {
			v = c->second;
			return true;
		}
		if (s == "true") v = 1;
		else if (s == "false") v = 0;
		else if (s == "SECOND") v = 1;
		else if (s == "MINUTE") v = 60;
		else if (race_id(s) >= 0) v = race_id(s);
		else if (unit_id(s) >= 0) v = unit_id(s);
		else if (tech_id(s) >= 0) v = tech_id(s);
		else if (upgrade_id(s) >= 0) v = upgrade_id(s);
		else return false;
		return true;
	}
	int variant(const std::string& name) {
		auto& v = out->variants;
		for (size_t i = 0; i != v.size(); ++i) {
			if (v[i] == name) return (int)i;
		}
		v.push_back(name);
		out->tables.emplace_back();
		return (int)v.size() - 1;
	}

	// --- code generation ---
	a_vector<int32_t>& code() { return out->code; }
	void emit(int32_t v) { code().push_back(v); }
	void emit(int32_t o, int32_t a) {
		emit(o);
		emit(a);
	}
	int here() const { return (int)out->code.size(); }
	int jump(int32_t o) {
		emit(o, -1);
		return here() - 1;
	}
	void patch(int at, int target) { code()[(size_t)at] = target; }

	// The function being compiled: its scopes of locals.
	struct scope_t {
		a_vector<std::pair<std::string, int>> names;
	};
	a_vector<scope_t> scopes;
	int locals = 0, max_locals = 0;
	bool in_function = false;
	bool returns_value = false;
	bool init_context = false; // set and var initializers (start of game)
	bool const_mode = false;   // a constant expression
	struct loop_t {
		a_vector<int> breaks, continues;
	};
	a_vector<loop_t> loops;

	int local(const std::string& name) {
		for (size_t i = scopes.size(); i-- > 0;) {
			for (auto& n : scopes[i].names) {
				if (n.first == name) return n.second;
			}
		}
		return -1;
	}
	int global(const std::string& name) {
		for (size_t i = 0; i != out->globals.size(); ++i) {
			if (out->globals[i] == name) return (int)i;
		}
		return -1;
	}
	int declare_local(const token& at, const std::string& name) {
		for (auto& n : scopes.back().names) {
			if (n.first == name) fail_at(at, "'" + name + "' is already declared here");
		}
		// (A local may hide a fact of the same name, "ally" say.)
		if (unit_id(name) >= 0 || tech_id(name) >= 0 || upgrade_id(name) >= 0) fail_at(at, "'" + name + "' is a unit, tech or upgrade name");
		int slot = locals++;
		max_locals = std::max(max_locals, locals);
		scopes.back().names.push_back({name, slot});
		return slot;
	}

	// Starts a function body; returns its index.
	int begin_function(const token& at, const std::string& name, int params, bool value) {
		int index;
		auto it = function_index.find(name);
		if (it != function_index.end()) {
			index = it->second;
			function& f = out->functions[(size_t)index];
			if (f.params != params) fail_at(at, name + "() takes " + std::to_string(f.params) + " argument(s) elsewhere");
		} else {
			index = (int)out->functions.size();
			function_index[name] = index;
			out->functions.emplace_back();
			out->functions.back().name = name;
			out->functions.back().params = params;
		}
		out->functions[(size_t)index].value = value;
		scopes.assign(1, scope_t());
		locals = max_locals = 0;
		in_function = true;
		returns_value = value;
		return index;
	}
	void end_function(int index, int entry) {
		emit(op_retv);
		function& f = out->functions[(size_t)index];
		f.entry = entry;
		f.locals = max_locals;
		scopes.clear();
		in_function = false;
	}

	// --- declarations ---
	void global_decl() {
		token at = tok;
		std::string name = ident("a variable's name");
		check_new_name(at, name);
		int g = global(name);
		if (g < 0) {
			if ((int)out->globals.size() >= max_globals) fail_at(at, "too many variables (at most " + std::to_string(max_globals) + ")");
			out->globals.push_back(name);
			g = (int)out->globals.size() - 1;
		}
		if (accept("=")) {
			int fn = begin_init(at);
			int entry = here();
			init_context = true;
			expr();
			init_context = false;
			emit(op_stg, g);
			end_function(fn, entry);
		}
		expect(";");
	}

	int begin_init(const token& at) {
		std::string name = "(start " + std::to_string(out->init.size()) + ")";
		int fn = begin_function(at, name, 0, false);
		out->init.push_back(fn);
		return fn;
	}

	void init_statement() {
		token at = tok;
		int fn = begin_init(at);
		int entry = here();
		init_context = true;
		statement();
		init_context = false;
		end_function(fn, entry);
	}

	a_vector<token> param_list(a_vector<std::string>& names) {
		a_vector<token> at;
		expect("(");
		if (!accept(")")) {
			do {
				// (The type may be left out: everything is an int.)
				if (!accept_word("int")) accept_word("bool");
				at.push_back(tok);
				names.push_back(ident("a parameter name"));
			} while (accept(","));
			expect(")");
		}
		return at;
	}

	void function_decl() {
		bool value = !is_word("void");
		next();
		token at = tok;
		std::string name = ident("a function name");
		check_new_name(at, name);
		if (consts.count(name) || global(name) >= 0) fail_at(at, "'" + name + "' is already a constant or variable");
		a_vector<std::string> params;
		a_vector<token> param_at = param_list(params);
		int fn = begin_function(at, name, (int)params.size(), value);
		for (size_t i = 0; i != params.size(); ++i) declare_local(param_at[i], params[i]);
		int entry = here();
		block();
		end_function(fn, entry);
	}

	void handler_decl() {
		token at = tok;
		std::string name = ident("an event name");
		int h = -1;
		for (int i = 0; i != handler_count; ++i) {
			if (name == handlers()[i].name) h = i;
		}
		if (h < 0) {
			std::string list;
			for (int i = 0; i != handler_count; ++i) list += std::string(i ? ", " : "") + handlers()[i].name;
			fail_at(at, "no event '" + name + "' (there are: " + list + ")");
		}
		a_vector<std::string> params;
		a_vector<token> param_at;
		if (is("(")) param_at = param_list(params);
		if ((int)params.size() != handlers()[h].argc) {
			fail_at(at, "on " + name + " takes " + std::to_string(handlers()[h].argc) + " parameter(s)");
		}
		int fn = begin_function(at, "on " + name, (int)params.size(), true);
		for (size_t i = 0; i != params.size(); ++i) declare_local(param_at[i], params[i]);
		int entry = here();
		block();
		end_function(fn, entry);
		out->handler[(size_t)h] = fn;
	}

	// --- tables ---
	int race_word() {
		token at = tok;
		std::string r = ident("a race (zerg, terran or protoss)");
		int id = race_id(r);
		if (id < 0) fail_at(at, "expected zerg, terran or protoss, found '" + r + "'");
		return id;
	}
	int where_word() {
		if (accept_word("ground")) return bw_ai::where_ground;
		if (accept_word("island")) return bw_ai::where_island;
		accept_word("any");
		return bw_ai::where_any;
	}
	UnitTypes unit_word() {
		token at = tok;
		std::string u = ident("a unit type");
		int id = unit_id(u);
		if (id < 0) fail_at(at, "no unit type '" + u + "' (unit names look like terran_marine)");
		return (UnitTypes)id;
	}
	int variant_name() { return tok.k == t_string ? variant(string_lit("a name")) : 0; }

	void plan_table() {
		int r = race_word();
		int v = variant_name();
		auto& t = out->tables[(size_t)v];
		auto& rows = t.t.plan[(size_t)r];
		rows.clear();
		t.plan[(size_t)r] = true;
		expect("{");
		while (!accept("}")) {
			if (!accept_word("build")) fail("expected build" + found());
			plan_step s;
			s.type = unit_word();
			s.count = const_expr();
			if (!accept_word("at")) fail("expected at (the supply to start at)" + found());
			s.supply = const_expr();
			s.where = where_word();
			expect(";");
			rows.push_back(s);
		}
	}

	void research_table() {
		int r = race_word();
		int v = variant_name();
		auto& t = out->tables[(size_t)v];
		auto& rows = t.t.research[(size_t)r];
		rows.clear();
		t.research[(size_t)r] = true;
		expect("{");
		while (!accept("}")) {
			research2_step s;
			token at = tok;
			if (accept_word("tech")) {
				s.is_tech = true;
				std::string n = ident("a tech");
				s.id = tech_id(n);
				if (s.id < 0) fail_at(at, "no tech '" + n + "'");
			} else if (accept_word("upgrade")) {
				s.is_tech = false;
				std::string n = ident("an upgrade");
				s.id = upgrade_id(n);
				if (s.id < 0) fail_at(at, "no upgrade '" + n + "'");
			} else {
				fail("expected tech or upgrade" + found());
			}
			if (!accept_word("by")) fail("expected by (the building that researches it)" + found());
			s.building = unit_word();
			if (!accept_word("at")) fail("expected at (the supply to start at)" + found());
			s.supply = const_expr();
			s.where = where_word();
			expect(";");
			rows.push_back(s);
		}
	}

	void mix_table() {
		int r = race_word();
		bool island;
		if (accept_word("island")) island = true;
		else if (accept_word("ground")) island = false;
		else fail("expected ground or island (which map the mix is for)" + found());
		int v = variant_name();
		auto& t = out->tables[(size_t)v];
		auto& rows = (island ? t.t.mix_island : t.t.mix_ground)[(size_t)r];
		rows.clear();
		(island ? t.mix_island : t.mix_ground)[(size_t)r] = true;
		expect("{");
		while (!accept("}")) {
			mix_row m{unit_word(), 0, 0};
			if (!accept_word("share")) fail("expected share" + found());
			m.share = const_expr();
			while (!accept(";")) {
				if (accept_word("cap")) {
					m.cap = const_expr();
				} else if (accept_word("aa")) {
					m.aa_mul = const_primary();
					m.aa_div = accept("/") ? const_primary() : 1;
					if (m.aa_div < 1) fail("aa needs a divisor of 1 or more");
				} else if (accept_word("late")) {
					m.late = const_expr();
				} else if (accept_word("cloak")) {
					m.cloak = const_expr();
				} else if (accept_word("some_island")) {
					m.some_island = true;
				} else {
					fail("expected cap, aa, late, cloak, some_island or ';'" + found());
				}
			}
			rows.push_back(m);
		}
	}

	// --- constant expressions: compiled, run, and the code dropped ---
	int32_t const_value(void (compiler::*parse)()) {
		bool saved = const_mode;
		const_mode = true;
		size_t start = out->code.size();
		(this->*parse)();
		emit(op_ret);
		const_mode = saved;
		function f;
		f.entry = (int)start;
		out->functions.push_back(f);
		struct none : host {
			int32_t builtin(int, const int32_t*, int) override { return 0; }
			int32_t* globals() override { return g; }
			ai_tunables& tunables() override { return t; }
			void warn(const char*) override {}
			int32_t g[1]{};
			ai_tunables t;
		} h;
		result r = run(*out, (int)out->functions.size() - 1, nullptr, 0, h);
		out->functions.pop_back();
		out->code.resize(start);
		return r.v;
	}
	int32_t const_expr() { return const_value(&compiler::expr); }
	int32_t const_primary() { return const_value(&compiler::unary); }

	// --- statements ---
	void block() {
		expect("{");
		scopes.emplace_back();
		int saved = locals;
		while (!accept("}")) {
			if (tok.k == t_eof) fail("expected '}'" + found());
			statement();
		}
		locals = saved;
		scopes.pop_back();
	}

	void statement() {
		if (is("{")) {
			if (!in_function) fail("a block needs a function");
			block();
			return;
		}
		if (accept(";")) return;
		if (is_word("int") || is_word("bool")) {
			if (init_context) fail("declare variables at the top level with var");
			next();
			token at = tok;
			std::string name = ident("a variable's name");
			int slot = declare_local(at, name);
			if (accept("=")) expr();
			else emit(op_push, 0);
			emit(op_stl, slot);
			expect(";");
			return;
		}
		if (is_word("var")) fail("var declares variables at the top level; inside a function use int");
		if (accept_word("if")) {
			expect("(");
			expr();
			expect(")");
			int skip = jump(op_jz);
			statement();
			if (accept_word("else")) {
				int end = jump(op_jmp);
				patch(skip, here());
				statement();
				patch(end, here());
			} else {
				patch(skip, here());
			}
			return;
		}
		if (accept_word("while")) {
			int top = here();
			expect("(");
			expr();
			expect(")");
			int exit = jump(op_jz);
			loops.emplace_back();
			statement();
			emit(op_jmp, top);
			finish_loop(top, exit);
			return;
		}
		if (accept_word("for")) {
			expect("(");
			scopes.emplace_back();
			int saved = locals;
			if (!accept(";")) {
				if (is_word("int") || is_word("bool")) {
					next();
					token at = tok;
					std::string name = ident("a variable's name");
					int slot = declare_local(at, name);
					if (accept("=")) expr();
					else emit(op_push, 0);
					emit(op_stl, slot);
				} else {
					simple_statement();
				}
				expect(";");
			}
			int top = here();
			int exit = -1;
			if (!is(";")) {
				expr();
				exit = jump(op_jz);
			}
			expect(";");
			// The step runs after the body: jump over it the first time.
			int body = jump(op_jmp);
			int step = here();
			if (!is(")")) simple_statement();
			expect(")");
			emit(op_jmp, top);
			patch(body, here());
			loops.emplace_back();
			statement();
			emit(op_jmp, step);
			finish_loop(step, exit);
			locals = saved;
			scopes.pop_back();
			return;
		}
		if (is_word("break") || is_word("continue")) {
			bool brk = is_word("break");
			if (loops.empty()) fail(std::string(brk ? "break" : "continue") + " outside a loop");
			next();
			int at = jump(op_jmp);
			(brk ? loops.back().breaks : loops.back().continues).push_back(at);
			expect(";");
			return;
		}
		if (accept_word("return")) {
			if (init_context) fail("return outside a function");
			if (accept(";")) {
				emit(op_retv);
				return;
			}
			if (!returns_value) fail("a void function returns no value");
			expr();
			emit(op_ret);
			expect(";");
			return;
		}
		simple_statement();
		expect(";");
	}

	void finish_loop(int continue_to, int exit) {
		loop_t l = loops.back();
		loops.pop_back();
		int end = here();
		if (exit >= 0) patch(exit, end);
		for (int b : l.breaks) patch(b, end);
		for (int c : l.continues) patch(c, continue_to);
	}

	// Assignment, ++/--, or a call whose value is dropped.
	void simple_statement() {
		accept_word("set");
		token at = tok;
		std::string name = ident("a statement");
		if (is(".")) {
			next();
			std::string field = ident("a field");
			std::string full = name + "." + field;
			int t = tunable(full);
			if (t < 0) fail_at(at, "no number '" + full + "' to set");
			assign_rest(at, [&] { emit(op_ldp, t); }, [&] { emit(op_stp, t); });
			return;
		}
		if (is("(")) {
			call(at, name, false);
			return;
		}
		int l = in_function ? local(name) : -1;
		if (l >= 0) {
			assign_rest(at, [&] { emit(op_ldl, l); }, [&] { emit(op_stl, l); });
			return;
		}
		int g = global(name);
		if (g >= 0) {
			assign_rest(at, [&] { emit(op_ldg, g); }, [&] { emit(op_stg, g); });
			return;
		}
		int32_t v;
		if (named_constant(name, v)) fail_at(at, "'" + name + "' is a constant");
		if (resolve_builtin(name) >= 0) {
			call(at, name, false);
			return;
		}
		fail_at(at, "unknown name '" + name + "'");
	}

	template<typename L, typename S>
	void assign_rest(const token& at, L load, S store) {
		if (accept("=")) {
			expr();
		} else if (is("++") || is("--")) {
			bool inc = is("++");
			next();
			load();
			emit(op_push, 1);
			emit(inc ? op_add : op_sub);
		} else {
			static const char* ops[] = {"+=", "-=", "*=", "/=", "%="};
			static const op codes[] = {op_add, op_sub, op_mul, op_div, op_mod};
			int k = -1;
			for (int i = 0; i != 5; ++i) {
				if (is(ops[i])) k = i;
			}
			if (k < 0) fail_at(at, "expected =, +=, -=, *=, /=, %=, ++ or --" + found());
			next();
			load();
			expr();
			emit(codes[k]);
		}
		store();
	}

	// A call: user function or builtin. `want` its value (else dropped).
	void call(const token& at, const std::string& name, bool want) {
		int b = resolve_builtin(name);
		int argc = 0;
		if (is("(")) {
			next();
			if (!accept(")")) {
				do {
					if (b >= 0 && (builtins()[b].flags & f_name) && tok.k == t_string) {
						emit(op_push, variant(string_lit("a name")));
					} else {
						expr();
					}
					++argc;
				} while (accept(","));
				expect(")");
			}
		}
		if (b >= 0) {
			const builtin_info& info = builtins()[b];
			if (const_mode) fail_at(at, "'" + name + "' is not a constant");
			if (argc != info.argc) fail_at(at, name + "() takes " + std::to_string(info.argc) + " argument(s)");
			if (want && !(info.flags & f_value)) fail_at(at, name + "() gives no value");
			if (init_context && !(info.flags & f_init)) fail_at(at, name + "() means nothing at the start of the game; use it in an event (on think)");
			emit(op_callb, b);
			emit(argc);
		} else {
			if (const_mode) fail_at(at, "'" + name + "' is not a constant");
			auto it = function_index.find(name);
			int index;
			if (it == function_index.end()) {
				index = (int)out->functions.size();
				function_index[name] = index;
				out->functions.emplace_back();
				function& f = out->functions.back();
				f.name = name;
				f.params = argc;
				f.value = want;
				f.first_use = where(at);
			} else {
				index = it->second;
				const function& f = out->functions[(size_t)index];
				if (f.params != argc) fail_at(at, name + "() takes " + std::to_string(f.params) + " argument(s)");
				if (want && f.entry >= 0 && !f.value) fail_at(at, name + "() gives no value");
			}
			emit(op_call, index);
			emit(argc);
		}
		if (!want) emit(op_pop);
	}

	// --- expressions (C precedence) ---
	void expr() {
		logic_or();
		if (accept("?")) {
			int skip = jump(op_jz);
			expr();
			int end = jump(op_jmp);
			expect(":");
			patch(skip, here());
			expr();
			patch(end, here());
		}
	}
	void logic_or() {
		logic_and();
		while (is("||")) {
			next();
			// a || b: 1 if a, else b != 0.
			int to_b = jump(op_jz);
			emit(op_push, 1);
			int end = jump(op_jmp);
			patch(to_b, here());
			logic_and();
			emit(op_push, 0);
			emit(op_ne);
			patch(end, here());
		}
	}
	void logic_and() {
		equality();
		while (is("&&")) {
			next();
			int no = jump(op_jz);
			equality();
			emit(op_push, 0);
			emit(op_ne);
			int end = jump(op_jmp);
			patch(no, here());
			emit(op_push, 0);
			patch(end, here());
		}
	}
	void equality() {
		comparison();
		while (is("==") || is("!=")) {
			op o = is("==") ? op_eq : op_ne;
			next();
			comparison();
			emit(o);
		}
	}
	void comparison() {
		additive();
		while (is("<") || is("<=") || is(">") || is(">=")) {
			op o = is("<") ? op_lt : is("<=") ? op_le : is(">") ? op_gt : op_ge;
			next();
			additive();
			emit(o);
		}
	}
	void additive() {
		multiplicative();
		while (is("+") || is("-")) {
			op o = is("+") ? op_add : op_sub;
			next();
			multiplicative();
			emit(o);
		}
	}
	void multiplicative() {
		unary();
		while (is("*") || is("/") || is("%")) {
			op o = is("*") ? op_mul : is("/") ? op_div : op_mod;
			next();
			unary();
			emit(o);
		}
	}
	void unary() {
		if (accept("-")) {
			unary();
			emit(op_neg);
		} else if (accept("!")) {
			unary();
			emit(op_not);
		} else if (accept("+")) {
			unary();
		} else {
			primary();
		}
	}
	void primary() {
		token at = tok;
		if (tok.k == t_number) {
			emit(op_push, tok.n);
			next();
			return;
		}
		if (accept("(")) {
			expr();
			expect(")");
			return;
		}
		if (tok.k == t_string) fail("a string can only name a plan or mix (use_plan(\"name\"))");
		if (tok.k != t_ident) fail("expected a value" + found());
		std::string name = tok.s;
		next();
		if (is(".")) {
			next();
			std::string field = ident("a field");
			std::string full = name + "." + field;
			int t = tunable(full);
			if (t < 0) fail_at(at, "no number '" + full + "'");
			if (const_mode) fail_at(at, "'" + full + "' is not a constant");
			emit(op_ldp, t);
			return;
		}
		if (is("(")) {
			call(at, name, true);
			return;
		}
		int l = in_function ? local(name) : -1;
		if (l >= 0) {
			if (const_mode) fail_at(at, "'" + name + "' is not a constant");
			emit(op_ldl, l);
			return;
		}
		int g = global(name);
		if (g >= 0) {
			if (const_mode) fail_at(at, "'" + name + "' is not a constant");
			emit(op_ldg, g);
			return;
		}
		int32_t v;
		if (named_constant(name, v)) {
			emit(op_push, v);
			return;
		}
		int b = resolve_builtin(name);
		if (b >= 0) {
			if (!(builtins()[b].flags & f_bare)) fail_at(at, name + " needs arguments: " + name + "(...)");
			call(at, name, true);
			return;
		}
		fail_at(at, "unknown name '" + name + "'");
	}
};

// Compiles; on failure returns null and sets `message`.
inline std::shared_ptr<const profile> compile(const bundle& files, const std::string& dir, std::string& message) {
	try {
		compiler c(files);
		return c.compile(dir);
	} catch (const error& e) {
		message = e.message;
	} catch (const std::exception& e) {
		message = std::string("internal error: ") + e.what();
	}
	return nullptr;
}

} // namespace botscript

#endif // BOTSCRIPT_H
