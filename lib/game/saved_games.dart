// lib/game/saved_games.dart
//
// Saved games, organised in sessions: 'saves/' in the app storage
// (lib/platform/storage.dart; on desktop $XDG_DATA_HOME/brood/saves/,
// BROOD_SAVES_DIR overrides) holds one folder per session, a continuous
// stretch of play on one map. A session keeps points in time (auto-saves
// every few minutes, and manual saves); any of them can be loaded. Saving
// manually, or carrying on from a loaded point, starts a new session, so
// earlier timelines are never overwritten. Auto-saves come every game
// minute, every ten minutes after the first hour and every hour after ten.
//
//   saves/<session folder>/session.json   name, map, setup, list of points
//   saves/<session folder>/t<frame>.json  one point: the engine's command log
//
// A point is the resolved setup plus the command log; loading starts the
// same game and replays the log, and the deterministic simulation arrives
// at the same moment of play.

import 'dart:convert';
import 'dart:typed_data';

import '../platform/storage.dart';
import 'game_setup.dart';

class SavePoint {
  final String file; // inside the session folder
  final int frame;
  final DateTime saved;
  final bool manual;
  final String name; // manual saves only

  const SavePoint({required this.file, required this.frame, required this.saved, required this.manual, this.name = ''});

  /// Game time, as the original's clock shows it.
  String get gameTime {
    final seconds = frame * 42 ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() => {'file': file, 'frame': frame, 'saved': saved.toIso8601String(), 'manual': manual, if (name.isNotEmpty) 'name': name};

  static SavePoint fromJson(Map<String, dynamic> j) => SavePoint(
    file: j['file'] as String,
    frame: (j['frame'] as num).toInt(),
    saved: DateTime.tryParse(j['saved'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
    manual: j['manual'] == true,
    name: j['name'] as String? ?? '',
  );
}

class SaveSession {
  static const int formatVersion = 2;
  // Enough for the auto-save schedule (minutes, then tens of minutes,
  // then hours) over a very long game; the oldest go first beyond that.
  static const int maxAutoPoints = 240;

  final String id; // the session's folder under saves/
  final String name;
  final DateTime created;
  final String mapFile;
  final String mapKey;
  final String mapName;
  final GameSetup setup;
  final String origin; // where it branched from, '' for a new game
  final List<SavePoint> points;

  SaveSession._(this.id, this.name, this.created, this.mapFile, this.mapKey, this.mapName, this.setup, this.origin, this.points);

  static AppStorage get _store => AppStorage.instance;
  String get _prefix => 'saves/$id/';

  DateTime get lastSaved => points.isEmpty ? created : points.map((p) => p.saved).reduce((a, b) => a.isAfter(b) ? a : b);
  SavePoint? get latest => points.isEmpty ? null : points.reduce((a, b) => a.frame >= b.frame ? a : b);

  static String _two(int v) => v.toString().padLeft(2, '0');

  static SaveSession create({
    required String name,
    required String mapFile,
    required String mapKey,
    required String mapName,
    required GameSetup setup,
    String origin = '',
  }) {
    final now = DateTime.now();
    final slug = mapName.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final stamp = '${now.year}${_two(now.month)}${_two(now.day)}-${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
    final taken = {for (final k in _store.keys('saves/')) k.split('/')[1]};
    var id = '$stamp-$slug';
    for (int i = 2; taken.contains(id); ++i) {
      id = '$stamp-$slug-$i';
    }
    final s = SaveSession._(id, name, now, mapFile, mapKey, mapName, setup, origin, []);
    s._writeIndex();
    return s;
  }

  Map<String, dynamic> _indexJson() => {
    'version': formatVersion,
    'name': name,
    'created': created.toIso8601String(),
    'mapFile': mapFile,
    'mapKey': mapKey,
    'mapName': mapName,
    'setup': setup.toJson(),
    if (origin.isNotEmpty) 'origin': origin,
    'points': [for (final p in points) p.toJson()],
  };

  void _writeIndex() => _store.write('${_prefix}session.json', jsonEncode(_indexJson()));

  static String _encodeLog(List<int> log) {
    final bytes = ByteData(log.length * 4);
    for (int i = 0; i < log.length; ++i) {
      bytes.setInt32(i * 4, log[i], Endian.little);
    }
    return base64Encode(bytes.buffer.asUint8List());
  }

  static List<int> _decodeLog(String s) {
    final bytes = ByteData.sublistView(base64Decode(s));
    return List<int>.generate(bytes.lengthInBytes ~/ 4, (i) => bytes.getInt32(i * 4, Endian.little), growable: false);
  }

  /// Writes a point in time (the file asynchronously, so the game doesn't
  /// stall on a long command log).
  Future<SavePoint> addPoint(SavedGameData data, {bool manual = false, String name = ''}) async {
    final file = 't${data.frame.toString().padLeft(8, '0')}${manual ? '-manual' : ''}.json';
    final json = jsonEncode({'frame': data.frame, 'camX': data.camX, 'camY': data.camY, 'log': _encodeLog(data.commandLog)});
    await _store.writeAsync('$_prefix$file', json);
    final point = SavePoint(file: file, frame: data.frame, saved: DateTime.now(), manual: manual, name: name);
    points.removeWhere((p) => p.file == file);
    points.add(point);
    points.sort((a, b) => a.frame.compareTo(b.frame));
    // Old auto-saves make room (the first point and manual saves stay).
    final autos = points.where((p) => !p.manual).toList();
    while (autos.length > maxAutoPoints) {
      final drop = autos.removeAt(1);
      points.remove(drop);
      _store.delete('$_prefix${drop.file}');
    }
    _writeIndex();
    return point;
  }

  SavedGameData readPoint(SavePoint p) {
    final text = _store.read('$_prefix${p.file}');
    if (text == null) throw StateError('save point ${p.file} is missing');
    final j = jsonDecode(text) as Map<String, dynamic>;
    return SavedGameData(
      commandLog: _decodeLog(j['log'] as String),
      frame: (j['frame'] as num).toInt(),
      camX: (j['camX'] as num?)?.toDouble() ?? 0,
      camY: (j['camY'] as num?)?.toDouble() ?? 0,
    );
  }

  GameLaunch launch(SavePoint p) =>
      GameLaunch(mapFile: mapFile, mapKey: mapKey, mapName: mapName, setup: setup, saved: readPoint(p), continues: '$name at ${p.gameTime}');

  static SaveSession? read(String id) {
    try {
      final text = _store.read('saves/$id/session.json');
      if (text == null) return null;
      final j = jsonDecode(text) as Map<String, dynamic>;
      if ((j['version'] as num?)?.toInt() != formatVersion) return null;
      return SaveSession._(
        id,
        j['name'] as String? ?? 'Session',
        DateTime.tryParse(j['created'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        j['mapFile'] as String,
        j['mapKey'] as String? ?? j['mapFile'] as String,
        j['mapName'] as String? ?? '',
        GameSetup.fromJson(j['setup'] as Map<String, dynamic>),
        j['origin'] as String? ?? '',
        [for (final p in j['points'] as List? ?? const []) SavePoint.fromJson(p as Map<String, dynamic>)]..sort((a, b) => a.frame.compareTo(b.frame)),
      );
    } catch (_) {
      return null;
    }
  }

  /// Every session with at least one point, most recently saved first.
  static List<SaveSession> list() {
    _migrateFlatSaves();
    final ids = <String>{};
    for (final k in _store.keys('saves/')) {
      final parts = k.split('/');
      if (parts.length == 3 && parts[2] == 'session.json') ids.add(parts[1]);
    }
    final sessions = ids.map(read).whereType<SaveSession>().where((s) => s.points.isNotEmpty).toList();
    sessions.sort((a, b) => b.lastSaved.compareTo(a.lastSaved));
    return sessions;
  }

  // Saves from before sessions (one JSON file each) become one-point sessions.
  static void _migrateFlatSaves() {
    for (final key in _store.keys('saves/').where((k) => k.split('/').length == 2 && k.endsWith('.json'))) {
      try {
        final j = jsonDecode(_store.read(key)!) as Map<String, dynamic>;
        if ((j['version'] as num?)?.toInt() != 1 || j['log'] is! String) continue;
        final saved = DateTime.tryParse(j['saved'] as String? ?? '') ?? DateTime.now();
        final frame = (j['frame'] as num).toInt();
        final s = SaveSession.create(
          name: j['name'] as String? ?? 'Saved game',
          mapFile: j['mapFile'] as String,
          mapKey: j['mapKey'] as String? ?? j['mapFile'] as String,
          mapName: j['mapName'] as String? ?? '',
          setup: GameSetup.fromJson(j['setup'] as Map<String, dynamic>),
        );
        final file = 't${frame.toString().padLeft(8, '0')}-manual.json';
        _store.write('${s._prefix}$file', jsonEncode({'frame': frame, 'camX': j['camX'], 'camY': j['camY'], 'log': j['log']}));
        s.points.add(SavePoint(file: file, frame: frame, saved: saved, manual: true, name: s.name));
        s._writeIndex();
        _store.delete(key);
      } catch (_) {
        // Leave anything unexpected alone.
      }
    }
  }

  void delete() {
    for (final k in _store.keys(_prefix)) {
      _store.delete(k);
    }
  }
}
