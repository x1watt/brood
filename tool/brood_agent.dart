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
      ..writeln('Your buildings: ${_list(mine['buildings'])}.')
      ..writeln('Players:');
    for (final p in s['players'] as List) {
      final m = p as Map<String, Object?>;
      if (m['me'] == true) continue;
      final rel = m['ally'] == true ? 'ally' : 'enemy';
      b.writeln('  slot ${m['slot']} ${m['name']} (${m['race']}${m['human'] == true ? ', human' : ''}): $rel, '
          '${m['active'] == true ? '' : 'OUT, '}army ${m['army_value']}, ${m['workers']} workers, mining ${m['mining_per_minute']}/min, score ${m['score']}'
          '${m['invited_by'] != null ? ', invited by ${m['invited_by']}' : ''}');
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
        throw ArgumentError('no action "${a['action']}" (advise, steer, set_autoplay, command_units, train, build, research, diplomacy, pause, allow)');
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
GET  /numbers           the names steer can set (army.wave_first, ...)
GET  /names             unit, tech and upgrade names
POST /act {"action": ...}  advise | steer | set_autoplay | command_units | train | build | research | diplomacy | pause | allow
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
        'wave_size': _int,
        'numbers': {'type': 'object', 'description': 'e.g. {"army.wave_max": 30, "diplomacy.betray_after": 600} (times in seconds)'},
      }),
    },
    {'name': 'get_numbers', 'description': 'The names of the numbers steer can set.', 'inputSchema': _obj({})},
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
