// Desktop storage: one file per key under $XDG_DATA_HOME/brood/.

import 'dart:io';

import 'storage.dart';

AppStorage createStorage() => FileStorage();

class FileStorage extends AppStorage {
  static String _base() {
    final env = Platform.environment;
    final base = env['XDG_DATA_HOME']?.isNotEmpty == true ? env['XDG_DATA_HOME']! : '${env['HOME'] ?? '.'}/.local/share';
    return '$base/brood';
  }

  // Tests point single files or the saves folder elsewhere.
  File _file(String key) {
    final env = Platform.environment;
    String? override(String name) => env[name]?.isNotEmpty == true ? env[name] : null;
    if (key == 'settings.json' && override('BROOD_SETTINGS_FILE') != null) return File(override('BROOD_SETTINGS_FILE')!);
    if (key == 'play_stats.json' && override('BROOD_STATS_FILE') != null) return File(override('BROOD_STATS_FILE')!);
    if (key.startsWith('saves/') && override('BROOD_SAVES_DIR') != null) return File('${override('BROOD_SAVES_DIR')}/${key.substring(6)}');
    return File('${_base()}/$key');
  }

  @override
  String? read(String key) {
    try {
      final f = _file(key);
      return f.existsSync() ? f.readAsStringSync() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  void write(String key, String value) {
    final f = _file(key);
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(value);
    tmp.renameSync(f.path);
  }

  @override
  Future<void> writeAsync(String key, String value) async {
    final f = _file(key);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(value, flush: true);
    await tmp.rename(f.path);
  }

  @override
  void delete(String key) {
    try {
      final f = _file(key);
      if (f.existsSync()) f.deleteSync();
      // Drop folders left empty (a deleted save session).
      var dir = f.parent;
      final root = _file(key.startsWith('saves/') ? 'saves/x' : 'x').parent.path;
      while (dir.path.length > root.length && dir.existsSync() && dir.listSync().isEmpty) {
        dir.deleteSync();
        dir = dir.parent;
      }
    } catch (_) {}
  }

  @override
  List<String> keys(String prefix) {
    // Keys map onto paths: list the folder holding the prefix.
    final slash = prefix.lastIndexOf('/');
    final folderKey = slash < 0 ? '' : prefix.substring(0, slash + 1);
    final dir = folderKey.isEmpty ? Directory(_base()) : _file('${folderKey}x').parent;
    if (!dir.existsSync()) return const [];
    final out = <String>[];
    for (final e in dir.listSync(recursive: true).whereType<File>()) {
      if (e.path.endsWith('.tmp')) continue;
      final key = folderKey + e.path.substring(dir.path.length + 1);
      if (key.startsWith(prefix)) out.add(key);
    }
    return out;
  }

  @override
  String describe(String key) => _file(key).path;
}
