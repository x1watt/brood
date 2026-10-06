# Bot profiles

A bot profile sets how a computer player plays: its personality, build
order, army, how and when it attacks, and how it deals with alliances. A
profile is a folder of text files written in BotScript, a small language
that looks like C. Pick a profile for each computer opponent on the start
screen (the menu next to its race).

## Where profiles live

- `assets/bots/` ships with the game: `standard` (the usual player, every
  number and table spelled out), `rusher`, `turtle`, `loyal`,
  `opportunist`, and `lib/common.bot` with helpers.
- Your own go in a `bots/` folder of the game data (next to `maps/`;
  `BROOD_DATA` on desktop). A file there replaces a shipped file of the
  same path, so `bots/lib/common.bot` changes the helpers for everyone.
- The home server (`tool/brood_server.dart`) hands `bots/**.bot` to
  browsers along with the maps; in the browser a folder you import may
  also hold a `bots/` folder.

A game keeps the text of every file its profiles use (`GameSetup.botFiles`).
A saved game loads with the profiles it was played with, and every player
of a multiplayer game runs the same ones.

## The editor

The start screen's Bot profiles button (next to the opponents) opens the
editor. It lists every profile. A shipped one opens as a copy, and yours
open as they are. New profile starts from the standard player or a copy of
any profile. A profile has two tabs:

- **Settings**: its name, its description and every number it plays by,
  grouped, with what each does and its standard value. Changed numbers are
  kept in the profile's `settings.bot`, which `profile.bot` includes last,
  so they win over its own `set` statements.
- **Code**: its files in a text editor, with line numbers. New files are
  included from `profile.bot`.

Check compiles the profile as it stands, saved or not. An error names its
place, and Show goes there.

## A profile

A profile is a folder with a `profile.bot`; the folder's name identifies it.

```c
// bots/sneaky/profile.bot
profile "Sneaky" {
	extends "standard";          // everything standard does, then the changes below
	description "Expands early and attacks the weakest enemy.";
}

include "lib/common.bot";        // another file: next to this one, else from the bots folder

const FIRST_ATTACK = 9 * MINUTE;

set army.wave_first = 12;        // a number the player plays by (see below)
set expansion.base1 = 4 * MINUTE;

var target = -1;                 // a variable kept for the whole game (and in saves)

on think {                       // an event: runs on every decision, about twice a second
	if (time > FIRST_ATTACK && !attacking) {
		target = weakest_enemy();
		focus(target);
	}
}

on wave(ready) {                 // decides whether the next attack wave goes
	if (time < FIRST_ATTACK) return false;
}
```

A profile that `extends` another gets all of it first and then replaces
what it declares again: a number it sets, a table it writes for the same
race (and variant), a function or event handler of the same name. Functions
are looked up by name when called, so a helper redefined in the child also
changes the parent's code that calls it.

## The language

Everything is a 32-bit integer; `true` is 1 and `false` is 0. Arithmetic
wraps around, and a division by zero gives 0. Comments are `//` and
`/* */`.

- Declarations: `const NAME = expr;` (worked out when compiling), `var name =
  expr;` (a variable of the player, at most 64), functions
  `int name(int a, int b) { ... }` (also `bool` and `void`; parameter types
  may be left out), `on event(params) { ... }`, `set group.number = expr;`,
  and the tables below.
- Statements: `int x = expr;`, `x = expr;`, `+= -= *= /= %=`, `x++`,
  `x--`, `if (...) ... else ...`, `while`, `for (init; cond; step)`,
  `break`, `continue`, `return expr;`, `return;`, and calls.
- Expressions: `+ - * / %`, `== != < <= > >=`, `&& || !` (short-circuit),
  `cond ? a : b`, parentheses, numbers (also `0x1F`), names.
- Names: unit types, techs and upgrades by their names in lower case
  (`terran_marine`, `protoss_dragoon`, `stim_packs`, `u_238_shells`),
  races `zerg terran protoss`, `MINUTE` (60) and `SECOND` (1). Players are
  numbers 0 to 7; -1 is none.
- Times are in seconds everywhere in a script.

Statements at the top level (`set`, `var` initializers and calls such as
`use_plan("rush");`) run once when the player starts, in order (a parent's
first). Then only random numbers and the player's race and number mean
anything; the game's facts are read in events.

A run that takes more than 100,000 steps or calls 64 functions deep stops
(the event then makes no decision), and the message goes to the console
and to `BROOD_AI_LOG`. Compiling stops at the first error, given as
`file:line:col: what`. The start screen shows it under the opponent and
won't start the game.

## Numbers

`set group.number = value;` changes a number, and `group.number` reads it
(in events too: a profile may change its numbers as the game goes).
`assets/bots/standard/numbers.bot` lists every one at its standard value,
with what it does. The groups:

- `personality`: the trust range (trust colours every alliance decision).
- `economy`: workers, supply, gas, what to do with surplus money.
- `expansion`: when to take the next bases (`base1` to `base4`).
- `army`: attack waves (first size, growth, cap, when a wave ends), unit
  mix switches (late game, enemy air), units when gas runs short.
- `defense`: what counts as an attack, workers that fight, defences per
  base, anti-air, comsats and silos.
- `help`: helping allies under attack (defensive mode).
- `drops`: transports carrying units to other islands.
- `spells`: the least value a spell must hit before it is cast.
- `diplomacy`: how much it wants each alliance, when it accepts, surrenders
  and betrays, how often it invites.

## Tables

```c
// Build plan: <type> <how many in all> at <supply in use> [ground|island|any];
plan terran {
	build terran_barracks 1 at 10;
	build terran_starport 1 at 17 island;   // only when no enemy base can be walked to
}

// Research: tech|upgrade <name> by <building> at <supply in use> [where];
research protoss {
	upgrade singularity_charge by protoss_cybernetics_core at 20 ground;
	tech psionic_storm by protoss_templar_archives at 48;
}

// Army mix for maps where enemies can be walked to (ground) or not (island):
// <type> share <part> [cap <at most>] [aa <n>/<d>] [late <share>] [cloak <share>] [some_island];
mix zerg ground {
	zerg_zergling share 20;
	zerg_scourge share 0 cap 12 aa 1;       // grows with the enemies' air force
	zerg_ultralisk share 0 cap 8 late 6;    // only in the late game
}
```

The plan is followed in order, one building per decision, and saves money
for the next row. A table declared for a race replaces that race's table
entirely; a race without one keeps the standard table.

Tables may have names: `plan terran "rush" { ... }`. `use_plan("rush")`,
`use_research(...)` and `use_mix(...)` switch to them (at the start or in
an event), and `use_plan("")` goes back. A race without a table of that
name uses the unnamed one.

## Events

An event that returns a value makes the decision; one that returns nothing
(or isn't there) leaves it to the standard player.

| Event | When | Return |
|---|---|---|
| `on think` | every decision, about twice a second | nothing |
| `on wave(ready)` | not attacking, with `ready` units able to go | true: attack now, false: wait |
| `on invite(from)` | answering an invitation from `from` | true: accept |
| `on surrender_offer(from, tribute, conquest)` | `from` offers to surrender | true: accept |
| `on surrender(to)` | losing at home: surrender to `to`? | true: offer it |
| `on betray(ally)` | the weakest ally could be turned on | true: leave and attack it |
| `on ally_attacked(ally)` | defensive mode, an ally's base is attacked | false: don't help |

## Facts

`time`, `frame`, `me`, `race`, `trust`, `minerals`, `gas`, `supply`,
`supply_max`, `workers`, `bases`, `army` (units), `army_value`,
`wave_size`, `attacking`, `losing` (beaten at home), `attacker` (by whom),
`island` (no enemy base can be walked to), `some_island`, `enemy_air`,
`enemy_cloaked` (their value), `defensive` (a human ally's defensive mode).

`count(type)` (including those being made), `done(type)`,
`researched(tech)`, `upgrade_level(upgrade)`.

About player `q`: `alive(q)`, `human(q)`, `ally(q)`, `enemy(q)`,
`race_of(q)`, `army_of(q)`, `economy_of(q)`, `strength(q)` (its alliance's
army and economy), `utility(q)` (how much we want its alliance),
`distance(q)` (between main bases), `mining(q)` (per minute),
`lost_to(q)` (what we lost to it lately), `group_size(q)`, `vassal(q)`,
`lord(q)`.

`random(a, b)` (from the player's own seeded numbers), `min`, `max`, `abs`,
`clamp(x, lo, hi)`.

## Actions

`attack()` (the next wave goes now), `retreat()`, `set_wave(n)`,
`focus(q)` (its buildings first; -1: the nearest), `invite(q)`, `leave()`,
`surrender_to(q)`, `set_open(bool)`, `use_plan(name)`,
`use_research(name)`, `use_mix(name)`, `print(x)` (to `BROOD_AI_LOG`).
Diplomacy actions do nothing for auto-play, a vassal or a player out of
the game.

Agents and assistants (docs/agent_api.md) can steer a profile's player
from outside during the game: start or hold attack waves, pick a target,
or set any of its numbers.

## Engine side

- `engine/bridge/src/botscript.h`: the compiler and the stack machine; the
  names of units, techs and upgrades come from
  `engine/bridge/src/botscript_names.h` (`tool/gen_bot_names.py`).
- `engine/bridge/src/bw_ai_params.h`: the numbers (`ai_tunables`, kept per
  player and saved with it) and tables (`ai_tables`).
- `engine/bridge/src/bw_ai.h`: the facts and actions (`script_host`) and
  where events fire.
- `bw_bridge_bot_compile` and `bw_bridge_set_bot_profile` (bw_bridge.h);
  `BwEngine.compileBot` and `setBotProfile`; `lib/game/bot_profiles.dart`.

Tests: `engine/bridge/tests/botscript_test.cpp` (the language, and that
`standard` is exactly the built-in player), `BOTS_ONLY=1
bridge_smoke_test` (a game with profiles plays on identically from a
saved state and from its replayed log), `test/bot_profiles_test.dart`,
and `test/probe/ai_probe.dart --dart-define=BOTS=,rusher,turtle` to watch
them play.
