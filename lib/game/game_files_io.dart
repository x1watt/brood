// Game data on disk: on desktop a folder (BROOD_DATA, default
// ~/box/media/games/BROOD); on Android the app's own storage
// (Android/data/com.maxbrito.brood/files/BROOD), filled by importing the
// player's folder or by copying the files there over USB.

import 'dart:io';

import '../platform/android_files.dart';
import 'game_data.dart';

GameFiles createGameFiles() => _FolderGameFiles();

class _FolderGameFiles extends GameFiles {
  @override
  String get dataDir {
    if (Platform.isAndroid) return '${AndroidFiles.externalDir}/BROOD';
    final home = Platform.environment['HOME'] ?? '';
    return Platform.environment['BROOD_DATA'] ?? '$home/box/media/games/BROOD';
  }

  @override
  bool get ready => File('$dataDir/StarDat.mpq').existsSync();

  @override
  Future<bool> init() async {
    if (Platform.isAndroid) await AndroidFiles.load();
    return ready;
  }

  @override
  Future<String?> pickAndImport(void Function(int done, int total) progress, {bool folder = true}) async {
    if (!Platform.isAndroid) return super.pickAndImport(progress, folder: folder);
    final error = await AndroidFiles.pickGameFolder(progress);
    if (error != null) return error;
    return ready ? null : 'The game files could not be found after copying.';
  }

  @override
  String get description => Platform.isAndroid ? 'your game files, kept in this app' : dataDir;

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
