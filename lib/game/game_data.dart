// lib/game/game_data.dart
//
// The player's own copy of the game (never bundled, see
// docs/third_party_licensing.md): the three MPQ archives and the maps.
//   - desktop: a folder on disk (game_files_io.dart),
//   - browser: files the player picked once, kept in IndexedDB and written
//     into the engine's in-memory file system at start (game_files_web.dart).

import 'dart:typed_data';

import 'game_files_io.dart' if (dart.library.js_interop) 'game_files_web.dart' as platform;

abstract class GameFiles {
  static GameFiles? _instance;
  static GameFiles get instance => _instance ??= platform.createGameFiles();

  /// Whether the game data is there and ready for the engine.
  bool get ready;

  /// Prepares the data (the browser loads it from storage). Returns [ready].
  Future<bool> init();

  /// The folder handed to the engine (holds the MPQs and maps/).
  String get dataDir;

  /// Where the data comes from, for the start screen.
  String get description;

  List<GameMap> maps();

  /// The player's own bot profiles (lib/game/bot_profiles.dart): every .bot
  /// file under bots/, by path relative to it.
  Future<Map<String, String>> botFiles() async => const {};

  bool exists(String path);

  /// Writes a map (the map editor's save), creating or replacing it.
  /// [relativePath] is under the game data folder ("maps/Brood/My map.scm").
  /// Returns the path the engine opens it by.
  Future<String> saveMap(String relativePath, Uint8List bytes);

  /// Browser only: asks for the game folder (or the files) and imports it.
  /// Returns an error message, or null when the game data is ready.
  Future<String?> pickAndImport(void Function(int done, int total) progress, {bool folder = true}) async =>
      'Choose the game folder with BROOD_DATA on this platform.';

  /// Browser tests only: imports the game files listed in `base` + manifest.json.
  Future<String?> importFromUrl(String base, void Function(int done, int total) progress) async => 'Not available here.';

  /// Where the page's own server offers the game files (the home server,
  /// tool/brood_server.dart), or null.
  Future<String?> serverFiles() async => null;

  /// Browser only: forgets imported game files.
  Future<void> forget() async {}
}

String get gameDataDir => GameFiles.instance.dataDir;

class GameMap {
  final String path; // as the engine opens it
  const GameMap(this.path);

  /// Path relative to the game data folder (the key for play stats).
  String get key => path.startsWith('$gameDataDir/') ? path.substring(gameDataDir.length + 1) : path;

  String get name => path.split('/').last.replaceAll(RegExp(r'\.sc[mx]$', caseSensitive: false), '');

  String get folder {
    final k = key;
    final slash = k.lastIndexOf('/');
    return slash < 0 ? '' : k.substring(0, slash);
  }

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

  /// Melee maps only (campaign, scenario and save folders skipped).
  static bool isMeleeMap(String relativePath) {
    final p = relativePath.toLowerCase();
    if (!p.endsWith('.scm') && !p.endsWith('.scx')) return false;
    return !p.contains('/save/') && !p.contains('/campaign/') && !p.contains('/scenario/');
  }

  static List<GameMap> list() => GameFiles.instance.maps();
}
