// lib/net/multiplayer.dart
//
// The client side of multiplayer (the server is lib/net/home_server.dart):
// the lobby of games running on the home server, and the session of the
// game being played. The game itself stays in GameController: in a
// multiplayer game the engine's commands are deferred (sent here instead
// of run), come back from the server stamped with a frame, and run on that
// frame in every player's browser; the server's ticks say how far the game
// may run.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'ws.dart';

/// A player of a game in the lobby: a computer, or the human playing it.
class LobbySlot {
  final int slot;
  final int race;
  final String name; // the computer's name in the game ("Computer 2")
  final String? human; // who plays it, null for the computer
  final int group; // alliance (equal groups are allied)
  final bool active; // still in the game
  const LobbySlot({required this.slot, required this.race, required this.name, this.human, this.group = 0, this.active = true});

  static LobbySlot fromJson(Map<String, dynamic> j) => LobbySlot(
    slot: j['slot'] as int,
    race: j['race'] as int? ?? 0,
    name: j['name'] as String? ?? 'Player',
    human: j['human'] as String?,
    group: j['group'] as int? ?? 0,
    active: j['active'] != false,
  );
}

class LobbyGame {
  final int id;
  final String mapName;
  final int frame;
  final bool paused;
  final List<LobbySlot> slots;
  const LobbyGame({required this.id, required this.mapName, required this.frame, required this.paused, required this.slots});

  static LobbyGame fromJson(Map<String, dynamic> j) => LobbyGame(
    id: j['id'] as int,
    mapName: j['mapName'] as String? ?? '',
    frame: j['frame'] as int? ?? 0,
    paused: j['paused'] == true,
    slots: [for (final s in j['slots'] as List) LobbySlot.fromJson(s as Map<String, dynamic>)],
  );
}

class MpClient {
  final TextSocket _socket;
  String name;
  final ValueNotifier<List<LobbyGame>> games = ValueNotifier(const []);
  /// Addresses of the server others at home can open.
  final ValueNotifier<List<String>> urls = ValueNotifier(const []);
  MpSession? session;
  Completer<MpSession>? _joining;
  bool closed = false;

  MpClient._(this._socket, this.name) {
    _socket.messages.listen(_message, onDone: () {
      closed = true;
      session?._lost();
      if (identical(_instance, this)) _instance = null;
    });
  }

  static MpClient? _instance;
  static Future<MpClient?>? _connecting;

  /// The connection to the home server, when there is one (the page was
  /// opened from one; the app's own when it shares the game on the network,
  /// lib/net/lan_host.dart; elsewhere BROOD_SERVER).
  static MpClient? get current => _instance;

  /// Connects to [url], by default the page's own server or BROOD_SERVER.
  static Future<MpClient?> connect(String name, {Uri? url}) {
    if (_instance != null && !_instance!.closed) return Future.value(_instance);
    return _connecting ??= () async {
      final to = url ?? defaultServer();
      final socket = to == null ? null : await TextSocket.connect(to);
      _connecting = null;
      if (socket == null) return null;
      final c = MpClient._(socket, name.trim().isEmpty ? 'Player' : name.trim());
      c.send({'t': 'hello', 'name': c.name});
      return _instance = c;
    }();
  }

  void send(Map<String, Object?> m) => _socket.send(jsonEncode(m));

  void rename(String n) {
    name = n.trim().isEmpty ? 'Player' : n.trim();
    send({'t': 'hello', 'name': name});
  }

  /// Puts the game just started (or loaded) on the server for others to
  /// join. [log] and [frame] are where it stands (a loaded game's replay).
  Future<MpSession> host({required Map<String, Object?> launch, required List<Map<String, Object?>> slots, required int slot, required List<int> log, required int frame}) {
    _joining = Completer();
    send({'t': 'create', 'launch': launch, 'slots': slots, 'slot': slot, 'log': log, 'frame': frame});
    return _joining!.future;
  }

  /// Joins a game in the lobby, taking over the computer player [slot].
  Future<MpSession> join(int game, int slot) {
    _joining = Completer();
    send({'t': 'join', 'game': game, 'slot': slot});
    return _joining!.future;
  }

  void _message(String text) {
    final m = jsonDecode(text) as Map<String, dynamic>;
    switch (m['t']) {
      case 'info':
        urls.value = [for (final u in m['urls'] as List? ?? const []) u as String];
      case 'games':
        games.value = [for (final g in m['games'] as List) LobbyGame.fromJson(g as Map<String, dynamic>)];
      case 'joined':
        final s = MpSession._(this, m);
        session = s;
        _joining?.complete(s);
        _joining = null;
      case 'error':
        final j = _joining;
        _joining = null;
        if (j != null) {
          j.completeError(StateError(m['message'] as String? ?? 'Refused'));
        } else {
          session?.notice('${m['message']}');
        }
      default:
        session?._message(m);
    }
  }
}

/// The multiplayer game being played.
class MpSession extends ChangeNotifier {
  final MpClient client;
  final int gameId;
  final int slot; // the player this browser plays
  final Map<String, dynamic> launch;
  final List<Map<String, dynamic>> slots;
  final List<int> initialLog; // [frame, op, n, args...] entries so far
  int upTo; // the server's clock: the game may run up to this frame
  bool paused;
  String pausedBy;
  Map<int, String> names = {}; // slot -> human player
  bool lost = false; // the connection to the server is gone
  bool outOfSync = false;
  String? lastNotice;

  /// Assistants (docs/agent_api.md): programs following this player's game
  /// (tool/brood_agent.dart), what they may do (0 advise, 1 steer the
  /// auto-play, 2 command everything), and their latest advice.
  List<String> assistants = const [];
  int allow = 0;
  ({String from, String text})? advice;

  /// Commands to run, by frame (entries in log format).
  final SplayTreeMap<int, List<int>> pending = SplayTreeMap();

  MpSession._(this.client, Map<String, dynamic> m)
    : gameId = m['game'] as int,
      slot = m['slot'] as int,
      launch = Map<String, dynamic>.from(m['launch'] as Map),
      slots = [for (final s in m['slots'] as List) Map<String, dynamic>.from(s as Map)],
      initialLog = [for (final v in m['log'] as List) v as int],
      upTo = m['upTo'] as int,
      paused = m['paused'] == true,
      pausedBy = m['pausedBy'] as String? ?? '';

  void _message(Map<String, dynamic> m) {
    switch (m['t']) {
      case 'cmd':
        // Entries carry the sender's frame; they run at the server's.
        final frame = m['frame'] as int;
        final entries = [for (final v in m['entries'] as List) v as int];
        for (int i = 0; i + 3 <= entries.length; i += 3 + entries[i + 2]) {
          entries[i] = frame;
        }
        pending.putIfAbsent(frame, () => []).addAll(entries);
      case 'tick':
        upTo = m['upTo'] as int;
        return; // no rebuild for every tick
      case 'paused':
        paused = m['on'] == true;
        pausedBy = m['by'] as String? ?? '';
      case 'players':
        names = {for (final e in (m['names'] as Map).entries) int.parse(e.key as String): e.value as String};
      case 'desync':
        outOfSync = true;
      case 'assistants':
        assistants = [for (final n in m['names'] as List? ?? const []) n as String];
        allow = m['allow'] as int? ?? 0;
      case 'advice':
        advice = (from: m['from'] as String? ?? 'Assistant', text: m['text'] as String? ?? '');
    }
    notifyListeners();
  }

  void _lost() {
    lost = true;
    notifyListeners();
  }

  void notice(String text) {
    lastNotice = text;
    notifyListeners();
  }

  /// Commands to run when the game reaches [frame] (and removes them).
  List<int>? takeFor(int frame) => pending.remove(frame);

  /// Joining: everything to replay up to the server's clock now (the log
  /// at joining, then whatever arrived while the game was loading);
  /// commands for later frames stay pending. Returns (log, frame).
  (List<int>, int) catchUp() {
    final target = upTo;
    final log = <int>[];
    for (int i = 0; i + 3 <= initialLog.length;) {
      final k = 3 + initialLog[i + 2];
      final entry = initialLog.sublist(i, i + k);
      if (entry[0] <= target) {
        log.addAll(entry);
      } else {
        // (Before anything that arrived later for the same frame.)
        pending[entry[0]] = [...entry, ...?pending[entry[0]]];
      }
      i += k;
    }
    for (final f in pending.keys.where((f) => f <= target).toList()) {
      log.addAll(pending.remove(f)!);
    }
    return (log, target);
  }

  void sendCommands(List<int> entries) {
    if (entries.isNotEmpty) client.send({'t': 'cmd', 'entries': entries});
  }

  void pause(bool on) => client.send({'t': 'pause', 'on': on});

  /// What this player's assistants may do (see [allow]).
  void setAllow(int level) {
    allow = level;
    client.send({'t': 'allow', 'level': level});
    notifyListeners();
  }

  void dismissAdvice() {
    advice = null;
    notifyListeners();
  }

  /// Every few seconds: a hash of the game at [frame] (to catch players
  /// drifting apart) and the alliances, for the lobby.
  void report(int frame, int hash, List<int> groups, List<int> active) =>
      client.send({'t': 'report', 'frame': frame, 'hash': hash, 'groups': groups, 'active': active});

  void leave() {
    client.send({'t': 'leave'});
    if (identical(client.session, this)) client.session = null;
  }
}
