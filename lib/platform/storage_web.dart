// Browser storage: IndexedDB (database 'brood', store 'kv'), cached in
// memory so reads stay synchronous; writes go through in the background.

import 'dart:js_interop';

import 'idb.dart';
import 'storage.dart';

AppStorage createStorage() => WebStorage();

class WebStorage extends AppStorage {
  final Map<String, String> _cache = {};

  @override
  Future<void> load() async {
    final db = await BroodDb.open();
    final all = await db.getAll(BroodDb.kv);
    all.forEach((k, v) {
      if (v.isA<JSString>()) _cache[k] = (v as JSString).toDart;
    });
  }

  @override
  String? read(String key) => _cache[key];

  @override
  void write(String key, String value) {
    _cache[key] = value;
    BroodDb.open().then((db) => db.put(BroodDb.kv, key, value.toJS));
  }

  @override
  Future<void> writeAsync(String key, String value) async {
    _cache[key] = value;
    final db = await BroodDb.open();
    await db.put(BroodDb.kv, key, value.toJS);
  }

  @override
  void delete(String key) {
    _cache.remove(key);
    BroodDb.open().then((db) => db.delete(BroodDb.kv, key));
  }

  @override
  List<String> keys(String prefix) => [for (final k in _cache.keys) if (k.startsWith(prefix)) k];

  @override
  String describe(String key) => 'browser storage ($key)';
}
