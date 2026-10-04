// The blend worker in the browser: on the page itself (no isolates there),
// yielding between maps while it learns.

import 'dart:typed_data';

import 'blend_worker.dart';
import 'terrain_blend.dart';

BlendWorker createBlendWorker(Uint8List? Function(String) readChk) => _InlineWorker(readChk);

class _InlineWorker implements BlendWorker {
  final Uint8List? Function(String) _read;
  BlendModel _model = BlendModel();
  _InlineWorker(this._read);

  @override
  Future<int> learn(int tileset, List<String> mapFiles, String exclude, Uint16List current, int w, int h) {
    _model = BlendModel();
    return learnFrom(_model, tileset, mapFiles, exclude, current, w, h, _read, yieldNow: () => Future<void>.delayed(Duration.zero));
  }

  @override
  Future<BlendResult> blend(Int32List grid, int pw, int h, Map<int, Set<int>> forced, Set<int> keep) async =>
      _model.blend(grid, pw, h, forced, keep: keep);

  @override
  void dispose() {}
}
