// lib/rendering/terrain_layer.dart
//
// The map's terrain as one ui.Image, built once per game (terrain doesn't
// change mid-game; creep is not drawn yet). FFI calls stay on the main
// isolate (the engine handle lives there); the per-pixel composition of the
// full map, millions of pixels, runs in a background isolate.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../engine/bw_engine_io.dart';

class TerrainLayer {
  final ui.Image image;
  final int widthPx;
  final int heightPx;

  TerrainLayer._(this.image, this.widthPx, this.heightPx);

  static Future<TerrainLayer> build(BwEngine engine) async {
    final (widthTiles, heightTiles) = engine.getMapTileSize();
    final grid = engine.getTileGrid(widthTiles, heightTiles);
    final palette = engine.getPalette();
    final megatiles = <int, Uint8List>{};
    for (final index in grid) {
      megatiles.putIfAbsent(index, () => engine.decodeMegatile(index));
    }

    final rgba = await _composeInBackground(widthTiles, heightTiles, grid, palette, megatiles);

    final widthPx = widthTiles * 32;
    final heightPx = heightTiles * 32;
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, widthPx, heightPx, ui.PixelFormat.rgba8888, completer.complete);
    return TerrainLayer._(await completer.future, widthPx, heightPx);
  }

  // Separate static function so the isolate closure captures only these
  // plain-data parameters, not the engine (a native handle can't be sent).
  static Future<Uint8List> _composeInBackground(
    int widthTiles,
    int heightTiles,
    Uint16List grid,
    Uint8List palette,
    Map<int, Uint8List> megatiles,
  ) => Isolate.run(() => _compose(widthTiles, heightTiles, grid, palette, megatiles));

  static Uint8List _compose(int widthTiles, int heightTiles, Uint16List grid, Uint8List palette, Map<int, Uint8List> megatiles) {
    final widthPx = widthTiles * 32;
    final rgba = Uint8List(widthPx * heightTiles * 32 * 4);
    final rgbaWords = rgba.buffer.asUint32List();
    // Little-endian RGBA bytes as one 32-bit word per palette entry.
    final paletteWords = Uint32List(256);
    for (int i = 0; i < 256; ++i) {
      paletteWords[i] = palette[i * 4] | (palette[i * 4 + 1] << 8) | (palette[i * 4 + 2] << 16) | (0xff << 24);
    }
    for (int ty = 0; ty < heightTiles; ++ty) {
      for (int tx = 0; tx < widthTiles; ++tx) {
        final tile = megatiles[grid[ty * widthTiles + tx]]!;
        for (int y = 0; y < 32; ++y) {
          final dst = (ty * 32 + y) * widthPx + tx * 32;
          final src = y * 32;
          for (int x = 0; x < 32; ++x) {
            rgbaWords[dst + x] = paletteWords[tile[src + x]];
          }
        }
      }
    }
    return rgba;
  }
}
