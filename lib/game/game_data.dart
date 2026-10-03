// lib/game/game_data.dart
//
// Where the user's own copy of the game lives (never bundled, see
// docs/third_party_licensing.md) and the melee maps found in it.

import 'dart:io';

String get gameDataDir {
  final home = Platform.environment['HOME'] ?? '';
  return Platform.environment['BROOD_DATA'] ?? '$home/box/media/games/BROOD';
}

class GameMap {
  final File file;
  const GameMap(this.file);

  String get path => file.path;

  /// Path relative to the game data folder (the key for play stats).
  String get key => path.startsWith(gameDataDir) ? path.substring(gameDataDir.length + 1) : path;

  String get name => file.uri.pathSegments.last.replaceAll(RegExp(r'\.sc[mx]$', caseSensitive: false), '');

  String get folder => file.parent.path.replaceFirst('$gameDataDir/maps', 'maps');

  /// Blizzard's maps carry their player count in the name, "(4)Lost Temple".
  /// Others are assumed to allow 8; the engine places whoever fits.
  int get maxPlayers {
    final m = RegExp(r'^\((\d)\)').firstMatch(name);
    final n = m == null ? 8 : int.parse(m.group(1)!);
    return n.clamp(2, 8);
  }

  @override
  bool operator ==(Object other) => other is GameMap && other.path == path;

  @override
  int get hashCode => path.hashCode;

  /// Melee maps under maps/ (campaign, scenario and save folders skipped).
  static List<GameMap> list() {
    final dir = Directory('$gameDataDir/maps');
    if (!dir.existsSync()) return [];
    return dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.scm') || f.path.toLowerCase().endsWith('.scx'))
        .where((f) => !f.path.contains('/save/') && !f.path.contains('/campaign/') && !f.path.contains('/scenario/'))
        .map(GameMap.new)
        .toList();
  }
}
