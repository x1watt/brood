// Browser game data: the player picks their game folder once; the MPQs and
// maps are kept in IndexedDB ('files' store, keyed by path relative to the
// game folder) and written into the engine's in-memory file system under
// /data at every start, where OpenBW opens them as on desktop.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../engine/bridge_raw_web.dart';
import '../platform/idb.dart';
import 'game_data.dart';

GameFiles createGameFiles() => WebGameFiles();

/// The archives the engine needs, by their canonical names.
const List<String> requiredArchives = ['StarDat.mpq', 'BrooDat.mpq', 'Patch_rt.mpq'];

class WebGameFiles extends GameFiles {
  static WebGameFiles get current => GameFiles.instance as WebGameFiles;

  final List<String> _files = []; // relative paths mounted under /data
  bool _ready = false;

  @override
  String get dataDir => '/data';

  @override
  bool get ready => _ready;

  @override
  String get description => 'your game files, kept in this browser';

  @override
  List<GameMap> maps() => [for (final f in _files) if (GameMap.isMeleeMap('/$f')) GameMap('/data/$f')];

  @override
  bool exists(String path) => path.startsWith('/data/') && _files.contains(path.substring(6));

  @override
  Future<bool> init() async {
    // Ask the browser to keep the files: storage the page didn't ask to
    // keep may be cleared when space runs low.
    try {
      await web.window.navigator.storage.persist().toDart;
    } catch (_) {}
    final db = await BroodDb.open();
    var keys = await db.keys(BroodDb.files);
    if (!requiredArchives.every(keys.contains)) return _ready = false;
    // From the home server: maps added since (a new map on the server shows
    // up without importing everything again).
    if (await _fetchNewFromServer(db, keys)) keys = await db.keys(BroodDb.files);
    final bridge = await BridgeRawWeb.open();
    final fs = bridge.fs;
    _files.clear();
    for (final key in keys) {
      final value = await db.get(BroodDb.files, key);
      if (value == null) continue;
      final bytes = (value as JSArrayBuffer).toDart.asUint8List();
      _mkdirs(fs, '/data/$key');
      fs.callMethodVarArgs('writeFile'.toJS, ['/data/$key'.toJS, bytes.toJS]);
      _files.add(key);
    }
    return _ready = true;
  }

  Future<bool> _fetchNewFromServer(BroodDb db, List<String> have) async {
    final base = await serverFiles();
    if (base == null) return false;
    try {
      final r = await web.window.fetch('${base}manifest.json'.toJS).toDart;
      final list = ((await r.json().toDart) as JSArray<JSString>).toDart.map((e) => e.toDart);
      var added = false;
      for (final rel in list.where((f) => !have.contains(f))) {
        final file = await web.window.fetch('$base$rel'.toJS).toDart;
        if (!file.ok) continue;
        await db.put(BroodDb.files, rel, await file.arrayBuffer().toDart);
        added = true;
      }
      return added;
    } catch (_) {
      return false;
    }
  }

  static void _mkdirs(JSObject fs, String filePath) {
    final parts = filePath.split('/')..removeLast();
    var dir = '';
    for (final p in parts.where((p) => p.isNotEmpty)) {
      dir += '/$p';
      try {
        fs.callMethodVarArgs('mkdir'.toJS, [dir.toJS]);
      } catch (_) {
        // Already there.
      }
    }
  }

  /// Opens the browser's folder picker and imports the game files from the
  /// chosen folder. [progress] gets (files done, files to do). Returns an
  /// error message, or null when the game is ready.
  @override
  Future<String?> pickAndImport(void Function(int done, int total) progress, {bool folder = true}) async {
    final picked = await _pick(folder);
    if (picked.isEmpty) return 'No files were chosen.';
    // What to keep: the three archives (by name, anywhere) and melee maps
    // under a maps/ folder.
    final keep = <String, web.File>{};
    for (final f in picked) {
      final rel = f.webkitRelativePath.isNotEmpty ? f.webkitRelativePath : f.name;
      final parts = rel.split('/');
      final base = parts.last;
      final archive = requiredArchives.where((a) => a.toLowerCase() == base.toLowerCase()).firstOrNull;
      if (archive != null) {
        keep[archive] = f;
        continue;
      }
      final mapsAt = parts.indexWhere((p) => p.toLowerCase() == 'maps');
      final key = mapsAt >= 0 ? (['maps', ...parts.sublist(mapsAt + 1)]).join('/') : 'maps/$base';
      if (GameMap.isMeleeMap('/$key')) keep[key] = f;
    }
    final missing = requiredArchives.where((a) => !keep.containsKey(a)).toList();
    if (missing.isNotEmpty) return 'These files are missing from what you chose: ${missing.join(', ')}.';
    final db = await BroodDb.open();
    int done = 0;
    for (final e in keep.entries) {
      final buffer = await e.value.arrayBuffer().toDart;
      await db.put(BroodDb.files, e.key, buffer);
      progress(++done, keep.length);
    }
    final ok = await init();
    return ok ? null : 'The game files could not be loaded.';
  }

  /// Tests only (a build made with `--dart-define=BROOD_TEST_DATA=url`):
  /// imports the files listed in `url` + manifest.json from the same server,
  /// so no file dialog is needed.
  @override
  Future<String?> importFromUrl(String base, void Function(int done, int total) progress) async {
    Future<JSArrayBuffer> fetchBytes(String url) async {
      final r = await web.window.fetch(url.toJS).toDart;
      if (!r.ok) throw StateError('$url: ${r.status}');
      return r.arrayBuffer().toDart;
    }

    try {
      final manifest = await web.window.fetch('${base}manifest.json'.toJS).toDart;
      final list = ((await manifest.json().toDart) as JSArray<JSString>).toDart.map((e) => e.toDart).toList();
      final db = await BroodDb.open();
      int done = 0;
      for (final rel in list) {
        await db.put(BroodDb.files, rel, await fetchBytes('$base$rel'));
        progress(++done, list.length);
      }
    } catch (e) {
      return 'Test data import failed: $e';
    }
    return await init() ? null : 'The game files could not be loaded.';
  }

  @override
  Future<String?> serverFiles() async {
    try {
      final r = await web.window.fetch('gamedata/manifest.json'.toJS).toDart;
      if (!r.ok) return null;
      final list = (await r.json().toDart) as JSArray<JSAny?>;
      return list.length > 0 ? 'gamedata/' : null;
    } catch (_) {
      return null;
    }
  }

  Future<List<web.File>> _pick(bool folder) {
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..multiple = true;
    if (folder) input.setAttribute('webkitdirectory', '');
    final done = Future<List<web.File>>(() async {
      final changed = input.onChange.first;
      final cancelled = const web.EventStreamProvider<web.Event>('cancel').forTarget(input).first;
      await Future.any([changed, cancelled]);
      final list = input.files;
      if (list == null) return <web.File>[];
      return [for (int i = 0; i < list.length; ++i) list.item(i)!];
    });
    input.click();
    return done;
  }

  /// Forgets the imported files (the player can choose again).
  @override
  Future<void> forget() async {
    final db = await BroodDb.open();
    await db.clear(BroodDb.files);
    _ready = false;
  }

  static Uint8List bytesOf(JSArrayBuffer b) => b.toDart.asUint8List();
}
