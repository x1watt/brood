// lib/platform/idb.dart
//
// Minimal IndexedDB access for the browser build: one database 'brood' with
// two object stores, 'kv' (the app's own data as strings) and 'files' (the
// player's game files as bytes, imported once). Keys are strings.

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

class BroodDb {
  static const kv = 'kv';
  static const files = 'files';

  final web.IDBDatabase _db;
  BroodDb._(this._db);

  static Future<BroodDb>? _opening;

  static Future<BroodDb> open() => _opening ??= _open();

  static Future<BroodDb> _open() {
    final c = Completer<BroodDb>();
    final req = web.window.indexedDB.open('brood', 1);
    req.onupgradeneeded = (web.Event _) {
      final db = req.result as web.IDBDatabase;
      for (final name in [kv, files]) {
        if (!db.objectStoreNames.contains(name)) db.createObjectStore(name);
      }
    }.toJS;
    req.onsuccess = ((web.Event _) => c.complete(BroodDb._(req.result as web.IDBDatabase))).toJS;
    req.onerror = ((web.Event _) => c.completeError(StateError('IndexedDB: ${req.error?.message}'))).toJS;
    return c.future;
  }

  Future<T> _wait<T extends JSAny?>(web.IDBRequest req) {
    final c = Completer<T>();
    req.onsuccess = ((web.Event _) => c.complete(req.result as T)).toJS;
    req.onerror = ((web.Event _) => c.completeError(StateError('IndexedDB: ${req.error?.message}'))).toJS;
    return c.future;
  }

  web.IDBObjectStore _store(String name, String mode) => _db.transaction(name.toJS, mode).objectStore(name);

  Future<void> put(String store, String key, JSAny value) => _wait<JSAny?>(_store(store, 'readwrite').put(value, key.toJS));

  Future<JSAny?> get(String store, String key) => _wait<JSAny?>(_store(store, 'readonly').get(key.toJS));

  Future<void> delete(String store, String key) => _wait<JSAny?>(_store(store, 'readwrite').delete(key.toJS));

  Future<void> clear(String store) => _wait<JSAny?>(_store(store, 'readwrite').clear());

  Future<List<String>> keys(String store) async {
    final r = await _wait<JSArray<JSAny?>>(_store(store, 'readonly').getAllKeys());
    return [for (final k in r.toDart) if (k != null && k.isA<JSString>()) (k as JSString).toDart];
  }

  /// Every key with its value.
  Future<Map<String, JSAny>> getAll(String store) async {
    final s = _store(store, 'readonly');
    final keysReq = s.getAllKeys();
    final valuesReq = s.getAll();
    final keys = await _wait<JSArray<JSAny?>>(keysReq);
    final values = await _wait<JSArray<JSAny?>>(valuesReq);
    final out = <String, JSAny>{};
    final k = keys.toDart, v = values.toDart;
    for (int i = 0; i < k.length && i < v.length; ++i) {
      final key = k[i], value = v[i];
      if (key != null && key.isA<JSString>() && value != null) out[(key as JSString).toDart] = value;
    }
    return out;
  }

  /// Quota left for the site, in bytes (null when unknown).
  static Future<int?> freeSpace() async {
    try {
      final est = await web.window.navigator.storage.estimate().toDart;
      final quota = est.getProperty<JSNumber?>('quota'.toJS)?.toDartInt;
      final usage = est.getProperty<JSNumber?>('usage'.toJS)?.toDartInt;
      return quota == null || usage == null ? null : quota - usage;
    } catch (_) {
      return null;
    }
  }
}
