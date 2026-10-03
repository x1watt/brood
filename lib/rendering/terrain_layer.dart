// lib/rendering/terrain_layer.dart
//
// Builds the map's terrain background once (it doesn't change during a
// game, aside from creep growth which v0 ignores — see bw_bridge.h) as a
// single composited ui.Image, so painting it each frame is one drawImage
// call instead of one per tile.

import 'dart:async';
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

    final widthPx = widthTiles * 32;
    final heightPx = heightTiles * 32;
    final rgba = Uint8List(widthPx * heightPx * 4);

    final decodedCache = <int, Uint8List>{};
    Uint8List decoded(int megatileIndex) =>
        decodedCache.putIfAbsent(megatileIndex, () => engine.decodeMegatile(megatileIndex));

    for (int ty = 0; ty != heightTiles; ++ty) {
      for (int tx = 0; tx != widthTiles; ++tx) {
        final megatileIndex = grid[ty * widthTiles + tx];
        final tile = decoded(megatileIndex);
        final originX = tx * 32;
        final originY = ty * 32;
        for (int y = 0; y != 32; ++y) {
          final dstRowStart = ((originY + y) * widthPx + originX) * 4;
          final srcRowStart = y * 32;
          for (int x = 0; x != 32; ++x) {
            final idx = tile[srcRowStart + x];
            final d = dstRowStart + x * 4;
            rgba[d + 0] = palette[idx * 4 + 0];
            rgba[d + 1] = palette[idx * 4 + 1];
            rgba[d + 2] = palette[idx * 4 + 2];
            rgba[d + 3] = 255;
          }
        }
      }
    }

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, widthPx, heightPx, ui.PixelFormat.rgba8888, completer.complete);
    final image = await completer.future;
    return TerrainLayer._(image, widthPx, heightPx);
  }
}
