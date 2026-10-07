// Game data on disk: on desktop a folder (BROOD_DATA, else the copy bundled
// next to the executable in data/BROOD, else ~/box/media/games/BROOD); on
// Android the app's own storage
// (Android/data/dev.x1watt.brood/files/BROOD), filled from the copy in the
// APK at first start, by importing the player's folder or by copying the
// files there over USB.

import 'dart:io';
import 'dart:typed_data';

import '../platform/android_files.dart';
import 'game_data.dart';

GameFiles createGameFiles() => _FolderGameFiles();

class _FolderGameFiles extends GameFiles {
  @override
  String get dataDir {
    if (Platform.isAndroid) return '${AndroidFiles.externalDir}/BROOD';
    final env = Platform.environment['BROOD_DATA'];
    if (env != null) return env;
    final bundled = _bundled;
    if (bundled != null) return bundled;
    final home = Platform.environment['HOME'] ?? '';
    return '$home/box/media/games/BROOD';
  }

  // The game files bundled with the Linux build (linux/CMakeLists.txt).
  static final String? _bundled = () {
    final dir = '${File(Platform.resolvedExecutable).parent.path}/data/BROOD';
    return File('$dir/StarDat.mpq').existsSync() ? dir : null;
  }();

  @override
  bool get ready => File('$dataDir/StarDat.mpq').existsSync();

  @override
  Future<bool> init() async {
    if (Platform.isAndroid) await AndroidFiles.load();
    return ready;
  }

  @override
  Future<bool> hasBundled() async => Platform.isAndroid && await AndroidFiles.hasBundledFiles();

  @override
  Future<String?> importBundled(void Function(int done, int total) progress) async {
    final error = await AndroidFiles.installBundledFiles(progress);
    if (error != null) return error;
    return ready ? null : 'The game files could not be found after copying.';
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
  Future<Map<String, String>> botFiles() async {
    final dir = Directory('$dataDir/bots');
    if (!dir.existsSync()) return const {};
    final out = <String, String>{};
    for (final f in dir.listSync(recursive: true, followLinks: true).whereType<File>()) {
      if (!f.path.endsWith('.bot')) continue;
      final rel = f.path.substring(dir.path.length + 1).replaceAll('\\', '/');
      try {
        out[rel] = await f.readAsString();
      } catch (_) {
        // Not text: skipped.
      }
    }
    return out;
  }

  @override
  Future<void> saveBotFile(String relativePath, String text) async {
    final file = File('$dataDir/bots/$relativePath');
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<void> deleteBotFile(String relativePath) async {
    final file = File('$dataDir/bots/$relativePath');
    if (await file.exists()) await file.delete();
    // An empty profile folder goes too.
    final dir = file.parent;
    if (await dir.exists() && await dir.list().isEmpty) await dir.delete();
  }

  @override
  bool exists(String path) => File(path).existsSync();

  @override
  Future<String> saveMap(String relativePath, Uint8List bytes) async {
    final file = File('$dataDir/$relativePath');
    await file.parent.create(recursive: true);
    // Through a temporary file, so a failed write never leaves half a map.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    return file.path;
  }
}
