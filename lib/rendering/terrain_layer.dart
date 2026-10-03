// lib/rendering/terrain_layer.dart
//
// The map's terrain, built once per game. It is kept as palette indices
// (shaders/terrain.frag colors it through a palette that rotates over time,
// which is how the original animates water, lava and glowing tiles) plus a
// small full-color thumbnail for the minimap. If the shader can't be
// loaded, a static full-color image is used instead.
//
// FFI calls stay on the main isolate (the engine handle lives there); the
// per-pixel composition of the full map runs in a background isolate.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;

import 'dart:ui' as ui;

import '../engine/bw_engine.dart';

/// Palette ranges the original rotates (indices 1-6 and 7-13: on every
/// tileset these hold the water/lava animation colors).
const List<(int, int)> paletteCycleRanges = [(1, 6), (7, 13)];

/// Game frames per rotation step. The original's exact table isn't
/// documented; this matches its slow shimmer closely enough.
const int paletteCycleFrames = 8;

class TerrainLayer {
  final int widthPx;
  final int heightPx;
  final ui.Image indices; // red channel = palette index (shader path)
  final ui.Image? colors; // static full-color terrain (fallback path)
  final ui.Image minimap;
  final ui.FragmentProgram? program;
  final List<ui.Image> palettes; // one per rotation step

  TerrainLayer._(this.widthPx, this.heightPx, this.indices, this.colors, this.minimap, this.program, this.palettes);

  ui.Image paletteForFrame(int frame) => palettes[(frame ~/ paletteCycleFrames) % palettes.length];

  static Future<TerrainLayer> build(BwEngine engine) async {
    final (widthTiles, heightTiles) = engine.getMapTileSize();
    final grid = engine.getTileGrid(widthTiles, heightTiles);
    final palette = engine.getPalette();
    final megatiles = <int, Uint8List>{};
    for (final index in grid) {
      megatiles.putIfAbsent(index, () => engine.decodeMegatile(index));
    }

    ui.FragmentProgram? program;
    try {
      program = await ui.FragmentProgram.fromAsset('shaders/terrain.frag');
    } catch (_) {
      program = null;
    }

    final composed = await _composeInBackground(widthTiles, heightTiles, grid, palette, megatiles, program == null);
    final widthPx = widthTiles * 32;
    final heightPx = heightTiles * 32;

    final indices = await _image(composed.indices, widthPx, heightPx);
    final colors = composed.colors == null ? null : await _image(composed.colors!, widthPx, heightPx);
    final minimap = await _image(composed.minimap, composed.minimapWidth, composed.minimapHeight);

    // Every distinct rotation of the cycling ranges, precomputed (6 x 7 = 42).
    final steps = paletteCycleRanges.fold<int>(1, (acc, r) => _lcm(acc, r.$2 - r.$1 + 1));
    final palettes = <ui.Image>[];
    for (int step = 0; step < steps; ++step) {
      palettes.add(await _image(_rotated(palette, step), 256, 1));
    }
    return TerrainLayer._(widthPx, heightPx, indices, colors, minimap, program, palettes);
  }

  static int _lcm(int a, int b) {
    int gcd(int x, int y) => y == 0 ? x : gcd(y, x % y);
    return a ~/ gcd(a, b) * b;
  }

  /// RGBA palette with each cycling range rotated [step] places (each color
  /// moves up one index per step).
  static Uint8List _rotated(Uint8List palette, int step) {
    final out = Uint8List.fromList(palette);
    for (final (lo, hi) in paletteCycleRanges) {
      final len = hi - lo + 1;
      for (int i = lo; i <= hi; ++i) {
        final src = lo + ((i - lo - step) % len + len) % len;
        for (int c = 0; c < 3; ++c) {
          out[i * 4 + c] = palette[src * 4 + c];
        }
        out[i * 4 + 3] = 255;
      }
    }
    for (int i = 0; i < 256; ++i) {
      out[i * 4 + 3] = 255;
    }
    return out;
  }

  static Future<ui.Image> _image(Uint8List rgba, int w, int h) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  // Separate static function so the isolate closure captures only these
  // plain-data parameters, not the engine (a native handle can't be sent).
  static Future<_Composed> _composeInBackground(
    int widthTiles,
    int heightTiles,
    Uint16List grid,
    Uint8List palette,
    Map<int, Uint8List> megatiles,
    bool withColors,
  ) => compute((_) => _compose(widthTiles, heightTiles, grid, palette, megatiles, withColors), null); // a background isolate where there is one

  static _Composed _compose(int widthTiles, int heightTiles, Uint16List grid, Uint8List palette, Map<int, Uint8List> megatiles, bool withColors) {
    final widthPx = widthTiles * 32;
    final heightPx = heightTiles * 32;
    final paletteWords = Uint32List(256);
    for (int i = 0; i < 256; ++i) {
      paletteWords[i] = palette[i * 4] | (palette[i * 4 + 1] << 8) | (palette[i * 4 + 2] << 16) | (0xff << 24);
    }

    final indices = Uint8List(widthPx * heightPx * 4);
    final indexWords = indices.buffer.asUint32List();
    final colors = withColors ? Uint8List(widthPx * heightPx * 4) : null;
    final colorWords = colors?.buffer.asUint32List();
    for (int ty = 0; ty < heightTiles; ++ty) {
      for (int tx = 0; tx < widthTiles; ++tx) {
        final tile = megatiles[grid[ty * widthTiles + tx]]!;
        for (int y = 0; y < 32; ++y) {
          final dst = (ty * 32 + y) * widthPx + tx * 32;
          final src = y * 32;
          for (int x = 0; x < 32; ++x) {
            final idx = tile[src + x];
            indexWords[dst + x] = idx | (0xff << 24);
            if (colorWords != null) colorWords[dst + x] = paletteWords[idx];
          }
        }
      }
    }

    // Minimap thumbnail: one sample per 16x16 map pixels.
    final mw = (widthPx / 16).ceil(), mh = (heightPx / 16).ceil();
    final minimap = Uint8List(mw * mh * 4);
    final miniWords = minimap.buffer.asUint32List();
    for (int y = 0; y < mh; ++y) {
      for (int x = 0; x < mw; ++x) {
        final idx = indexWords[(y * 16 + 8).clamp(0, heightPx - 1) * widthPx + (x * 16 + 8).clamp(0, widthPx - 1)] & 0xff;
        miniWords[y * mw + x] = paletteWords[idx];
      }
    }
    return _Composed(indices, colors, minimap, mw, mh);
  }
}

class _Composed {
  final Uint8List indices;
  final Uint8List? colors;
  final Uint8List minimap;
  final int minimapWidth;
  final int minimapHeight;
  _Composed(this.indices, this.colors, this.minimap, this.minimapWidth, this.minimapHeight);
}
