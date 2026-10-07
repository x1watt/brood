// lib/net/home_server.dart
//
// The home server for the browser version: open http://<that computer's
// address>:9191 on any computer, tablet or browser tab at home. Run by
// tool/brood_server.dart, and by the desktop and Android app when the player
// shares the game on the network (lib/net/lan_host.dart, in an isolate of
// its own). Plain dart:io: no Flutter here.
//
// It serves:
//   /               the browser version (build/web)
//   /gamedata/      the player's own game files from --data (BROOD_DATA,
//                   default ~/box/media/games/BROOD): manifest.json lists the
//                   three archives and the melee maps. Pages load them from
//                   here instead of asking for a folder.
//   /ws             multiplayer (a WebSocket, JSON messages)
//   /home.json      tells a page it came from a home server (it doesn't ask
//                   whether the player has the game files)
//   /playstats.json the play time per map of whoever runs the server (the
//                   app's play_stats.json), so pages list the same most
//                   played maps first
//
// Multiplayer is lockstep, which works because the simulation is
// deterministic and every command already goes through the engine's command
// log (that is how saved games work). This server keeps each game's clock
// and its command log; every browser runs the same simulation:
//   - the clock advances one frame per 42 ms (the original's speed) while
//     someone is connected and nobody paused; 'tick' messages tell the
//     players how far they may run;
//   - a player's command is stamped a few frames ahead of the clock and sent
//     to everyone, who apply it on that frame;
//   - joining a game replays its log (like loading a save) and takes over
//     one of the computer players (a logged command), with its alliance;
//     leaving hands the slot back to the computer.
//   - anyone can pause and resume; every few seconds the players report a
//     hash of their game, and a difference is reported as out of sync.
//
// Assistants (docs/agent_api.md): an outside program (tool/brood_agent.dart,
// for scripts and LLMs) follows a game for one player without taking its
// place. It runs the same simulation, may send that player advice (shown in
// their game), and may command for it as far as allowed: a computer player
// fully; a human's only after they allow it (1: steer their auto-play,
// 2: everything their units do).
//
// Messages, client to server: hello{name}, list, create{launch, slot},
// join{game, slot}, assist{game, slot}, cmd{entries}, pause{on},
// report{frame, hash, groups, active}, advice{text}, allow{level}, leave.
// Server to client: games{games}, joined{..., assistant, allow}, cmd{frame,
// entries}, tick{upTo}, paused{on, by}, players{names}, desync{frame},
// advice{from, text}, assistants{names, allow}, allow{level},
// error{message}.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Frames a command is stamped ahead of the clock: time for it to reach
/// every player before they get there (about 0.2 s).
const int inputDelay = 5;
const int frameMs = 42;

// The engine's log operations (bw_bridge.cpp): the one this server writes
// itself, and what an assistant may send.
const int opSetController = 24;
const int opAutoplay = 19;
const int opBotSteer = 29;
// Settings of the whole game: never from an assistant.
const Set<int> gameOps = {23, opSetController, 26, 28};

class HomeServer {
  final HttpServer _server;
  final Lobby lobby;
  final GameDataFiles files;
  final Directory web;
  final File? stats;
  HomeServer._(this._server, this.lobby, this.files, this.web, this.stats);

  int get port => _server.port;

  /// Addresses others at home can open.
  List<String> get urls => lobby.urls;

  /// Serves on every network interface, on [port] or, when it is taken, the
  /// next free one of [tries].
  static Future<HomeServer> start({required Directory web, required Directory data, File? stats, int port = 9191, int tries = 1}) async {
    HttpServer? server;
    SocketException? error;
    for (var p = port; p < port + tries && server == null; ++p) {
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, p);
      } on SocketException catch (e) {
        error = e;
      }
    }
    if (server == null) throw error!;
    final s = HomeServer._(server, Lobby(), GameDataFiles(data), web, stats);
    s.lobby.urls.addAll(await lanUrls(server.port));
    s._serve();
    return s;
  }

  /// http://<address>:[port]/ for each network interface others can reach
  /// (not loopback, not containers').
  static Future<List<String>> lanUrls(int port) async {
    final out = <String>[];
    for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      if (i.name.startsWith('docker') || i.name.startsWith('br-') || i.name.startsWith('veth')) continue;
      for (final a in i.addresses) {
        if (!a.isLoopback) out.add('http://${a.address}:$port/');
      }
    }
    return out;
  }

  Future<void> _serve() async {
    await for (final req in _server) {
      try {
        if (req.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
          lobby.connect(await WebSocketTransformer.upgrade(req));
        } else if (req.uri.path.startsWith('/gamedata/')) {
          await files.serve(req, req.uri.path.substring('/gamedata/'.length));
        } else if (req.uri.path == '/home.json') {
          req.response.headers.contentType = ContentType.json;
          req.response.headers.set('Cache-Control', 'no-cache');
          req.response.write('{}');
          await req.response.close();
        } else if (req.uri.path == '/playstats.json') {
          // Read at every request: the app's games add to it.
          final f = stats;
          req.response.headers.contentType = ContentType.json;
          req.response.headers.set('Cache-Control', 'no-cache');
          req.response.write(f != null && await f.exists() ? await f.readAsString() : '{}');
          await req.response.close();
        } else {
          await serveStatic(req, web);
        }
      } catch (e) {
        try {
          req.response.statusCode = HttpStatus.internalServerError;
          await req.response.close();
        } catch (_) {}
      }
    }
  }

  Future<void> close() async {
    lobby.close();
    await _server.close(force: true);
  }
}

// --- files -------------------------------------------------------------------

const _types = {
  'html': 'text/html; charset=utf-8',
  'js': 'text/javascript',
  'mjs': 'text/javascript',
  'json': 'application/json',
  'wasm': 'application/wasm',
  'css': 'text/css',
  'png': 'image/png',
  'ico': 'image/x-icon',
  'svg': 'image/svg+xml',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  'frag': 'application/octet-stream',
};

Future<void> serveStatic(HttpRequest req, Directory root) async {
  var path = Uri.decodeComponent(req.uri.path);
  if (path.endsWith('/')) path += 'index.html';
  final file = File('${root.path}$path');
  final resolved = file.absolute.path;
  if (path.contains('..') || !resolved.startsWith(root.absolute.path) || !file.existsSync()) {
    req.response.statusCode = HttpStatus.notFound;
    await req.response.close();
    return;
  }
  final ext = path.split('.').last.toLowerCase();
  req.response.headers.contentType = ContentType.parse(_types[ext] ?? 'application/octet-stream');
  // The app's own files can change with a new build; check every time.
  req.response.headers.set('Cache-Control', 'no-cache');
  await req.response.addStream(file.openRead());
  await req.response.close();
}

/// The player's game files: the three archives, the melee maps and the bot
/// profiles (bots/**.bot), by their path relative to the game folder (as
/// the page stores them).
class GameDataFiles {
  final Directory dir;
  final Map<String, File> byKey = {};
  GameDataFiles(this.dir) {
    if (!dir.existsSync()) return;
    const archives = ['StarDat.mpq', 'BrooDat.mpq', 'Patch_rt.mpq'];
    for (final e in dir.listSync(recursive: true, followLinks: true).whereType<File>()) {
      final rel = e.path.substring(dir.path.length).replaceAll('\\', '/').replaceFirst(RegExp('^/'), '');
      final base = rel.split('/').last;
      final archive = archives.where((a) => a.toLowerCase() == base.toLowerCase()).firstOrNull;
      if (archive != null && !rel.contains('/')) {
        byKey[archive] = e;
        continue;
      }
      final parts = rel.split('/');
      if (parts.first == 'bots' && rel.endsWith('.bot')) {
        byKey[rel] = e;
        continue;
      }
      final mapsAt = parts.indexWhere((p) => p.toLowerCase() == 'maps');
      final lower = rel.toLowerCase();
      if (mapsAt < 0 || !(lower.endsWith('.scm') || lower.endsWith('.scx'))) continue;
      if (lower.contains('/campaign/') || lower.contains('/scenario/') || lower.contains('/save/')) continue;
      byKey[['maps', ...parts.sublist(mapsAt + 1)].join('/')] = e;
    }
    if (!archives.every(byKey.containsKey)) byKey.clear();
  }

  List<String> get list => byKey.keys.toList()..sort();

  Future<void> serve(HttpRequest req, String path) async {
    final key = Uri.decodeComponent(path);
    final res = req.response;
    if (key == 'manifest.json') {
      res.headers.contentType = ContentType.json;
      res.headers.set('Cache-Control', 'no-cache');
      res.write(jsonEncode(list));
    } else if (byKey[key] case final file?) {
      res.headers.contentType = ContentType.binary;
      await res.addStream(file.openRead());
    } else {
      res.statusCode = HttpStatus.notFound;
    }
    await res.close();
  }
}

// --- multiplayer -----------------------------------------------------------------

class Client {
  final WebSocket ws;
  String name = 'Player';
  Game? game;
  int slot = -1;
  bool assistant = false; // follows `slot` without playing it
  Client(this.ws);
  void send(Map<String, Object?> m) {
    try {
      ws.add(jsonEncode(m));
    } catch (_) {}
  }
}

class Game {
  final int id;
  final Map<String, Object?> launch; // map, setup (resolved), names of the computer players
  final List<Map<String, Object?>> slots; // {slot, race, name}
  final List<List<int>> log = []; // [frame, op, n, args...] entries
  final Map<int, Client> humans = {}; // slot -> who plays it
  final Map<int, String> names = {}; // slot -> human name, kept after leaving
  final Map<Client, int> assistants = {}; // who assists which slot
  final Map<int, int> allow = {}; // slot -> what its human lets assistants do (0-2)
  int frame = 0;
  int lastStamp = 0;
  bool paused = false;
  String pausedBy = '';
  Client? pausedByClient;
  List<int> groups = const [];
  List<int> active = const [];
  final Map<int, Map<int, int>> hashes = {}; // frame -> slot -> hash
  final DateTime started = DateTime.now();
  Game(this.id, this.launch, this.slots);

  Iterable<Client> get clients => [...humans.values, ...assistants.keys];
  bool get running => !paused && (humans.isNotEmpty || assistants.isNotEmpty);

  /// What assistants of [slot] may command: a computer player everything,
  /// a human's what they allowed.
  int level(int slot) => humans.containsKey(slot) ? (allow[slot] ?? 0) : 2;

  /// Whether every entry is something an assistant of [slot] may send.
  bool allowed(int slot, List<int> entries) => assistantMay(level(slot), slot, entries);

  void broadcast(Map<String, Object?> m) {
    final s = jsonEncode(m);
    for (final c in clients) {
      try {
        c.ws.add(s);
      } catch (_) {}
    }
  }

  /// Logs [entries] (frames ignored) at the next free frame ahead of the
  /// clock and sends them to everyone.
  void command(List<int> entries) {
    final at = (frame + inputDelay) > lastStamp ? frame + inputDelay : lastStamp;
    lastStamp = at;
    for (int i = 0; i + 3 <= entries.length;) {
      final n = entries[i + 2];
      if (i + 3 + n > entries.length) break;
      log.add([at, entries[i + 1], n, ...entries.sublist(i + 3, i + 3 + n)]);
      i += 3 + n;
    }
    broadcast({'t': 'cmd', 'frame': at, 'entries': entries});
  }

  Map<String, Object?> summary() => {
    'id': id,
    'mapName': launch['mapName'],
    'frame': frame,
    'paused': paused,
    'slots': [
      for (final s in slots)
        {
          ...s,
          'human': humans.containsKey(s['slot']) ? names[s['slot']] : null,
          'assistants': [for (final e in assistants.entries) if (e.value == s['slot']) e.key.name],
          'group': groups.length > (s['slot'] as int) ? groups[s['slot'] as int] : s['slot'],
          'active': active.length > (s['slot'] as int) ? active[s['slot'] as int] == 1 : true,
        },
    ],
  };
}

/// Whether log [entries] are something an assistant of [slot] may send at
/// [level] (0 advice only, 1 steer the auto-play, 2 everything): only for
/// that player, and never the game's own settings.
bool assistantMay(int level, int slot, List<int> entries) {
  if (level <= 0 || entries.isEmpty) return false;
  for (int i = 0; i < entries.length;) {
    if (i + 3 > entries.length) return false;
    final op = entries[i + 1], n = entries[i + 2];
    if (n < 1 || i + 3 + n > entries.length || entries[i + 3] != slot || gameOps.contains(op)) return false;
    if (level < 2 && op != opBotSteer && op != opAutoplay) return false;
    i += 3 + n;
  }
  return true;
}

class Lobby {
  final Set<Client> clients = {};
  final Map<int, Game> games = {};
  final List<String> urls = [];
  int nextId = 1;

  late final Timer _timer;
  Lobby() {
    _timer = Timer.periodic(const Duration(milliseconds: frameMs), (_) => _clock());
  }

  void close() {
    _timer.cancel();
    for (final c in clients.toList()) {
      c.ws.close();
    }
  }

  int _ticks = 0;
  void _clock() {
    ++_ticks;
    for (final g in games.values) {
      if (!g.running) continue;
      ++g.frame;
      if (g.frame % 2 == 0) g.broadcast({'t': 'tick', 'upTo': g.frame});
    }
    // The lobby's list, every few seconds for the game times.
    if (_ticks % 72 == 0) _sendGames();
  }

  void connect(WebSocket ws) {
    final c = Client(ws);
    clients.add(c);
    ws.listen((data) {
      try {
        _message(c, jsonDecode(data as String) as Map<String, dynamic>);
      } catch (e) {
        c.send({'t': 'error', 'message': '$e'});
      }
    }, onDone: () => _leave(c, gone: true), onError: (_) => _leave(c, gone: true));
    c.send({'t': 'games', 'games': [for (final g in games.values) g.summary()]});
    c.send({'t': 'info', 'urls': urls});
  }

  void _sendGames() {
    final m = {'t': 'games', 'games': [for (final g in games.values) g.summary()]};
    for (final c in clients) {
      if (c.game == null) c.send(m);
    }
  }

  void _message(Client c, Map<String, dynamic> m) {
    switch (m['t']) {
      case 'hello':
        c.name = (m['name'] as String? ?? 'Player').trim().isEmpty ? 'Player' : (m['name'] as String).trim();
      case 'list':
        c.send({'t': 'games', 'games': [for (final g in games.values) g.summary()]});
      case 'create':
        _leave(c);
        final g = Game(nextId++, Map<String, Object?>.from(m['launch'] as Map), [
          for (final s in m['slots'] as List) Map<String, Object?>.from(s as Map),
        ]);
        // Where the host's game stands (a loaded game was replayed).
        final log = [for (final v in m['log'] as List? ?? const []) v as int];
        for (int i = 0; i + 3 <= log.length;) {
          final n = log[i + 2];
          if (i + 3 + n > log.length) break;
          g.log.add(log.sublist(i, i + 3 + n));
          i += 3 + n;
        }
        g.frame = g.lastStamp = m['frame'] as int? ?? 0;
        games[g.id] = g;
        _seat(c, g, m['slot'] as int, takeOver: false);
        _sendGames();
      case 'join':
        final g = games[m['game']];
        final slot = m['slot'] as int;
        if (g == null) return c.send({'t': 'error', 'message': 'That game is over.'});
        if (g.humans.containsKey(slot)) return c.send({'t': 'error', 'message': '${g.names[slot]} plays that one already.'});
        if (!g.slots.any((s) => s['slot'] == slot)) return c.send({'t': 'error', 'message': 'No such player.'});
        _leave(c);
        _seat(c, g, slot, takeOver: true);
        _sendGames();
      case 'assist':
        final g = games[m['game']];
        final slot = m['slot'] as int;
        if (g == null) return c.send({'t': 'error', 'message': 'That game is over.'});
        if (!g.slots.any((s) => s['slot'] == slot)) return c.send({'t': 'error', 'message': 'No such player.'});
        _leave(c);
        _seat(c, g, slot, takeOver: false, assistant: true);
        _sendGames();
      case 'cmd':
        final g = c.game;
        if (g == null) return;
        final entries = [for (final v in m['entries'] as List) v as int];
        if (c.assistant && !g.allowed(c.slot, entries)) {
          return c.send({'t': 'error', 'message': g.level(c.slot) == 0 ? '${g.names[c.slot]} has not allowed assistants to command.' : 'Not allowed for an assistant.'});
        }
        g.command(entries);
      case 'advice':
        final g = c.game;
        final text = (m['text'] as String? ?? '').trim();
        if (g == null || !c.assistant || text.isEmpty) return;
        g.humans[c.slot]?.send({'t': 'advice', 'from': c.name, 'text': text.length > 2000 ? text.substring(0, 2000) : text});
      case 'allow':
        final g = c.game;
        if (g == null || c.assistant || g.humans[c.slot] != c) return;
        g.allow[c.slot] = ((m['level'] as int?) ?? 0).clamp(0, 2);
        _sendAssistants(g);
      case 'pause':
        final g = c.game;
        if (g == null) return;
        g.paused = m['on'] == true;
        g.pausedBy = c.name;
        g.pausedByClient = g.paused ? c : null;
        g.broadcast({'t': 'paused', 'on': g.paused, 'by': c.name});
      case 'report':
        if (!c.assistant) _report(c, m);
      case 'leave':
        _leave(c);
        _sendGames();
    }
  }

  void _seat(Client c, Game g, int slot, {required bool takeOver, bool assistant = false}) {
    c.game = g;
    c.slot = slot;
    c.assistant = assistant;
    if (assistant) {
      g.assistants[c] = slot;
    } else {
      g.humans[slot] = c;
      g.names[slot] = c.name;
    }
    // The new player gets the game so far; then everyone learns the slot is
    // played by a human now (a logged command, so replays agree).
    c.send({
      't': 'joined',
      'game': g.id,
      'slot': slot,
      'launch': g.launch,
      'slots': g.slots,
      'log': [for (final e in g.log) ...e],
      'upTo': g.frame,
      'paused': g.paused,
      'pausedBy': g.pausedBy,
      'assistant': assistant,
      'allow': g.level(slot),
    });
    if (takeOver) g.command([0, opSetController, 2, slot, 1]);
    g.broadcast({'t': 'players', 'names': {for (final e in g.humans.entries) '${e.key}': g.names[e.key]}});
    _sendAssistants(g);
  }

  /// Who assists whom: to each human their assistants and what they
  /// allowed, to each assistant what it may do now.
  void _sendAssistants(Game g) {
    for (final e in g.humans.entries) {
      e.value.send({
        't': 'assistants',
        'names': [for (final a in g.assistants.entries) if (a.value == e.key) a.key.name],
        'allow': g.allow[e.key] ?? 0,
      });
    }
    for (final e in g.assistants.entries) {
      e.key.send({'t': 'allow', 'level': g.level(e.value)});
    }
  }

  void _leave(Client c, {bool gone = false}) {
    final g = c.game;
    if (gone) clients.remove(c);
    if (g == null) return;
    c.game = null;
    if (c.assistant) {
      g.assistants.remove(c);
      c.assistant = false;
      c.slot = -1;
      _sendAssistants(g);
      if (gone) _sendGames();
      return;
    }
    // A pause ends with the player who paused leaving.
    if (g.paused && g.pausedByClient == c) {
      g.paused = false;
      g.pausedByClient = null;
      g.broadcast({'t': 'paused', 'on': false, 'by': c.name});
    }
    if (g.humans[c.slot] == c) {
      g.humans.remove(c.slot);
      g.allow.remove(c.slot);
      _sendAssistants(g);
      // The computer plays the slot again.
      g.command([0, opSetController, 2, c.slot, 0]);
      g.broadcast({'t': 'players', 'names': {for (final e in g.humans.entries) '${e.key}': g.names[e.key]}});
    }
    c.slot = -1;
    // Nobody left: the game waits (its clock stops) until someone joins.
    if (g.humans.isEmpty && g.assistants.isEmpty) {
      // Kept so it can be joined again; dropped after an hour alone.
      Timer(const Duration(hours: 1), () {
        if (g.humans.isEmpty && g.assistants.isEmpty) games.remove(g.id);
      });
    }
    if (gone) _sendGames();
  }

  void _report(Client c, Map<String, dynamic> m) {
    final g = c.game;
    if (g == null) return;
    g.groups = [for (final v in (m['groups'] as List? ?? const [])) v as int];
    g.active = [for (final v in (m['active'] as List? ?? const [])) v as int];
    final frame = m['frame'] as int, hash = m['hash'] as int;
    final at = g.hashes.putIfAbsent(frame, () => {});
    at[c.slot] = hash;
    if (Platform.environment['BROOD_SERVER_DEBUG'] == '1') stdout.writeln('game ${g.id} frame $frame slot ${c.slot} hash $hash');
    if (at.values.toSet().length > 1) {
      stdout.writeln('Game ${g.id}: out of sync at frame $frame: $at');
      g.broadcast({'t': 'desync', 'frame': frame});
    }
    g.hashes.removeWhere((f, _) => f < frame - 24 * 60);
  }
}
