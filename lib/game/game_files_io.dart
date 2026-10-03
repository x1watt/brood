// Desktop game data: a folder on disk (BROOD_DATA, default
// ~/box/media/games/BROOD).

import 'dart:io';

import 'game_data.dart';

GameFiles createGameFiles() => _FolderGameFiles();

class _FolderGameFiles extends GameFiles {
  @override
  String get dataDir {
    final home = Platform.environment['HOME'] ?? '';
    return Platform.environment['BROOD_DATA'] ?? '$home/box/media/games/BROOD';
  }

  @override
  bool get ready => File('$dataDir/StarDat.mpq').existsSync();

  @override
  Future<bool> init() async => ready;

  @override
  String get description => dataDir;

  @override
  List<GameMap> maps() {
    final dir = Directory('$dataDir/maps');
    if (!dir.existsSync()) return [];
    return dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => GameMap.isMeleeMap(f.path.substring(dataDir.length)))
        .map((f) => GameMap(f.path))
        .toList();
  }

  @override
  bool exists(String path) => File(path).existsSync();
}
