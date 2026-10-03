// lib/rendering/creep_layer.dart
//
// Zerg creep over the terrain. The terrain texture is built once per game,
// but creep spreads and recedes, so it is drawn on top every frame from the
// bridge's per-tile codes (bw_bridge_get_creep): creep tiles as the
// tileset's creep megatiles, tiles next to creep with the tileset's creep
// edge frames, exactly as OpenBW's own renderer does. All the pictures sit
// in one small texture and the visible tiles go out in a single drawAtlas
// call.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../engine/bw_engine.dart';

class CreepLayer {
  final BwEngine _engine;
  final Uint8List _palette; // 256 * 4 RGBA
  final int _edgeCount, _edgeWidth, _edgeHeight;
  final int _cell; // atlas cell size: the larger of a tile and an edge frame
  static const int _columns = 16;

  // Atlas cells: edge frames first (cell = frame), then creep megatiles in
  // the order first seen.
  final List<int> _megatiles = [];
  final Map<int, int> _megatileCell = {};
  ui.Image? _atlas;
  bool _building = false;

  /// Codes per tile, refreshed by the controller (see GameController).
  Uint16List? tiles;
  int widthTiles = 0;

  CreepLayer._(this._engine, this._palette, this._edgeCount, this._edgeWidth, this._edgeHeight)
    : _cell = [32, _edgeWidth, _edgeHeight].reduce((a, b) => a > b ? a : b);

  /// Null when the tileset's creep graphics can't be read.
  static CreepLayer? create(BwEngine engine) {
    final info = engine.creepEdgeInfo();
    if (info == null) return null;
    final (count, w, h) = info;
    return CreepLayer._(engine, engine.getPalette(), count, w, h);
  }

  /// New codes from the bridge; a creep megatile not seen before rebuilds
  /// the (small) atlas.
  void update(Uint16List codes, int width) {
    tiles = codes;
    widthTiles = width;
    var added = false;
    for (final code in codes) {
      if (code & 0x8000 == 0) continue;
      final m = code & 0x3fff;
      if (_megatileCell.containsKey(m)) continue;
      _megatileCell[m] = _edgeCount + _megatiles.length;
      _megatiles.add(m);
      added = true;
    }
    if ((added || _atlas == null) && !_building) unawaited(_buildAtlas());
  }

  Future<void> _buildAtlas() async {
    _building = true;
    final cells = _edgeCount + _megatiles.length;
    final rows = (cells + _columns - 1) ~/ _columns;
    final w = _columns * _cell, h = (rows == 0 ? 1 : rows) * _cell;
    final rgba = Uint8List(w * h * 4);
    void put(int cell, Uint8List indices, int pw, int ph) {
      final ox = (cell % _columns) * _cell, oy = (cell ~/ _columns) * _cell;
      for (int y = 0; y < ph; ++y) {
        for (int x = 0; x < pw; ++x) {
          final idx = indices[y * pw + x];
          if (idx == 0) continue;
          final o = ((oy + y) * w + ox + x) * 4;
          rgba[o] = _palette[idx * 4];
          rgba[o + 1] = _palette[idx * 4 + 1];
          rgba[o + 2] = _palette[idx * 4 + 2];
          rgba[o + 3] = 255;
        }
      }
    }

    for (int f = 0; f < _edgeCount; ++f) {
      final px = _engine.decodeCreepEdge(f, _edgeWidth, _edgeHeight);
      if (px != null) put(f, px, _edgeWidth, _edgeHeight);
    }
    final megatiles = List<int>.of(_megatiles);
    for (int i = 0; i < megatiles.length; ++i) {
      final px = _engine.decodeMegatile(megatiles[i]);
      // Creep megatiles are opaque: index 0 is a real color here.
      final ox = ((_edgeCount + i) % _columns) * _cell, oy = ((_edgeCount + i) ~/ _columns) * _cell;
      for (int y = 0; y < 32; ++y) {
        for (int x = 0; x < 32; ++x) {
          final idx = px[y * 32 + x];
          final o = ((oy + y) * w + ox + x) * 4;
          rgba[o] = _palette[idx * 4];
          rgba[o + 1] = _palette[idx * 4 + 1];
          rgba[o + 2] = _palette[idx * 4 + 2];
          rgba[o + 3] = 255;
        }
      }
    }
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
    final image = await c.future;
    _atlas?.dispose();
    _atlas = image;
    _building = false;
    // Megatiles seen while this was building.
    if (megatiles.length != _megatiles.length) unawaited(_buildAtlas());
  }

  Float32List _transforms = Float32List(0);
  Float32List _rects = Float32List(0);

  /// Draws the creep on the tiles in view ([camX], [camY] top-left of the
  /// view in map pixels).
  void paint(ui.Canvas canvas, double camX, double camY, ui.Size view, ui.Paint paint) {
    final atlas = _atlas, codes = tiles;
    if (atlas == null || codes == null || widthTiles == 0) return;
    final heightTiles = codes.length ~/ widthTiles;
    final x0 = (camX ~/ 32).clamp(0, widthTiles), y0 = (camY ~/ 32).clamp(0, heightTiles);
    final x1 = ((camX + view.width) ~/ 32 + 1).clamp(0, widthTiles), y1 = ((camY + view.height) ~/ 32 + 1).clamp(0, heightTiles);
    final most = (x1 - x0) * (y1 - y0);
    if (_transforms.length < most * 4) {
      _transforms = Float32List(most * 4);
      _rects = Float32List(most * 4);
    }
    int n = 0;
    for (int ty = y0; ty < y1; ++ty) {
      for (int tx = x0; tx < x1; ++tx) {
        final code = codes[ty * widthTiles + tx];
        if (code == 0) continue;
        final int cell;
        final int w, h;
        if (code & 0x8000 != 0) {
          final c = _megatileCell[code & 0x3fff];
          if (c == null || c >= _cellsBuilt(atlas)) continue;
          cell = c;
          w = 32;
          h = 32;
        } else {
          cell = code & 0x3fff;
          if (cell >= _edgeCount) continue;
          w = _edgeWidth;
          h = _edgeHeight;
        }
        final sx = (cell % _columns) * _cell.toDouble(), sy = (cell ~/ _columns) * _cell.toDouble();
        _transforms
          ..[n * 4] = 1
          ..[n * 4 + 1] = 0
          ..[n * 4 + 2] = tx * 32 - camX
          ..[n * 4 + 3] = ty * 32 - camY;
        _rects
          ..[n * 4] = sx
          ..[n * 4 + 1] = sy
          ..[n * 4 + 2] = sx + w
          ..[n * 4 + 3] = sy + h;
        ++n;
      }
    }
    if (n == 0) return;
    canvas.drawRawAtlas(atlas, Float32List.sublistView(_transforms, 0, n * 4), Float32List.sublistView(_rects, 0, n * 4), null, null, null, paint);
  }

  int _cellsBuilt(ui.Image atlas) => (atlas.height ~/ _cell) * _columns;

  void dispose() {
    _atlas?.dispose();
    _atlas = null;
  }
}
