# Agent API

Programs and LLMs can take part in the home server's multiplayer games
(`tool/brood_server.dart`). `tool/brood_agent.dart` is an agent without a
screen. It follows one player of a game and runs the same simulation as
every other player (lockstep), so it always knows the whole game. It
offers that player's view and actions:

- **over HTTP** on `127.0.0.1` (JSON), for scripts and tools;
- **over MCP** (Model Context Protocol, `--mcp`, on stdin and stdout), for
  LLM clients such as Claude Code or Claude Desktop.

## Three ways to take part

- **Assist a computer player** (`--game G --slot S`). The computer keeps
  playing by itself. The agent may steer it (attack now, hold, which enemy
  first, any of the numbers its bot profile plays by) and may command its
  units, buildings and alliances.
- **Assist a human player** (`--game G --slot S` with a human's slot). The
  agent sends advice, which appears in that person's game. In their game
  menu (Esc) the person chooses what assistants may do:
  - **Advise**: advice only (the default).
  - **Auto-play**: assistants may also steer the person's auto-play, and
    switch its modes (resources, building, attacking, colonizing).
  - **Command**: assistants may also command everything the person's units
    do.
- **Play** (`--host <map>`). The agent starts a new game in the human's
  seat against computer opponents (with bot profiles if wanted). People join
  it from the lobby, and other agents may assist it.

The server enforces these rules: an assistant's commands must be for its
own player and within what is allowed, and never change the game's own
settings.

## Running it

Start the server once (`dart run tool/brood_server.dart`; it needs no
browser build for agents). Then:

```sh
# The games running, their players and who assists them:
dart run tool/brood_agent.dart --list

# Assist player 2 of game 1, with the HTTP API on port 9292:
dart run tool/brood_agent.dart --game 1 --slot 2 --name "Strategist"

# Host a game: you (the agent) as Terran, auto-play on, against a Rusher and a Protoss:
dart run tool/brood_agent.dart --host "maps/ladder/(4)Lost Temple.scm" \
    --race terran --opponents zerg:rusher,protoss --autoplay all
```

Options:

| Option | Meaning |
|---|---|
| `--server` | WebSocket address (`ws://127.0.0.1:9191/ws`) |
| `--data` | the game folder (`BROOD_DATA`) |
| `--http` | port (9292; 0 for none) |
| `--mcp` | speak MCP on stdin/stdout |
| `--name` | the name players see |
| `--fog` | see only what the player sees (the game has fog of war off for now) |
| `--seed` | seed for `--host` |

The engine library is `engine/bridge/build/libbwbridge.so` (run from the
repository), or wherever `BROOD_BRIDGE_LIB` points.

To use it from Claude Code, run from the repository:

```sh
claude mcp add brood -- dart run tool/brood_agent.dart --mcp --http 0 --game 1 --slot 2 --name Claude
```

## HTTP

`GET /` lists the endpoints.

| Request | Gives |
|---|---|
| `GET /describe` | the game in a few lines of text (a good LLM prompt) |
| `GET /state` | time, your resources and supply, your units and buildings by type, every player (alliance, army value, workers, mining rate, score, invitations, surrender offers, who fights whom), enemy units by type, what you may do, state hashes |
| `GET /units?owner=me\|enemies\|allies\|all\|resources\|<slot>&type=<name>` | units with id, type, owner, position (pixels), hit points, shields, energy, queue, research |
| `GET /map` | size, your base, mineral fields and geysers |
| `GET /events?after=<seq>` | alliance events, advice, permission changes, pauses, errors |
| `GET /numbers` | the names `steer` can set |
| `GET /names` | unit, tech and upgrade names |
| `POST /act` | one action (below); `{"ok": true, ...}` or `{"ok": false, "error": ...}` |

Names are the bot profile names in lower case: `terran_marine`,
`zerg_spawning_pool`, `stim_packs`, `u_238_shells`. Positions are in pixels
(32 per tile). Buildings are placed by tile.

## Actions

Each action is a `POST /act` body. An MCP tool takes the same fields
under the same name.

```jsonc
{"action": "advise", "text": "Their army is out: hit the natural now."}

// The built-in AI that plays for this player (a computer, or a human's auto-play):
{"action": "steer", "attack": true}                      // the next wave goes now
{"action": "steer", "hold_seconds": 90}                  // army home, no wave for 90 s
{"action": "steer", "focus_player": 2}                   // that player's buildings first (-1: nearest)
{"action": "steer", "wave_size": 20}                     // the next wave waits for 20 units
{"action": "steer", "numbers": {"army.wave_max": 30, "diplomacy.betray_after": 600}}
{"action": "set_autoplay", "modes": "resources,building"}   // or "all", "off"

// Units (needs Command for a human's player):
{"action": "command_units", "units": [75416, 75417], "order": "attack", "x": 1000, "y": 1000}
{"action": "command_units", "units": [75416], "order": "smart", "target": 80211}
{"action": "train", "building": 75201, "unit": "terran_marine", "count": 3}
{"action": "build", "building": "terran_barracks"}       // room found near your base, worker picked
{"action": "build", "building": "terran_bunker", "x": 1800, "y": 600, "worker": 75416}
{"action": "research", "building": 75300, "tech": "stim_packs"}
{"action": "research", "building": 75310, "upgrade": "terran_infantry_weapons"}
{"action": "diplomacy", "what": "invite", "player": 3}   // accept, decline, leave, surrender,
                                                         // accept_surrender, refuse_surrender, open, close
{"action": "pause", "on": true}
{"action": "allow", "level": 1}                          // in the human's seat (--host): what its assistants may do
```

Commands run when they come back from the server, a few frames later, as
everyone's do. `/state` and `/events` show their effect. An order the game
refuses (a unit that can't do it, the wrong place) does nothing. Orders
that cost money are checked first, since the game drops what it can't pay
for without a word.

MCP also has `describe_game`, `get_state`, `list_units`, `get_map`,
`get_events`, `get_numbers` and `wait` (lets the game run some seconds,
then describes it).

## How it stays in sync

Every client and agent runs the same deterministic simulation from the
same command log. An agent's commands enter that log like a player's.
Steering is a logged engine command (`bw_bridge_bot_steer`,
`BW_STEER_*`), so every client applies it at the same frame, and saved
games replay it. Unit commands are wrapped in `bw_bridge_keep_selection`,
so a person keeps what they had selected while their assistant orders
other units. `/state` lists the agent's state hash every 240 frames,
the same numbers players report to the server (which says when they
differ).

## Limits

- **Real time.** The game runs at about 24 frames a second whatever the
  agent does. An LLM thinks in seconds, so steering the built-in AI and
  giving advice suit it better than ordering single units.
- **Home network.** The server listens on the home network and trusts it:
  anyone there can assist a computer player. A human's player is
  protected by their own permission switch.
- **Not saved.** Advice is not kept in saved games; steering and commands
  are.
