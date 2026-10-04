// lib/maps/blend_worker.dart
//
// Runs terrain blending (terrain_blend.dart) away from the UI: learning
// reads every map of the player's that shares the tileset, and a blend can
// take a moment when the layers need room. On desktop and Android that is a
// long-lived isolate with its own engine handle (reading map archives needs
// no game data); the browser has no isolates there, so it runs on the page,
// yielding between maps.

import 'dart:typed_data';

import 'chk.dart';
import 'blend_worker_io.dart' if (dart.library.js_interop) 'blend_worker_web.dart' as platform;
import 'terrain_blend.dart';

abstract class BlendWorker {
  /// [readChk] reads a map's scenario data on this isolate (the browser's
  /// worker uses it; the isolate opens its own engine).
  static BlendWorker create(Uint8List? Function(String mapFile) readChk) => platform.createBlendWorker(readChk);

  /// Learns from [mapFiles] with this [tileset] (others are skipped), and
  /// from the map being edited ([current], [w] x [h]) whose own file
  /// [exclude] is skipped. Returns how many maps it learned from.
  Future<int> learn(int tileset, List<String> mapFiles, String exclude, Uint16List current, int w, int h);

  Future<BlendResult> blend(Int32List grid, int pw, int h, Map<int, Set<int>> forced, Set<int> keep);

  void dispose();
}

/// The learning both workers do: [read] gives a map's scenario data.
Future<int> learnFrom(BlendModel model, int tileset, List<String> mapFiles, String exclude, Uint16List current, int w, int h,
    Uint8List? Function(String) read, {Future<void> Function()? yieldNow}) async {
  for (final f in mapFiles) {
    if (f == exclude) continue;
    final bytes = read(f);
    if (bytes != null) {
      try {
        final chk = chkTerrain(bytes);
        if (chk != null && chk.$1 == tileset) model.add(chk.$4, chk.$2, chk.$3);
      } catch (_) {
        // A map the editor can't read teaches nothing.
      }
    }
    if (yieldNow != null) await yieldNow();
  }
  model.add(current, w, h, weight: 100);
  return model.maps - 1;
}

/// (tileset, width, height, tiles) of a map's scenario data, or null.
(int, int, int, Uint16List)? chkTerrain(Uint8List bytes) {
  final chk = ChkFile.parse(bytes);
  if (chk.section('DIM ') == null || chk.section('MTXM') == null) return null;
  final (w, h) = chk.size;
  return (chk.tileset, w, h, chk.tiles());
}
