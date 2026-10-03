// lib/platform/storage.dart
//
// Where the app keeps its own data (settings, play stats, saved games), as
// keys like 'settings.json' or 'saves/<session>/session.json':
//   - desktop: files under $XDG_DATA_HOME/brood/ (storage_io.dart), with the
//     BROOD_SETTINGS_FILE / BROOD_STATS_FILE / BROOD_SAVES_DIR overrides,
//   - browser: IndexedDB (storage_web.dart),
//   - tests: memory.
// Reads are synchronous: the web store loads everything at start and
// writes through in the background.

import 'storage_io.dart' if (dart.library.js_interop) 'storage_web.dart' as platform;

abstract class AppStorage {
  static AppStorage? _instance;
  static AppStorage get instance => _instance ??= platform.createStorage();
  static set instance(AppStorage s) => _instance = s;

  /// Loads what the platform needs before first use (the web store).
  static Future<void> init() => instance.load();

  Future<void> load() async {}

  String? read(String key);
  void write(String key, String value);
  Future<void> writeAsync(String key, String value) async => write(key, value);
  void delete(String key);

  /// Keys starting with [prefix], in no particular order.
  List<String> keys(String prefix);

  /// A human-readable location, for messages.
  String describe(String key) => key;
}

/// For tests.
class MemoryStorage extends AppStorage {
  final Map<String, String> data = {};

  @override
  String? read(String key) => data[key];
  @override
  void write(String key, String value) => data[key] = value;
  @override
  void delete(String key) => data.remove(key);
  @override
  List<String> keys(String prefix) => [for (final k in data.keys) if (k.startsWith(prefix)) k];
}
