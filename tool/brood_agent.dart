// tool/brood_agent.dart
//
// An agent for the home server's multiplayer games (docs/agent_api.md): a
// program without a screen that follows one player of a game, so scripts
// and LLMs can watch it and play or help. It runs the same simulation as
// every other player (lockstep, tool/brood_server.dart), and offers:
//   - an HTTP API on 127.0.0.1 (JSON; GET / lists it), and
//   - with --mcp, the Model Context Protocol on stdin/stdout, for LLM tools.
//
//   dart run tool/brood_agent.dart --list
//   dart run tool/brood_agent.dart --game 1 --slot 2 [--name Claude]
//   dart run tool/brood_agent.dart --host "maps/ladder/(4)Lost Temple.scm" \
//       --race terran --opponents zerg:rusher,protoss,terran:turtle [--autoplay all]
//
// --game/--slot assists a player of a running game: a computer player (the
// agent may command it fully; it keeps playing by itself) or a human (who
// gets the agent's advice, and decides in their game menu whether it may
// steer their auto-play or command their units). --host starts a new game
// with the agent in the human's seat; people join it from the lobby.
//
// --strategist has Claude revise this player's strategy, numbers and
// alliances every --every seconds (30), with --model (claude-opus-5-5),
// --effort (medium) and an optional --goal "..." in the player's words.
// It needs ANTHROPIC_API_KEY (or ANTHROPIC_AUTH_TOKEN, or `ant auth login`)
// and costs a request or a few each round. --provider openrouter, ollama,
// huggingface or openai (with --base-url) uses an OpenAI-compatible server
// instead (keys: OPENROUTER_API_KEY, HF_TOKEN, OPENAI_API_KEY, or
// --key-file; none for a local Ollama), with a fitting --model.
//
// Other options: --server ws://127.0.0.1:9191/ws, --data <game folder>
// (BROOD_DATA), --http <port> (9292; 0: none), --mcp, --fog (see only what
// the player sees; the game itself has fog of war off for now). The engine
// library is engine/bridge/build/libbwbridge.so, or BROOD_BRIDGE_LIB.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:brood/engine/bot_names.dart';
import 'package:brood/engine/bw_engine.dart';
import 'package:brood/engine/models.dart';
import 'package:brood/game/bot_bundle.dart';

const raceNames = ['zerg', 'terran', 'protoss'];
const autoplayModes = {'resources': 1, 'building': 2, 'attacking': 4, 'colonizing': 8};
const allianceEventNames = [
  '', 'invited', 'declined', 'formed', 'left', 'open', 'closed', 'offers surrender', 'surrendered', 'surrender refused', 'vassal moved', 'kicked',
];

bool mcpMode = false;
void log(String s) => stderr.writeln('brood_agent: $s');

Future<void> main(List<String> args) async {
  String? arg(String name) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  bool flag(String name) => args.contains('--$name');
  if (flag('help') || args.isEmpty) {
    stdout.writeln(File.fromUri(Platform.script).readAsLinesSync().takeWhile((l) => l.startsWith('//')).join('\n'));
    return;
  }
  mcpMode = flag('mcp');
  final home = Platform.environment['HOME'] ?? '.';
  final agent = Agent(
    server: arg('server') ?? 'ws://127.0.0.1:9191/ws',
    dataDir: arg('data') ?? Platform.environment['BROOD_DATA'] ?? '$home/box/media/games/BROOD',
    name: arg('name') ?? 'Agent',
    fog: flag('fog'),
  );
  try {
    await agent.connect();
    if (flag('list')) {
      final games = await agent.listGames();
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(games));
      exit(0);
    }
    if (arg('host') case final map?) {
      final opponents = [
        for (final o in (arg('opponents') ?? 'random').split(','))
          if (o.trim().isNotEmpty) o.trim(),
      ];
      await agent.host(map, race: arg('race') ?? 'terran', opponents: opponents, seed: int.tryParse(arg('seed') ?? ''));
    } else {
      final game = int.tryParse(arg('game') ?? ''), slot = int.tryParse(arg('slot') ?? '');
      if (game == null || slot == null) throw StateError('give --game and --slot (see --list), or --host <map>');
      await agent.assist(game, slot);
    }
    if (arg('autoplay') case final modes?) log(jsonEncode(agent.act({'action': 'set_autoplay', 'modes': modes})));
  } catch (e) {
    log('$e');
    exit(1);
  }
  final port = int.tryParse(arg('http') ?? '9292') ?? 9292;
  if (port > 0) await HttpApi(agent).serve(port);
  if (flag('strategist')) {
    // Where the model runs: Anthropic, or an OpenAI-compatible server.
    final provider = arg('provider') ?? 'anthropic';
    const bases = {'openrouter': 'https://openrouter.ai/api/v1', 'ollama': 'http://127.0.0.1:11434/v1', 'huggingface': 'https://router.huggingface.co/v1'};
    const models = {'openrouter': 'nvidia/nemotron-3-super-120b-a12b:free', 'ollama': 'qwen3:8b', 'huggingface': 'Qwen/Qwen3-32B'};
    const keys = {'openrouter': 'OPENROUTER_API_KEY', 'huggingface': 'HF_TOKEN', 'openai': 'OPENAI_API_KEY'};
    String? key;
    if (arg('key-file') case final f?) key = File(f).readAsStringSync().trim();
    key ??= Platform.environment[keys[provider] ?? ''];
    final strategist = Strategist(
      agent,
      every: (int.tryParse(arg('every') ?? '') ?? 30).clamp(10, 3600),
      model: arg('model') ?? models[provider] ?? 'claude-opus-5-5',
      effort: arg('effort') ?? 'medium',
      goal: arg('goal') ?? '',
      provider: provider == 'anthropic' ? 'anthropic' : 'openai',
      baseUrl: arg('base-url') ?? bases[provider] ?? '',
      apiKey: key,
    );
    if (strategist.provider == 'openai' && strategist.baseUrl.isEmpty) {
      log('--provider $provider needs --base-url');
      exit(1);
    }
    strategist.start();
  }
  if (mcpMode) await Mcp(agent).serve();
}

// --- following a game ----------------------------------------------------------------

class Agent {
  final String server, dataDir, name;
  final bool fog;
  Agent({required this.server, required this.dataDir, required this.name, required this.fog});

  late WebSocket _ws;
  late BwEngine e;
  int gameId = -1;
  int slot = -1;
  bool assistant = false;
  int allow = 2; // what this agent may command (see Game.level in the server)
  Map<String, dynamic> launch = const {};
  List<Map<String, dynamic>> slots = const [];
  Map<int, String> humans = {};
  int upTo = 0;
  bool paused = false;
  bool ready = false;
  bool outOfSync = false;
  final SplayTreeMap<int, List<int>> _pending = SplayTreeMap();
  Completer<Map<String, dynamic>>? _waiting;
  String? _waitingFor;

  /// What happened, newest last: alliance events, the server's messages.
  final List<Map<String, Object?>> events = [];
  int _eventSeq = 0;

  /// State hashes every 240 frames (to compare with other players).
  final SplayTreeMap<int, int> hashes = SplayTreeMap();

  late final List<String> numberNames;

  Future<void> connect() async {
    e = await BwEngine.open();
    e.loadAssets(dataDir);
    numberNames = e.botNumbers(const {}, null).values.keys.toList();
    _ws = await WebSocket.connect(server);
    _ws.listen((data) => _message(jsonDecode(data as String) as Map<String, dynamic>), onDone: () {
      log('the server closed the connection');
      exit(2);
    });
    _send({'t': 'hello', 'name': name});
  }

  void _send(Map<String, Object?> m) => _ws.add(jsonEncode(m));

  Future<Map<String, dynamic>> _await(String type) {
    _waitingFor = type;
    return (_waiting = Completer()).future.timeout(const Duration(seconds: 15));
  }

  void event(String kind, Map<String, Object?> detail) {
    events.add({'seq': ++_eventSeq, 'frame': ready ? e.currentFrame : 0, 'kind': kind, ...detail});
    if (events.length > 500) events.removeRange(0, events.length - 500);
  }

  Future<List<Object?>> listGames() async {
    final f = _await('games');
    _send({'t': 'list'});
    return (await f)['games'] as List;
  }

  /// Follows player [slot] of game [game] as its assistant.
  Future<void> assist(int game, int slot) async {
    final f = _await('joined');
    _send({'t': 'assist', 'game': game, 'slot': slot});
    final m = await f;
    await _startJoined(m);
  }

  Future<void> _startJoined(Map<String, dynamic> m) async {
    gameId = m['game'] as int;
    slot = m['slot'] as int;
    assistant = m['assistant'] == true;
    allow = m['allow'] as int? ?? 0;
    launch = Map<String, dynamic>.from(m['launch'] as Map);
    slots = [for (final s in m['slots'] as List) Map<String, dynamic>.from(s as Map)];
    upTo = m['upTo'] as int;
    paused = m['paused'] == true;
    final setup = Map<String, dynamic>.from(launch['setup'] as Map);
    final players = [for (final p in setup['players'] as List) Map<String, dynamic>.from(p as Map)];
    final botFiles = {for (final x in (setup['botFiles'] as Map? ?? const {}).entries) x.key as String: x.value as String};
    for (int i = 0; i < players.length; ++i) {
      final bot = players[i]['bot'] as String? ?? '';
      if (players[i]['human'] != true && bot.isNotEmpty && !e.setBotProfile(i, botFiles, bot)) {
        throw StateError('bot profile $bot: ${e.compileBot(botFiles, bot).error}');
      }
    }
    e.newGame('$dataDir/${launch['mapKey']}', [
      for (final p in players) (human: p['human'] == true, race: (p['race'] as num).toInt(), team: (p['team'] as num?)?.toInt() ?? 0),
    ], (setup['seed'] as num).toInt());
    // The game so far: its log up to the server's clock; later commands wait.
    final initial = [for (final v in m['log'] as List) v as int];
    final log = <int>[];
    for (int i = 0; i + 3 <= initial.length;) {
      final k = 3 + initial[i + 2];
      final entry = initial.sublist(i, i + k);
      if (entry[0] <= upTo) {
        log.addAll(entry);
      } else {
        _pending[entry[0]] = [...entry, ...?_pending[entry[0]]];
      }
      i += k;
    }
    for (final f in _pending.keys.where((f) => f <= upTo).toList()) {
      log.addAll(_pending.remove(f)!);
    }
    await e.replayCommands(log, upTo);
    _begin();
  }

  /// A new game on the server with this agent in the human's seat.
  /// [opponents]: "race" or "race:profile" each (race: zerg, terran,
  /// protoss or random).
  Future<void> host(String mapKey, {required String race, required List<String> opponents, int? seed}) async {
    seed ??= DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
    var rng = seed;
    int pickRace(String r) {
      final i = raceNames.indexOf(r.toLowerCase());
      if (i >= 0) return i;
      rng = (rng * 1103515245 + 12345) & 0x7fffffff;
      return rng % 3;
    }

    final bots = _botFiles();
    final players = <Map<String, Object?>>[
      {'human': true, 'race': pickRace(race), 'team': 0},
      for (final o in opponents)
        {'human': false, 'race': pickRace(o.split(':').first), 'team': 0, if (o.contains(':')) 'bot': o.split(':')[1]},
    ];
    final used = <String, String>{};
    for (final p in players) {
      if (p['bot'] case final String bot) {
        final files = botFilesOf(bots, bot);
        if (files.isEmpty) throw StateError('no bot profile "$bot" in assets/bots or $dataDir/bots');
        used.addAll(files);
      }
    }
    for (int i = 0; i < players.length; ++i) {
      if (players[i]['bot'] case final String bot) {
        if (!e.setBotProfile(i, used, bot)) throw StateError('bot profile $bot: ${e.compileBot(used, bot).error}');
      }
    }
    final mapFile = '$dataDir/$mapKey';
    if (!File(mapFile).existsSync()) throw StateError('no map $mapFile');
    final slotOf = e.newGame(mapFile, [for (final p in players) (human: p['human'] == true, race: p['race'] as int, team: 0)], seed);
    if (slotOf.first < 0) throw StateError('the map has no start location for the agent');
    final mapName = mapKey.split('/').last.replaceAll(RegExp(r'\.sc[mx]$', caseSensitive: false), '');
    final setup = {
      'players': players,
      'alliances': 'freeForAll',
      'seed': seed,
      'shareSwitch': true,
      'wideIds': true,
      'allianceCap': true,
      'aiV2': true,
      if (used.isNotEmpty) 'botFiles': used,
    };
    var computer = 0;
    final f = _await('joined');
    _send({
      't': 'create',
      'launch': {'mapKey': mapKey, 'mapName': mapName, 'setup': setup},
      'slots': [
        for (int i = 0; i < players.length; ++i)
          if (slotOf[i] >= 0) {'slot': slotOf[i], 'race': players[i]['race'], 'name': i == 0 ? name : _computerName(players[i], used, ++computer)},
      ],
      'slot': slotOf.first,
      'log': e.commandLog(),
      'frame': e.currentFrame,
    });
    final m = await f;
    gameId = m['game'] as int;
    slot = m['slot'] as int;
    assistant = false;
    allow = 2;
    launch = Map<String, dynamic>.from(m['launch'] as Map);
    slots = [for (final s in m['slots'] as List) Map<String, dynamic>.from(s as Map)];
    upTo = m['upTo'] as int;
    _begin();
  }

  /// As the app names them: after the profile, else "Computer n".
  String _computerName(Map<String, Object?> p, Map<String, String> files, int n) {
    final bot = p['bot'] as String?;
    final profile = bot == null ? '' : e.compileBot(files, bot).name;
    return profile.isEmpty ? 'Computer $n' : '$profile $n';
  }

  /// The shipped bot profiles (assets/bots) and the player's (bots/ in the
  /// game folder).
  Map<String, String> _botFiles() {
    final out = <String, String>{};
    for (final root in ['assets/bots', '$dataDir/bots']) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync(recursive: true, followLinks: true).whereType<File>()) {
        if (f.path.endsWith('.bot')) out[f.path.substring(dir.path.length + 1)] = f.readAsStringSync();
      }
    }
    return out;
  }

  void _begin() {
    e.setDeferred(true);
    e.setViewer(fog ? slot : -1);
    ready = true;
    log('${assistant ? 'assisting' : 'playing'} slot $slot (${playerName(slot)}) of game $gameId on ${launch['mapName']}');
    Timer.periodic(const Duration(milliseconds: 15), (_) => _run());
  }

  void _run() {
    var now = e.currentFrame;
    // Far behind (joining, a stall): catch up quickly.
    var steps = upTo - now > 24 ? 240 : 2;
    while (steps-- > 0 && now < upTo) {
      final cmds = _pending.remove(now);
      if (cmds != null) e.applyCommands(cmds);
      e.step(1);
      now = e.currentFrame;
      if (now % 240 == 0) {
        final h = e.stateHash();
        hashes[now] = h;
        while (hashes.length > 30) {
          hashes.remove(hashes.firstKey());
        }
        if (!assistant) {
          final al = e.alliances();
          _send({'t': 'report', 'frame': now, 'hash': h, 'groups': [for (final a in al) a.group], 'active': [for (final a in al) a.active ? 1 : 0]});
        }
      }
    }
    for (final ev in e.pollAllianceEvents()) {
      if (ev.kind == AllianceEventKind.open || ev.kind == AllianceEventKind.closed) continue;
      event('alliance', {'what': allianceEventNames[ev.kind.index], 'a': ev.a, 'b': ev.b});
    }
  }

  void _message(Map<String, dynamic> m) {
    final t = m['t'] as String?;
    if (t == _waitingFor && _waiting != null) {
      final w = _waiting!;
      _waiting = null;
      _waitingFor = null;
      w.complete(m);
      return;
    }
    switch (t) {
      case 'cmd':
        final frame = m['frame'] as int;
        final entries = [for (final v in m['entries'] as List) v as int];
        for (int i = 0; i + 3 <= entries.length; i += 3 + entries[i + 2]) {
          entries[i] = frame;
        }
        _pending.putIfAbsent(frame, () => []).addAll(entries);
      case 'tick':
        upTo = m['upTo'] as int;
      case 'paused':
        paused = m['on'] == true;
        event('paused', {'on': paused, 'by': m['by']});
      case 'players':
        humans = {for (final x in (m['names'] as Map).entries) int.parse(x.key as String): x.value as String};
        event('players', {'humans': {for (final x in humans.entries) '${x.key}': x.value}});
      case 'allow':
        allow = m['level'] as int? ?? 0;
        event('allow', {'level': allow});
      case 'desync':
        outOfSync = true;
        event('desync', {'frame': m['frame']});
      case 'advice':
        event('advice', {'from': m['from'], 'text': m['text']});
      case 'error':
        final w = _waiting;
        if (w != null) {
          _waiting = null;
          _waitingFor = null;
          w.completeError(StateError(m['message'] as String? ?? 'refused'));
        } else {
          event('error', {'message': m['message']});
          log('server: ${m['message']}');
        }
    }
  }

  /// Sends what the engine queued (commands run when they come back from
  /// the server, as everyone's do).
  void _flush() {
    final out = e.takeOutbox();
    if (out.isNotEmpty) _send({'t': 'cmd', 'entries': out});
  }

  // --- what the agent sees ---

  String playerName(int s) {
    if (humans[s] case final h?) return h;
    for (final x in slots) {
      if (x['slot'] == s) return x['name'] as String? ?? 'Player $s';
    }
    return 'Player $s';
  }

  static String typeName(int id) => id >= 0 && id < unitNames.length ? unitNames[id] : 'type_$id';

  static String clock(int frame) {
    final s = frame * 42 ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  List<UnitInfo> _units() => e.getUnits();

  Map<String, Object?> unitJson(UnitInfo u) => {
    'id': u.unitId,
    'type': typeName(u.typeId),
    'owner': u.owner,
    'x': u.x,
    'y': u.y,
    'hp': u.hp,
    'max_hp': u.maxHp,
    if (u.maxShields > 0) 'shields': u.shields,
    if (u.maxEnergy > 0) 'energy': u.energy,
    if (u.isBuilding) 'building': true,
    if (!u.isCompleted) 'completed': false,
    if (u.isWorker) 'worker': true,
    if (u.isFlyer) 'flyer': true,
    if (u.isResource) 'resources': u.resources,
    if (u.queue.isNotEmpty) 'queue': [for (final q in u.queue) typeName(q)],
    if (u.researchingTech >= 0) 'researching': techNames.length > u.researchingTech ? techNames[u.researchingTech] : u.researchingTech,
    if (u.upgrading >= 0) 'upgrading': upgradeNames.length > u.upgrading ? upgradeNames[u.upgrading] : u.upgrading,
  };

  /// What this agent may do now.
  Map<String, bool> get can => {
    'advise': assistant && humans.containsKey(slot),
    'steer': allow >= 1,
    'command': allow >= 2,
  };

  Map<String, int> _count(Iterable<UnitInfo> units) {
    final out = SplayTreeMap<String, int>();
    for (final u in units) {
      final n = typeName(u.typeId) + (u.isCompleted ? '' : ' (in progress)');
      out[n] = (out[n] ?? 0) + 1;
    }
    return out;
  }

  Map<String, Object?> state() {
    final units = _units();
    final al = e.alliances();
    final me = al.length > slot ? al[slot] : null;
    final race = me?.race ?? 0;
    final supply = e.supply(slot, race);
    final mine = units.where((u) => u.owner == slot).toList();
    final modes = e.autoplay(slot);
    return {
      'game': gameId,
      'map': launch['mapName'],
      'frame': e.currentFrame,
      'time': clock(e.currentFrame),
      'paused': paused,
      'out_of_sync': outOfSync,
      'me': slot,
      'role': assistant ? (humans.containsKey(slot) ? 'assistant of a human' : 'assistant of a computer player') : 'player',
      'can': can,
      'mine': _mine(mine, race, supply, modes),
      'players': [
        for (final s in slots)
          if (al.length > (s['slot'] as int))
            _playerJson(al[s['slot'] as int], me),
      ],
      'enemy_units_seen': {
        for (final s in slots)
          if (s['slot'] != slot && me != null && al.length > (s['slot'] as int) && al[s['slot'] as int].group != me.group)
            '${s['slot']}': _count(units.where((u) => u.owner == s['slot'])),
      },
      'hashes': {for (final h in hashes.entries) '${h.key}': h.value},
    };
  }

  Map<String, Object?> _mine(List<UnitInfo> mine, int race, (double, double) supply, int modes) => {
    'name': playerName(slot),
    'race': raceNames[race.clamp(0, 2)],
    'minerals': e.minerals(slot),
    'gas': e.gas(slot),
    'supply_used': supply.$1,
    'supply_max': supply.$2,
    'autoplay': [for (final x in autoplayModes.entries) if (modes & x.value != 0) x.key],
    'units': _count(mine.where((u) => !u.isBuilding)),
    'buildings': _count(mine.where((u) => u.isBuilding)),
  };

  Map<String, Object?> _playerJson(AlliancePlayer p, AlliancePlayer? me) => {
    'slot': p.slot,
    'name': playerName(p.slot),
    'race': raceNames[p.race.clamp(0, 2)],
    'human': humans.containsKey(p.slot),
    'me': p.slot == slot,
    'ally': me != null && p.slot != slot && p.group == me.group,
    'active': p.active,
    'alliance': p.group,
    if (p.lord >= 0) 'surrendered_to': p.lord,
    'army_value': p.armyValue,
    'workers': p.workers,
    'mining_per_minute': p.mineralRate + p.gasRate,
    'score': p.points + p.productionScore + p.killScore,
    'units_lost': p.unitsLost,
    if (p.invitedBy != 0) 'invited_by': [for (int i = 0; i < 8; ++i) if (p.invitedBy & (1 << i) != 0) i],
    if (p.surrenderFrom != 0) 'surrender_offers_from': [for (int i = 0; i < 8; ++i) if (p.surrenderFrom & (1 << i) != 0) i],
    if (p.fighting != 0) 'fighting': [for (int i = 0; i < 8; ++i) if (p.fighting & (1 << i) != 0) i],
  };

  /// The strategies this player can be switched to, and the one in use.
  Map<String, Object?> strategies() {
    final s = e.botStrategies(slot);
    return {
      'current': s.current.isEmpty ? 'none (the profile\'s own way)' : s.current,
      if (s.current.isNotEmpty && s.target >= 0) 'target': s.target,
      'army': s.armyStatus,
      'strategies': [
        for (final x in s.list) {'name': x.name, 'target': x.takesTarget ? 'a player slot' : 'none', 'description': x.description},
      ],
      'note': s.list.isEmpty
          ? 'This player has no bot profile with strategies (a human\'s auto-play, or the plain standard player): steer its numbers instead.'
          : 'A strategy starts from the profile\'s own numbers; numbers steered before are reset. "none" goes back to the profile.',
    };
  }

  /// Every player as this one's diplomacy sees them: alliances, strength,
  /// how much it wants them as allies, the favor steered for them.
  Map<String, Object?> alliances() {
    final al = e.alliances();
    final me = al.length > slot ? al[slot] : null;
    final rel = {for (final r in e.botDiplomacy(slot)) r.slot: r};
    final groups = <int, List<int>>{};
    for (final a in al) {
      if (a.active) groups.putIfAbsent(a.group, () => []).add(a.slot);
    }
    return {
      'me': slot,
      'my_alliance': me == null ? [] : groups[me.group] ?? [slot],
      'open_to_invitations': me?.open,
      'rules': 'An alliance holds at most 3 members, and never every player left. Allies share resources (if switched on), techs and mining '
          'score; a vassal (surrendered) pays half its mining to its lord. Once a human is in an alliance, only humans let players in.',
      'alliances': [
        for (final g in groups.entries)
          {'members': [for (final m in g.value) '${playerName(m)} (slot $m)'], if (g.value.contains(slot)) 'mine': true},
      ],
      'players': [
        for (final a in al)
          if (a.active && a.slot != slot)
            {
              'slot': a.slot,
              'name': playerName(a.slot),
              'race': raceNames[a.race.clamp(0, 2)],
              'human': humans.containsKey(a.slot),
              'relation': me != null && a.group == me.group ? 'ally' : 'enemy',
              if (a.lord >= 0) 'vassal_of': a.lord,
              'open': a.open,
              'army_value': a.armyValue,
              'mining_per_minute': a.mineralRate + a.gasRate,
              if (rel[a.slot] case final r?) ...{
                'alliance_strength': r.strength,
                'utility': r.utility,
                'favor': r.favor,
                'we_lost_to_them_lately': r.lost,
                'distance': r.distance,
              },
              if (me != null && me.fighting & (1 << a.slot) != 0) 'fighting_us': true,
              if (me != null && me.invitedBy & (1 << a.slot) != 0) 'invites_us': true,
              if (me != null && me.surrenderFrom & (1 << a.slot) != 0) 'offers_to_surrender': true,
            },
      ],
      'how_to_read': 'utility: how much this player\'s own diplomacy wants that alliance (it invites and accepts above about 40). '
          'favor (-100 never ... 100 always) is added to utility; at 100 it always accepts their invitation, at -100 never; '
          'negative favor toward an ally makes turning on them easier. Set it with set_relations.',
    };
  }

  List<Map<String, Object?>> units({String owner = 'me', String? type}) {
    final al = e.alliances();
    final myGroup = al.length > slot ? al[slot].group : -1;
    bool pick(UnitInfo u) {
      if (type != null && typeName(u.typeId) != type) return false;
      switch (owner) {
        case 'me':
          return u.owner == slot;
        case 'all':
          return true;
        case 'enemies':
          return u.owner < 8 && u.owner != slot && al.length > u.owner && al[u.owner].group != myGroup;
        case 'allies':
          return u.owner < 8 && u.owner != slot && al.length > u.owner && al[u.owner].group == myGroup;
        case 'resources':
          return u.isResource;
        default:
          return u.owner == int.tryParse(owner);
      }
    }

    return [for (final u in _units()) if (pick(u)) unitJson(u)];
  }

  Map<String, Object?> map() {
    final (w, h) = e.getMapTileSize();
    final mine = _units().where((u) => u.owner == slot && u.isBuilding).toList();
    return {
      'name': launch['mapName'],
      'width_tiles': w,
      'height_tiles': h,
      'width': w * 32,
      'height': h * 32,
      'note': 'Positions are in pixels (32 per tile); buildings are placed by tile.',
      if (mine.isNotEmpty) 'my_base': {'x': mine.first.x, 'y': mine.first.y},
      'resources': [
        for (final u in _units())
          if (u.isResource) {'id': u.unitId, 'type': typeName(u.typeId), 'x': u.x, 'y': u.y, 'amount': u.resources},
      ],
    };
  }

  /// The game in a few lines of text, for an LLM's context.
  String describe() {
    final s = state();
    final mine = s['mine'] as Map<String, Object?>;
    final b = StringBuffer()
      ..writeln('${s['map']}, ${s['time']} (frame ${s['frame']})${paused ? ', paused' : ''}${outOfSync ? ', OUT OF SYNC' : ''}.')
      ..writeln('You are slot $slot, ${mine['name']} (${mine['race']}), ${s['role']}. '
          'You may ${[if (can['advise']!) 'advise', if (can['steer']!) 'steer the AI', if (can['command']!) 'command units'].join(', ')}.')
      ..writeln('Resources: ${mine['minerals']} minerals, ${mine['gas']} gas, supply ${_n(mine['supply_used'])}/${_n(mine['supply_max'])}. '
          'Auto-play: ${(mine['autoplay'] as List).isEmpty ? 'off' : (mine['autoplay'] as List).join(', ')}.')
      ..writeln('Your units: ${_list(mine['units'])}.')
      ..writeln('Your buildings: ${_list(mine['buildings'])}.');
    // Where this player stands against the others, in plain words.
    final players = [for (final p in s['players'] as List) p as Map<String, Object?>];
    final me = players.where((p) => p['me'] == true).firstOrNull;
    if (me != null) {
      final enemies = players.where((p) => p['me'] != true && p['ally'] != true && p['active'] == true).toList();
      int army(Map<String, Object?> p) => (p['army_value'] as int?) ?? 0;
      int mining(Map<String, Object?> p) => (p['mining_per_minute'] as int?) ?? 0;
      b.writeln('Your army value ${army(me)}, mining ${mining(me)}/min, ${me['workers']} workers.');
      if (enemies.isNotEmpty) {
        final strongest = enemies.reduce((a, c) => army(a) >= army(c) ? a : c);
        final weakest = enemies.reduce((a, c) => army(a) <= army(c) ? a : c);
        if (army(strongest) > army(me) * 2 && army(strongest) > 500) {
          b.writeln('WARNING: ${strongest['name']} (slot ${strongest['slot']}) has ${army(strongest)} army value, more than twice yours: '
              'you need an army (defend, build_up) or allies.');
        }
        if (army(me) > army(weakest) * 2 && army(me) > 500) {
          b.writeln('OPPORTUNITY: your army is more than twice ${weakest['name']}\'s (slot ${weakest['slot']}, ${army(weakest)}).');
        }
      }
    }
    b.writeln('Players:');
    for (final p in s['players'] as List) {
      final m = p as Map<String, Object?>;
      if (m['me'] == true) continue;
      final rel = m['ally'] == true ? 'ally' : 'enemy';
      b.writeln('  slot ${m['slot']} ${m['name']} (${m['race']}${m['human'] == true ? ', human' : ''}): $rel, '
          '${m['active'] == true ? '' : 'OUT, '}army ${m['army_value']}, ${m['workers']} workers, mining ${m['mining_per_minute']}/min, score ${m['score']}'
          '${m['invited_by'] != null ? ', invited by ${m['invited_by']}' : ''}');
    }
    final st = e.botStrategies(slot);
    if (st.list.isNotEmpty) {
      b.writeln('Strategy: ${st.current.isEmpty ? 'none (the profile\'s own way)' : st.current}${st.current.isNotEmpty && st.target >= 0 ? ' against slot ${st.target}' : ''}. '
          'Available: ${[for (final x in st.list) x.takesTarget ? '${x.name}(target)' : x.name].join(', ')}.');
      b.writeln('Army: ${st.armyStatus}. (steer attack:true sends it now; wave_size lowers what it waits for.)');
      final al = e.alliances();
      if (st.current.isNotEmpty && st.target >= 0 && st.target < al.length && !al[st.target].active) {
        b.writeln('WARNING: the target of your strategy, slot ${st.target}, is out of the game: choose another.');
      }
    }
    final rel = e.botDiplomacy(slot);
    if (rel.isNotEmpty) {
      b.writeln('Diplomacy (utility / favor): ${[for (final r in rel) 'slot ${r.slot} ${r.utility}/${r.favor}'].join(', ')}.');
    }
    final seen = s['enemy_units_seen'] as Map;
    for (final x in seen.entries) {
      b.writeln('Enemy slot ${x.key} has: ${_list(x.value)}.');
    }
    final recent = events.length > 8 ? events.sublist(events.length - 8) : events;
    if (recent.isNotEmpty) {
      b.writeln('Recent events:');
      for (final ev in recent) {
        b.writeln('  ${clock(ev['frame'] as int)} ${ev['kind']}: ${Map.of(ev)..removeWhere((k, _) => k == 'seq' || k == 'frame' || k == 'kind')}');
      }
    }
    return b.toString();
  }

  static String _n(Object? v) => v is double && v == v.roundToDouble() ? '${v.toInt()}' : '$v';
  static String _list(Object? counts) {
    final m = counts as Map;
    return m.isEmpty ? 'none' : [for (final x in m.entries) '${x.value} ${x.key}'].join(', ');
  }

  // --- what the agent does ---

  /// One action (docs/agent_api.md); {ok, ...} or {ok: false, error}.
  Map<String, Object?> act(Map<String, dynamic> a) {
    if (!ready) return _fail('not in a game yet');
    try {
      final r = _act(a);
      _flush();
      return r;
    } catch (err) {
      return _fail('$err');
    }
  }

  static Map<String, Object?> _fail(String why) => {'ok': false, 'error': why};

  int _int(Map<String, dynamic> a, String k) {
    final v = a[k];
    if (v is num) return v.toInt();
    if (v is String && int.tryParse(v) != null) return int.parse(v);
    throw ArgumentError('"$k" (a number) is needed');
  }

  int _type(Object? name, List<String> names, String what) {
    final i = names.indexOf('$name'.toLowerCase().trim().replaceAll(' ', '_'));
    if (i < 0) throw ArgumentError('no $what "$name" (names look like ${names.first})');
    return i;
  }

  void _need(String what) {
    if (!can[what]!) {
      throw StateError(switch (what) {
        'advise' => 'advice goes to a human player; this one is a computer',
        _ => 'not allowed: ${playerName(slot)} lets assistants ${allow == 0 ? 'only advise' : 'only steer the auto-play'} (their game menu)',
      });
    }
  }

  List<int> _myUnits(Object? ids) {
    if (ids is! List || ids.isEmpty) throw ArgumentError('"units" (a list of unit ids) is needed');
    final mine = {for (final u in _units()) if (u.owner == slot) u.unitId};
    final out = [for (final v in ids) (v as num).toInt()];
    final foreign = out.where((id) => !mine.contains(id)).toList();
    if (foreign.isNotEmpty) throw ArgumentError('not your units: $foreign');
    return out;
  }

  /// Runs [commands] (which select units) without changing the player's
  /// own selection: a person keeps what they had selected.
  void _asIs(void Function() commands) {
    e.keepSelection(slot, true);
    commands();
    e.keepSelection(slot, false);
  }

  Map<String, Object?> _act(Map<String, dynamic> a) {
    final me = slot;
    switch (a['action']) {
      case 'advise':
        _need('advise');
        final text = '${a['text'] ?? ''}'.trim();
        if (text.isEmpty) throw ArgumentError('"text" is needed');
        _send({'t': 'advice', 'text': text});
        return {'ok': true};
      case 'steer':
        _need('steer');
        final done = <String>[];
        if (a['attack'] == true) {
          e.botSteer(me, 1);
          done.add('attack now');
        }
        if (a['hold_seconds'] != null) {
          e.botSteer(me, 2, _int(a, 'hold_seconds'));
          done.add('hold');
        }
        if (a['focus_player'] != null) {
          e.botSteer(me, 3, _int(a, 'focus_player'));
          done.add('focus');
        }
        if (a['wave_size'] != null) {
          e.botSteer(me, 5, _int(a, 'wave_size'));
          done.add('wave size');
        }
        if (a['numbers'] case final Map numbers) {
          for (final x in numbers.entries) {
            final i = numberNames.indexOf('${x.key}');
            if (i < 0) throw ArgumentError('no number "${x.key}" (see GET /numbers)');
            e.botSteer(me, 4, i, (x.value as num).toInt());
            done.add('${x.key} = ${x.value}');
          }
        }
        if (done.isEmpty) throw ArgumentError('nothing to steer: attack, hold_seconds, focus_player, wave_size or numbers');
        return {'ok': true, 'sent': done};
      case 'set_strategy':
        _need('steer');
        final name = '${a['name'] ?? ''}'.trim();
        if (name.isEmpty || name == 'none') {
          e.botSteer(me, 6, -1);
          return {'ok': true, 'strategy': 'none'};
        }
        final list = e.botStrategies(me).list;
        final st = list.where((x) => x.name == name).firstOrNull;
        if (st == null) throw ArgumentError('no strategy "$name" (${list.map((x) => x.name).join(', ')}, none)');
        var target = -1;
        if (st.takesTarget) {
          target = _int(a, 'target');
          if (target == me || target < 0 || target > 7) throw ArgumentError('target: another player\'s slot');
        }
        e.botSteer(me, 6, st.index, target);
        return {'ok': true, 'strategy': st.name, if (target >= 0) 'target': target};
      case 'set_relations':
        _need('steer');
        final favor = a['favor'];
        if (favor is! Map || favor.isEmpty) throw ArgumentError('"favor": {"<slot>": -100..100, ...}');
        final done = <String, int>{};
        for (final x in favor.entries) {
          final q = int.tryParse('${x.key}');
          if (q == null || q < 0 || q > 7 || q == me) throw ArgumentError('not another player\'s slot: ${x.key}');
          final v = (x.value as num).toInt().clamp(-100, 100);
          e.botSteer(me, 7, q, v);
          done['$q'] = v;
        }
        return {'ok': true, 'favor': done};
      case 'set_autoplay':
        _need('steer');
        final modes = a['modes'];
        var bits = 0;
        if (modes == 'all') {
          bits = 15;
        } else if (modes == 'off' || modes == null) {
          bits = 0;
        } else {
          for (final m in modes is List ? modes : '$modes'.split(',')) {
            final bit = autoplayModes['$m'.trim()];
            if (bit == null) throw ArgumentError('no auto-play mode "$m" (${autoplayModes.keys.join(', ')}, all, off)');
            bits |= bit;
          }
        }
        if (!humans.containsKey(me) && assistant) throw StateError('a computer player plays everything anyway');
        e.setAutoplay(me, bits);
        return {'ok': true, 'modes': bits};
      case 'command_units':
        _need('command');
        final ids = _myUnits(a['units']);
        final order = UnitOrder.values.where((o) => o.name == '${a['order'] ?? 'smart'}').firstOrNull;
        if (order == null) throw ArgumentError('order: ${UnitOrder.values.map((o) => o.name).join(', ')}');
        var x = (a['x'] as num?)?.toInt() ?? 0, y = (a['y'] as num?)?.toInt() ?? 0;
        final target = (a['target'] as num?)?.toInt() ?? 0;
        if (target != 0) {
          final t = e.getUnit(target);
          if (t == null) throw ArgumentError('no unit $target');
          x = t.x;
          y = t.y;
        }
        _asIs(() {
          e.selectUnits(me, ids);
          e.order(me, order, x, y, targetUnitId: target, queue: a['queue'] == true);
        });
        return {'ok': true};
      case 'train':
        _need('command');
        final building = _myUnits([a['building']]);
        final type = _type(a['unit'], unitNames, 'unit type');
        final count = (a['count'] as num?)?.toInt() ?? 1;
        _afford(type);
        _asIs(() {
          e.selectUnits(me, building);
          for (int i = 0; i < count.clamp(1, 5); ++i) {
            e.train(me, type);
          }
        });
        return {'ok': true};
      case 'build':
        _need('command');
        final type = _type(a['building'], unitNames, 'building');
        _afford(type);
        final units = _units();
        var tx = (a['tile_x'] as num?)?.toInt(), ty = (a['tile_y'] as num?)?.toInt();
        final near = (x: (a['x'] as num?)?.toInt(), y: (a['y'] as num?)?.toInt());
        UnitInfo? worker;
        if (a['worker'] != null) {
          final id = _myUnits([a['worker']]).first;
          worker = units.firstWhere((u) => u.unitId == id);
        }
        final ref = near.x != null && near.y != null
            ? (near.x!, near.y!)
            : worker != null
            ? (worker.x, worker.y)
            : units.where((u) => u.owner == me && u.isBuilding).map((u) => (u.x, u.y)).firstOrNull;
        worker ??= ref == null ? null : _nearestWorker(units, ref.$1, ref.$2);
        if (worker == null) throw StateError('no worker');
        if (tx == null || ty == null) {
          if (ref == null) throw ArgumentError('give tile_x and tile_y, or x and y to search near');
          final spot = _findSpot(worker.unitId, type, ref.$1 ~/ 32, ref.$2 ~/ 32);
          if (spot == null) throw StateError('no room for a ${unitNames[type]} near ${ref.$1},${ref.$2}');
          (tx, ty) = spot;
        }
        if (!e.canPlaceBy(worker.unitId, type, tx, ty)) throw StateError('a ${unitNames[type]} can\'t go at tile $tx,$ty');
        final w = worker.unitId, x = tx, y = ty;
        _asIs(() {
          e.selectUnits(me, [w]);
          e.build(me, type, x, y);
        });
        return {'ok': true, 'tile_x': tx, 'tile_y': ty, 'worker': worker.unitId};
      case 'research':
        _need('command');
        final building = _myUnits([a['building']]);
        final tech = a['tech'] != null ? _type(a['tech'], techNames, 'tech') : -1;
        final upgrade = tech < 0 ? _type(a['upgrade'], upgradeNames, 'upgrade') : -1;
        _asIs(() {
          e.selectUnits(me, building);
          if (tech >= 0) {
            e.research(me, tech);
          } else {
            e.upgrade(me, upgrade);
          }
        });
        return {'ok': true};
      case 'diplomacy':
        _need('command');
        final what = '${a['what'] ?? ''}';
        int player() => _int(a, 'player');
        switch (what) {
          case 'invite':
            e.allianceInvite(me, player());
          case 'accept':
          case 'decline':
            e.allianceRespond(me, player(), what == 'accept');
          case 'leave':
            e.allianceLeave(me);
          case 'surrender':
            e.offerSurrender(me, player());
          case 'accept_surrender':
          case 'refuse_surrender':
            e.answerSurrender(me, player(), what == 'accept_surrender');
          case 'open':
          case 'close':
            e.setAllianceOpen(me, what == 'open');
          default:
            throw ArgumentError('what: invite, accept, decline, leave, surrender, accept_surrender, refuse_surrender, open, close');
        }
        return {'ok': true};
      case 'pause':
        _send({'t': 'pause', 'on': a['on'] != false});
        return {'ok': true};
      case 'allow':
        // In the human's seat (--host): what this player's own assistants may do.
        if (assistant) throw StateError('only the player decides what assistants may do');
        _send({'t': 'allow', 'level': _int(a, 'level').clamp(0, 2)});
        return {'ok': true};
      default:
        throw ArgumentError('no action "${a['action']}" (advise, steer, set_strategy, set_relations, set_autoplay, command_units, train, build, research, diplomacy, pause, allow)');
    }
  }

  /// Orders the game can't pay for are dropped there without a word: say so here.
  void _afford(int type) {
    final t = e.unitType(type);
    final m = e.minerals(slot), g = e.gas(slot);
    if (m < t.mineralCost || g < t.gasCost) {
      throw StateError('not enough: a ${unitNames[type]} costs ${t.mineralCost} minerals and ${t.gasCost} gas; you have $m and $g');
    }
  }

  UnitInfo? _nearestWorker(List<UnitInfo> units, int x, int y) {
    UnitInfo? best;
    var bestD = 0;
    for (final u in units) {
      if (u.owner != slot || !u.isWorker || !u.isCompleted) continue;
      final d = (u.x - x) * (u.x - x) + (u.y - y) * (u.y - y);
      if (best == null || d < bestD) {
        best = u;
        bestD = d;
      }
    }
    return best;
  }

  (int, int)? _findSpot(int builder, int type, int cx, int cy) {
    for (int r = 2; r <= 20; ++r) {
      for (int dy = -r; dy <= r; ++dy) {
        for (int dx = -r; dx <= r; ++dx) {
          if (dx.abs() != r && dy.abs() != r) continue;
          if (cx + dx < 0 || cy + dy < 0) continue;
          if (e.canPlaceBy(builder, type, cx + dx, cy + dy)) return (cx + dx, cy + dy);
        }
      }
    }
    return null;
  }
}

// --- HTTP ---------------------------------------------------------------------------

class HttpApi {
  final Agent agent;
  HttpApi(this.agent);

  static const help = '''Brood agent API (docs/agent_api.md). JSON unless noted.
GET  /describe          the game in a few lines of text (text/plain)
GET  /state             resources, units by type, players, alliances
GET  /units?owner=me|enemies|allies|all|resources|<slot>&type=<name>
GET  /map               size, your base, mineral fields and geysers
GET  /events?after=<seq>  alliance events, advice, permissions, errors
GET  /strategies        the strategies set_strategy can switch to, and the one in use
GET  /alliances         alliances, and how this player's diplomacy sees every other player
GET  /numbers           the names steer can set (army.wave_first, ...)
GET  /names             unit, tech and upgrade names
POST /act {"action": ...}  advise | steer | set_strategy | set_relations | set_autoplay | command_units | train | build | research | diplomacy | pause | allow
''';

  Future<void> serve(int port) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    log('HTTP API on http://127.0.0.1:$port/');
    server.listen((req) async {
      final res = req.response;
      try {
        final q = req.uri.queryParameters;
        Object? out;
        switch ((req.method, req.uri.path)) {
          case ('GET', '/'):
            out = help;
          case ('GET', '/describe'):
            out = agent.describe();
          case ('GET', '/state'):
            out = agent.state();
          case ('GET', '/units'):
            out = agent.units(owner: q['owner'] ?? 'me', type: q['type']);
          case ('GET', '/map'):
            out = agent.map();
          case ('GET', '/events'):
            final after = int.tryParse(q['after'] ?? '') ?? 0;
            out = [for (final ev in agent.events) if ((ev['seq'] as int) > after) ev];
          case ('GET', '/strategies'):
            out = agent.strategies();
          case ('GET', '/alliances'):
            out = agent.alliances();
          case ('GET', '/numbers'):
            out = agent.numberNames;
          case ('GET', '/names'):
            out = {'units': unitNames, 'techs': techNames, 'upgrades': upgradeNames};
          case ('POST', '/act'):
            final body = jsonDecode(await utf8.decoder.bind(req).join());
            out = agent.act(Map<String, dynamic>.from(body as Map));
            if ((out as Map)['ok'] != true) res.statusCode = HttpStatus.badRequest;
          default:
            res.statusCode = HttpStatus.notFound;
            out = {'error': 'no such endpoint', 'help': help};
        }
        if (out is String) {
          res.headers.contentType = ContentType.text;
          res.write(out);
        } else {
          res.headers.contentType = ContentType.json;
          res.write(const JsonEncoder.withIndent('  ').convert(out));
        }
      } catch (err) {
        res.statusCode = HttpStatus.badRequest;
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'ok': false, 'error': '$err'}));
      }
      await res.close();
    });
  }
}

// --- MCP (Model Context Protocol, JSON-RPC 2.0 over stdin/stdout) ------------------------

class Mcp {
  final Agent agent;
  Mcp(this.agent);

  static Map<String, Object?> _obj(Map<String, Object?> props, [List<String> required = const []]) => {
    'type': 'object',
    'properties': props,
    if (required.isNotEmpty) 'required': required,
  };

  static const _int = {'type': 'integer'};
  static const _str = {'type': 'string'};

  final List<Map<String, Object?>> tools = [
    {'name': 'describe_game', 'description': 'The game right now in a few lines of text: time, your resources, units and buildings, every player, recent events. Start here.', 'inputSchema': _obj({})},
    {'name': 'get_state', 'description': 'The game state as JSON (resources, units by type, players, alliances, what you may do).', 'inputSchema': _obj({})},
    {
      'name': 'list_units',
      'description': 'Units with id, type, owner, position (pixels), hit points. Ids are what the other tools take.',
      'inputSchema': _obj({
        'owner': {'type': 'string', 'description': 'me (default), enemies, allies, all, resources, or a player slot number'},
        'type': {'type': 'string', 'description': 'only this unit type, e.g. terran_marine'},
      }),
    },
    {'name': 'get_map', 'description': 'Map size, your base, mineral fields and geysers.', 'inputSchema': _obj({})},
    {
      'name': 'get_events',
      'description': 'Alliance events, advice, permission changes and errors after a sequence number.',
      'inputSchema': _obj({'after': _int}),
    },
    {
      'name': 'wait',
      'description': 'Lets the game run for some seconds (it runs in real time), then describes it.',
      'inputSchema': _obj({'seconds': {'type': 'number', 'description': '1 to 120'}}, ['seconds']),
    },
    {
      'name': 'advise',
      'description': 'Sends advice to the human you assist; it appears in their game.',
      'inputSchema': _obj({'text': _str}, ['text']),
    },
    {
      'name': 'steer',
      'description': 'Directs the built-in AI that plays for this player (a computer player, or a human\'s auto-play): start an attack now, hold attacks for some seconds, attack a player first, set the next wave\'s size, or set any of its numbers (see get_numbers).',
      'inputSchema': _obj({
        'attack': {'type': 'boolean'},
        'hold_seconds': _int,
        'focus_player': {'type': 'integer', 'description': 'player slot, -1 for the nearest enemy'},
        'wave_size': {'type': 'integer', 'description': 'fighting units the next wave waits for: smaller attacks sooner'},
        'numbers': {'type': 'object', 'description': 'e.g. {"army.wave_max": 30, "diplomacy.betray_after": 600} (times in seconds)'},
      }),
    },
    {'name': 'get_numbers', 'description': 'The names of the numbers steer can set.', 'inputSchema': _obj({})},
    {
      'name': 'get_strategies',
      'description': 'The strategies this player can switch to (defend, economy, expand, build_up, attack, massive_attack, all_in, and whatever its profile adds), with what each does, and the one in use.',
      'inputSchema': _obj({}),
    },
    {
      'name': 'set_strategy',
      'description': 'Switches the built-in AI to a strategy (see get_strategies); "none" goes back to the profile\'s own way. Attack strategies take a target player slot. The AI keeps playing it until you change it: re-evaluate every half minute or so.',
      'inputSchema': _obj({'name': _str, 'target': _int}, ['name']),
    },
    {
      'name': 'get_alliances',
      'description': 'Alliances, and how this player\'s diplomacy sees every other player: alliance strength, utility (how much it wants them), favor, losses to them, distance, invitations and surrender offers.',
      'inputSchema': _obj({}),
    },
    {
      'name': 'set_relations',
      'description': 'How much this player wants each other player as an ally, from -100 (never: refuses their invitations, turns on them sooner) to 100 (always accepts them, seeks them out). Its own diplomacy then invites, accepts, leaves and betrays by it. E.g. {"favor": {"2": 100, "5": -60}}.',
      'inputSchema': _obj({'favor': {'type': 'object', 'description': 'player slot -> -100..100'}}, ['favor']),
    },
    {
      'name': 'set_autoplay',
      'description': 'A human player\'s auto-play modes: resources, building, attacking, colonizing, all, or off.',
      'inputSchema': _obj({'modes': {'type': 'string', 'description': 'comma separated, or all, or off'}}, ['modes']),
    },
    {
      'name': 'command_units',
      'description': 'Orders your units: smart (like a right click), move, attack, patrol, hold, stop. Give x and y (pixels) or a target unit id.',
      'inputSchema': _obj({
        'units': {'type': 'array', 'items': _int},
        'order': {'type': 'string', 'enum': ['smart', 'move', 'attack', 'patrol', 'hold', 'stop']},
        'x': _int,
        'y': _int,
        'target': _int,
        'queue': {'type': 'boolean'},
      }, ['units']),
    },
    {
      'name': 'train',
      'description': 'Trains units at one of your buildings (a larva for Zerg).',
      'inputSchema': _obj({'building': _int, 'unit': _str, 'count': _int}, ['building', 'unit']),
    },
    {
      'name': 'build',
      'description': 'Builds a building. Give tile_x and tile_y, or x and y (pixels) to search for room near, or nothing to build near your base. A worker is picked unless given.',
      'inputSchema': _obj({'building': _str, 'worker': _int, 'tile_x': _int, 'tile_y': _int, 'x': _int, 'y': _int}, ['building']),
    },
    {
      'name': 'research',
      'description': 'Researches a tech or an upgrade at one of your buildings.',
      'inputSchema': _obj({'building': _int, 'tech': _str, 'upgrade': _str}, ['building']),
    },
    {
      'name': 'diplomacy',
      'description': 'Alliances: invite, accept, decline, leave, surrender, accept_surrender, refuse_surrender, open, close.',
      'inputSchema': _obj({'what': _str, 'player': _int}, ['what']),
    },
  ];

  Future<void> serve() async {
    log('MCP on stdin/stdout');
    await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      Map<String, dynamic> m;
      try {
        m = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        _reply(null, error: {'code': -32700, 'message': 'parse error'});
        continue;
      }
      final id = m['id'];
      final params = Map<String, dynamic>.from(m['params'] as Map? ?? const {});
      switch (m['method']) {
        case 'initialize':
          _reply(id, result: {
            'protocolVersion': params['protocolVersion'] ?? '2025-06-18',
            'capabilities': {'tools': {}},
            'serverInfo': {'name': 'brood-agent', 'version': '1'},
            'instructions': 'You follow one player of a running Brood War game (real time, about 24 frames a second). '
                'Call describe_game first, then act with the other tools; wait lets time pass.',
          });
        case 'ping':
          _reply(id, result: {});
        case 'tools/list':
          _reply(id, result: {'tools': tools});
        case 'tools/call':
          final (text, error) = await _call('${params['name']}', Map<String, dynamic>.from(params['arguments'] as Map? ?? const {}));
          _reply(id, result: {
            'content': [
              {'type': 'text', 'text': text},
            ],
            'isError': error,
          });
        default:
          if (id != null) _reply(id, error: {'code': -32601, 'message': 'no method ${m['method']}'});
      }
    }
    exit(0);
  }

  Future<(String, bool)> _call(String name, Map<String, dynamic> a) async {
    String json(Object? o) => const JsonEncoder.withIndent('  ').convert(o);
    switch (name) {
      case 'describe_game':
        return (agent.describe(), false);
      case 'get_state':
        return (json(agent.state()), false);
      case 'list_units':
        return (json(agent.units(owner: '${a['owner'] ?? 'me'}', type: a['type'] as String?)), false);
      case 'get_map':
        return (json(agent.map()), false);
      case 'get_events':
        final after = (a['after'] as num?)?.toInt() ?? 0;
        return (json([for (final ev in agent.events) if ((ev['seq'] as int) > after) ev]), false);
      case 'get_numbers':
        return (json(agent.numberNames), false);
      case 'get_strategies':
        return (json(agent.strategies()), false);
      case 'get_alliances':
        return (json(agent.alliances()), false);
      case 'wait':
        final s = ((a['seconds'] as num?) ?? 5).clamp(1, 120);
        await Future<void>.delayed(Duration(milliseconds: (s * 1000).round()));
        return (agent.describe(), false);
      default:
        final r = agent.act({...a, 'action': name});
        return (json(r), r['ok'] != true);
    }
  }

  void _reply(Object? id, {Object? result, Object? error}) {
    stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, if (error != null) 'error': error else 'result': result}));
  }
}

// --- the strategist: an LLM revising the strategy every half minute ------------------------

/// Asks Claude (Anthropic's Messages API) every [every] seconds what this
/// player should do, with the game described, its strategies and its
/// alliances, and carries out what it decides: a strategy, the AI's
/// numbers, relations with each player, alliance moves, advice. It keeps a
/// short journal of its decisions between rounds. Needs ANTHROPIC_API_KEY
/// (or ANTHROPIC_AUTH_TOKEN, or a profile from `ant auth login`).
class Strategist {
  final Agent agent;
  final int every;
  final String model;
  final String effort;
  final String goal;

  /// 'anthropic' (the Messages API), or 'openai': any server speaking the
  /// OpenAI chat completions API (OpenRouter, Ollama, the Hugging Face
  /// router, ...) at [baseUrl] with [apiKey] (none for a local one).
  final String provider;
  final String baseUrl;
  final String? apiKey;
  Strategist(
    this.agent, {
    required this.every,
    required this.model,
    required this.effort,
    required this.goal,
    this.provider = 'anthropic',
    this.baseUrl = '',
    this.apiKey,
  });

  /// Tokens used so far (as the servers report them).
  int inputTokens = 0, outputTokens = 0, requests = 0;

  final List<String> _journal = [];
  bool _busy = false;
  int _round = 0;
  ({String header, String value})? _auth;

  static const _decisionTools = {'set_strategy', 'steer', 'set_relations', 'diplomacy', 'advise'};

  List<Map<String, Object?>> _tools() {
    final can = agent.can;
    final out = <Map<String, Object?>>[];
    for (final t in Mcp(agent).tools) {
      final name = t['name'] as String;
      if (!_decisionTools.contains(name)) continue;
      if (name == 'advise' && !can['advise']!) continue;
      if (name != 'advise' && !can['steer']!) continue;
      if (name == 'diplomacy' && !can['command']!) continue;
      out.add({'name': name, 'description': t['description'], 'input_schema': t['inputSchema']});
    }
    out.add({
      'name': 'remember',
      'description': 'Notes your plan and why, for your next rounds (you see your last notes each round).',
      'input_schema': {
        'type': 'object',
        'properties': {'note': {'type': 'string'}},
        'required': ['note'],
      },
    });
    return out;
  }

  String get _system => '''You are the strategist of one player in a real-time game of StarCraft: Brood War (four or more players, free for all or alliances).
A built-in AI plays the units: it gathers, builds, trains, defends and attacks by itself. You decide how it plays, as a commander
would: every $every seconds you get the situation and choose what, if anything, to change. You are slow next to the game, so think
in phases of a few minutes, not single fights.

Your levers:
- set_strategy: switch the AI's way of playing (defend, economy, expand, build_up, attack, massive_attack, all_in, or what its
  profile adds; "none" is its own way). A strategy holds until you change it. Changing strategy resets steered numbers.
- steer: fine-tune it (attack now, hold attacks for some seconds, attack a player first, the next wave's size, any of its numbers).
- set_relations: how much it wants each player as an ally (-100..100). Its own diplomacy invites, accepts, leaves and betrays by it.
- diplomacy: invite, accept, decline, leave, surrender, accept or refuse a surrender, open or close to invitations, right now.
- advise: tell the human you assist what to do (when you assist a human).
- remember: keep a note of your plan for the next rounds.

Good play: expand and grow the economy while nobody threatens you; defend when an enemy army is near or you are losing at home;
gather a big army before a decisive attack on the weakest or nearest enemy; ally with neighbours against a stronger common enemy
(an alliance holds at most three, and never everyone left); turn on a weak ally only when no strong enemy remains; accept a
surrender when the tribute is worth more than finishing them; offer yours only when the game is lost. Score counts mining,
production and destruction; winning counts most.

Watch the army line: an army gathering for a wave much bigger than it can reach in a minute or two wastes time (lower wave_size
or attack now); a wave that is out and losing should be held back.
Each round: read the situation, then either change nothing (say why in one line) or make a few decisive changes and remember the plan.
Do not repeat a change that is already in effect.${goal.isEmpty ? '' : '\nThe player\'s goal: $goal'}''';

  String _situation() {
    final b = StringBuffer()
      ..writeln('Round ${++_round}.')
      ..writeln(agent.describe())
      ..writeln('Strategies: ${jsonEncode(agent.strategies())}')
      ..writeln('Alliances: ${jsonEncode(agent.alliances())}');
    if (_journal.isNotEmpty) {
      b.writeln('Your notes and decisions so far (newest last):');
      for (final j in _journal) {
        b.writeln('- $j');
      }
    }
    return b.toString();
  }

  Future<({String header, String value})> _credentials() async {
    if (_auth case final a?) return a;
    final env = Platform.environment;
    if ((env['ANTHROPIC_API_KEY'] ?? '').isNotEmpty) return _auth = (header: 'x-api-key', value: env['ANTHROPIC_API_KEY']!);
    var token = env['ANTHROPIC_AUTH_TOKEN'] ?? '';
    if (token.isEmpty) {
      // A profile from `ant auth login`: a short-lived access token.
      try {
        final r = await Process.run('ant', ['auth', 'print-credentials', '--access-token']);
        if (r.exitCode == 0) token = '${r.stdout}'.trim();
      } catch (_) {}
    }
    if (token.isEmpty) throw StateError('no credentials: set ANTHROPIC_API_KEY, or run `ant auth login`');
    return (header: 'authorization', value: 'Bearer $token');
  }

  Future<Map<String, dynamic>> _http(String url, Map<String, String> headers, Map<String, Object?> body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      final req = await client.postUrl(Uri.parse(url));
      req.headers.contentType = ContentType.json;
      headers.forEach(req.headers.set);
      final bytes = utf8.encode(jsonEncode(body));
      req.contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close().timeout(const Duration(minutes: 5));
      final text = await utf8.decoder.bind(res).join();
      if (res.statusCode != 200) throw StateError('$url ${res.statusCode}: ${text.length > 500 ? text.substring(0, 500) : text}');
      ++requests;
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _post(Map<String, Object?> body) async {
    final auth = await _credentials();
    final base = Platform.environment['ANTHROPIC_BASE_URL'] ?? 'https://api.anthropic.com';
    final r = await _http('${base.replaceAll(RegExp(r'/+$'), '')}/v1/messages', {
      'anthropic-version': '2023-06-01',
      auth.header: auth.value,
      // Server-side fallback for declined requests; OAuth tokens need their own beta.
      'anthropic-beta': ['server-side-fallback-2026-07-01', if (auth.header == 'authorization') 'oauth-2025-04-20'].join(','),
    }, body);
    final usage = r['usage'] as Map? ?? const {};
    inputTokens += (usage['input_tokens'] as num? ?? 0).toInt() + (usage['cache_read_input_tokens'] as num? ?? 0).toInt();
    outputTokens += (usage['output_tokens'] as num? ?? 0).toInt();
    return r;
  }

  void start() {
    log('strategist: $model every $every s');
    Timer.periodic(Duration(seconds: every), (_) => _round_());
    _round_();
  }

  Future<void> _round_() async {
    if (_busy || agent.paused || !agent.ready) return;
    _busy = true;
    try {
      await _decide();
    } catch (err) {
      log('strategist: $err');
      agent.event('strategist_error', {'error': '$err'});
    } finally {
      _busy = false;
    }
  }

  /// Carries out one tool call; the result goes back to the model.
  Map<String, Object?> _carryOut(String name, Map<String, dynamic> input, List<String> decisions) {
    Map<String, Object?> out;
    if (name == 'remember') {
      final note = '${input['note'] ?? ''}'.trim();
      // (Small models copy their notes; the same one again adds nothing.)
      if (note.isNotEmpty && !_journal.any((j) => j.endsWith('note: $note'))) _journal.add('${Agent.clock(agent.e.currentFrame)} note: $note');
      out = {'ok': true};
    } else if (!_tools().any((t) => t['name'] == name)) {
      out = {'ok': false, 'error': 'no tool "$name"'};
    } else {
      out = agent.act({...input, 'action': name});
      decisions.add('$name ${jsonEncode(input)}${out['ok'] == true ? '' : ' (failed: ${out['error']})'}');
    }
    log('strategist: $name ${jsonEncode(input)} -> ${jsonEncode(out)}');
    return out;
  }

  void _said(String text, List<String> decisions) {
    // (Reasoning some models put in their answer.)
    final t = text.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '').trim();
    if (t.isEmpty) return;
    log('strategist: $t');
    decisions.add(t.length > 300 ? '${t.substring(0, 300)}...' : t);
  }

  void _endRound(List<String> decisions) {
    final at = Agent.clock(agent.e.currentFrame);
    agent.event('strategist', {'round': _round, 'decisions': decisions, 'requests': requests, 'input_tokens': inputTokens, 'output_tokens': outputTokens});
    if (decisions.isNotEmpty && !_journal.any((j) => j.endsWith(' ${decisions.join('; ')}'))) _journal.add('$at ${decisions.join('; ')}');
    while (_journal.length > 12) {
      _journal.removeAt(0);
    }
  }

  /// One round with an OpenAI-compatible server.
  Future<void> _decideOpenAi() async {
    final tools = [
      for (final t in _tools())
        {
          'type': 'function',
          'function': {'name': t['name'], 'description': t['description'], 'parameters': t['input_schema']},
        },
    ];
    final messages = <Map<String, Object?>>[
      {'role': 'system', 'content': _system},
      {'role': 'user', 'content': _situation()},
    ];
    final decisions = <String>[];
    // One batch of decisions; then a summary without tools (another batch
    // only to fix a call that failed). Small models otherwise keep
    // changing their minds within a round.
    var tooling = true;
    for (int turn = 0; turn < 4; ++turn) {
      final r = await _http('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions', {
        if (apiKey != null && apiKey!.isNotEmpty) 'authorization': 'Bearer $apiKey',
        // OpenRouter's attribution headers (ignored elsewhere).
        'HTTP-Referer': 'https://github.com/brood',
        'X-Title': 'Brood strategist',
      }, {
        'model': model,
        'messages': messages,
        'tools': tools,
        'tool_choice': tooling ? 'auto' : 'none',
        'max_tokens': 4096,
      });
      final usage = r['usage'] as Map? ?? const {};
      inputTokens += (usage['prompt_tokens'] as num? ?? 0).toInt();
      outputTokens += (usage['completion_tokens'] as num? ?? 0).toInt();
      final choices = r['choices'] as List? ?? const [];
      if (choices.isEmpty) throw StateError('no answer: ${jsonEncode(r)}');
      final message = Map<String, Object?>.from((choices.first as Map)['message'] as Map);
      messages.add({'role': 'assistant', 'content': message['content'] ?? '', if (message['tool_calls'] != null) 'tool_calls': message['tool_calls']});
      if (message['content'] case final String text) _said(text, decisions);
      final calls = [for (final c in message['tool_calls'] as List? ?? const []) Map<String, Object?>.from(c as Map)];
      if (calls.isEmpty || !tooling) break;
      var failed = false;
      for (final c in calls) {
        final fn = Map<String, Object?>.from(c['function'] as Map);
        Map<String, dynamic> input;
        Map<String, Object?> out;
        try {
          final args = fn['arguments'];
          input = args is String ? Map<String, dynamic>.from(jsonDecode(args.isEmpty ? '{}' : args) as Map) : Map<String, dynamic>.from(args as Map? ?? const {});
          out = _carryOut('${fn['name']}', input, decisions);
        } catch (err) {
          out = {'ok': false, 'error': 'arguments are not valid JSON: $err'};
        }
        failed |= out['ok'] != true;
        messages.add({'role': 'tool', 'tool_call_id': c['id'], 'content': jsonEncode(out)});
      }
      tooling = failed;
    }
    _endRound(decisions);
  }

  Future<void> _decide() async {
    if (provider != 'anthropic') return _decideOpenAi();
    final tools = _tools();
    final messages = <Map<String, Object?>>[
      {'role': 'user', 'content': _situation()},
    ];
    final decisions = <String>[];
    // One batch of decisions, carried out at once; then a summary without
    // tools (another batch only to fix a call that failed).
    var tooling = true;
    for (int turn = 0; turn < 4; ++turn) {
      final r = await _post({
        'model': model,
        'max_tokens': 16000,
        'system': _system,
        'tools': tools,
        if (!tooling) 'tool_choice': {'type': 'none'},
        'messages': messages,
        'output_config': {'effort': effort},
        'fallbacks': 'default',
        'cache_control': {'type': 'ephemeral'},
      });
      final stop = r['stop_reason'];
      if (stop == 'refusal') {
        log('strategist: the request was declined (${r['stop_details']})');
        break;
      }
      final content = [for (final c in r['content'] as List) Map<String, Object?>.from(c as Map)];
      // The whole answer goes back as it came (thinking blocks included).
      messages.add({'role': 'assistant', 'content': content});
      for (final c in content.where((c) => c['type'] == 'text')) {
        _said('${c['text']}', decisions);
      }
      final calls = content.where((c) => c['type'] == 'tool_use').toList();
      if (stop != 'tool_use' || calls.isEmpty || !tooling) break;
      final results = <Map<String, Object?>>[];
      var failed = false;
      for (final c in calls) {
        final out = _carryOut(c['name'] as String, Map<String, dynamic>.from(c['input'] as Map? ?? const {}), decisions);
        failed |= out['ok'] != true;
        results.add({'type': 'tool_result', 'tool_use_id': c['id'], 'content': jsonEncode(out), if (out['ok'] != true) 'is_error': true});
      }
      messages.add({'role': 'user', 'content': results});
      tooling = failed;
    }
    _endRound(decisions);
  }
}
