// lib/game/saved_games.dart
//
// Saved games in $XDG_DATA_HOME/brood/saves/ (BROOD_SAVES_DIR overrides),
// one JSON file each: the map, the resolved setup and the engine's command
// log. Loading starts the same game and replays the log; the simulation is
// deterministic, so it arrives at the same moment of play.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'game_setup.dart';

class SavedGame {
  static const int formatVersion = 1;

  final File file;
  final String name;
  final DateTime saved;
  final String mapFile;
  final String mapKey;
  final String mapName;
  final GameSetup setup;
  final SavedGameData data;

  const SavedGame({
    required this.file,
    required this.name,
    required this.saved,
    required this.mapFile,
    required this.mapKey,
    required this.mapName,
    required this.setup,
    required this.data,
  });

  static Directory directory() {
    final env = Platform.environment;
    final override = env['BROOD_SAVES_DIR'];
    if (override != null && override.isNotEmpty) return Directory(override);
    final base = env['XDG_DATA_HOME']?.isNotEmpty == true ? env['XDG_DATA_HOME']! : '${env['HOME'] ?? '.'}/.local/share';
    return Directory('$base/brood/saves');
  }

  GameLaunch toLaunch() => GameLaunch(mapFile: mapFile, mapKey: mapKey, mapName: mapName, setup: setup, saved: data);

  /// Game time at the save, as the original's clock shows it.
  String get gameTime {
    final seconds = data.frame * 42 ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

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

  static SavedGame write({
    required String name,
    required String mapFile,
    required String mapKey,
    required String mapName,
    required GameSetup setup,
    required SavedGameData data,
  }) {
    final dir = directory()..createSync(recursive: true);
    final now = DateTime.now();
    final file = File('${dir.path}/save_${now.millisecondsSinceEpoch}.json');
    final json = {
      'version': formatVersion,
      'name': name,
      'saved': now.toIso8601String(),
      'mapFile': mapFile,
      'mapKey': mapKey,
      'mapName': mapName,
      'setup': setup.toJson(),
      'frame': data.frame,
      'camX': data.camX,
      'camY': data.camY,
      'log': _encodeLog(data.commandLog),
    };
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(json));
    tmp.renameSync(file.path);
    return SavedGame(file: file, name: name, saved: now, mapFile: mapFile, mapKey: mapKey, mapName: mapName, setup: setup, data: data);
  }

  static SavedGame? read(File f) {
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      if ((j['version'] as num?)?.toInt() != formatVersion) return null;
      return SavedGame(
        file: f,
        name: j['name'] as String? ?? 'Saved game',
        saved: DateTime.tryParse(j['saved'] as String? ?? '') ?? f.lastModifiedSync(),
        mapFile: j['mapFile'] as String,
        mapKey: j['mapKey'] as String? ?? j['mapFile'] as String,
        mapName: j['mapName'] as String? ?? '',
        setup: GameSetup.fromJson(j['setup'] as Map<String, dynamic>),
        data: SavedGameData(
          commandLog: _decodeLog(j['log'] as String),
          frame: (j['frame'] as num).toInt(),
          camX: (j['camX'] as num?)?.toDouble() ?? 0,
          camY: (j['camY'] as num?)?.toDouble() ?? 0,
        ),
      );
    } catch (_) {
      return null; // unreadable or from another version: not listed
    }
  }

  /// Newest first.
  static List<SavedGame> list() {
    final dir = directory();
    if (!dir.existsSync()) return const [];
    final saves = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .map(read)
        .whereType<SavedGame>()
        .toList();
    saves.sort((a, b) => b.saved.compareTo(a.saved));
    return saves;
  }

  void delete() {
    try {
      file.deleteSync();
    } catch (_) {}
  }
}
