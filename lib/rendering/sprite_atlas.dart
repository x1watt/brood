// lib/rendering/sprite_atlas.dart
//
// Turns the bridge's indexed GRP frames into ui.Images. Three variants,
// matching how OpenBW's own renderer (ui/ui.h draw_image) treats image
// modifiers:
//   - color: palette lookup with the owner's player-color remap (indices 8-15)
//   - mask:  white wherever the frame has a pixel; the painter tints it
//            (black at half opacity for shadows, relation color for
//            selection circles)
//   - glow:  pixel values are light intensities into one of the tileset's
//            light tables, drawn additively
//
// Every variant is decoded per (image type, variant key) for all frames and
// both flip states at once, the first time it's needed. Animating units
// cycle through many frames; decoding frame by frame on first sight made
// sprites blink out for a tick on each new frame. While a batch is still
// decoding, the closest already-decoded frame of the same image stands in
// rather than drawing nothing.
//
// resolve*() are the only places deciding which picture represents an
// image, so swapping in custom/HD textures later only touches this file.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../engine/bw_engine_io.dart';

enum _Variant { color, mask, glow }

class SpriteAtlas {
  final BwEngine _engine;
  final Uint8List _palette; // 256 * 4 RGBA
  final Uint8List _playerColors; // 16 * 8
  final Map<int, (Uint8List, int)> _lightTables = {};

  final Map<int, ui.Image> _cache = {};
  final Map<int, ui.Image> _anyFrame = {};
  final Set<int> _batches = {};

  SpriteAtlas(this._engine)
    : _palette = _engine.getPalette(),
      _playerColors = _engine.getPlayerColors();

  // Packs (variant, key, imageType, frame, flipped) into one int key.
  // imageType < 1024, frame < 4096, key < 64.
  static int _batchKey(_Variant v, int key, int imageTypeId) =>
      (v.index << 16) | ((key & 0x3f) << 10) | (imageTypeId & 0x3ff);

  static int _frameKey(int batchKey, int frameIndex, bool flipped) =>
      (batchKey << 13) | ((frameIndex & 0xfff) << 1) | (flipped ? 1 : 0);

  ui.Image? resolveColor(int imageTypeId, int frameIndex, bool flipped, int colorIndex) =>
      _resolve(_Variant.color, colorIndex, imageTypeId, frameIndex, flipped);

  ui.Image? resolveMask(int imageTypeId, int frameIndex, bool flipped) =>
      _resolve(_Variant.mask, 0, imageTypeId, frameIndex, flipped);

  ui.Image? resolveGlow(int imageTypeId, int frameIndex, bool flipped, int lightIndex) =>
      _resolve(_Variant.glow, lightIndex, imageTypeId, frameIndex, flipped);

  ui.Image? _resolve(_Variant v, int key, int imageTypeId, int frameIndex, bool flipped) {
    final bk = _batchKey(v, key, imageTypeId);
    final hit = _cache[_frameKey(bk, frameIndex, flipped)];
    if (hit != null) return hit;
    if (_batches.add(bk)) {
      unawaited(_decodeBatch(v, key, imageTypeId, bk, frameIndex, flipped));
    }
    return _anyFrame[bk];
  }

  Future<void> _decodeBatch(_Variant v, int key, int imageTypeId, int bk, int firstFrame, bool firstFlipped) async {
    final frameCount = _engine.getImageFrameCount(imageTypeId);
    Future<void> one(int frame, bool flipped) async {
      final fk = _frameKey(bk, frame, flipped);
      if (_cache.containsKey(fk)) return;
      final image = await _decodeOne(v, key, imageTypeId, frame, flipped);
      if (image == null) return;
      _cache[fk] = image;
      if (frame == firstFrame || !_anyFrame.containsKey(bk)) _anyFrame[bk] = image;
    }

    if (firstFrame < frameCount) await one(firstFrame, firstFlipped);
    for (int frame = 0; frame < frameCount; ++frame) {
      await one(frame, false);
      await one(frame, true);
    }
  }

  Future<ui.Image?> _decodeOne(_Variant v, int key, int imageTypeId, int frameIndex, bool flipped) async {
    final (width, height) = _engine.getImageFrameSize(imageTypeId, frameIndex);
    if (width == 0 || height == 0) return null;
    final indexed = _engine.decodeImageFrame(imageTypeId, frameIndex, flipped);
    final rgba = Uint8List(width * height * 4);

    switch (v) {
      case _Variant.color:
        final row = (key & 15) * 8;
        for (int i = 0; i < indexed.length; ++i) {
          int idx = indexed[i];
          if (idx == 0) continue;
          if (idx >= 8 && idx < 16) idx = _playerColors[row + idx - 8];
          final o = i * 4;
          rgba[o] = _palette[idx * 4];
          rgba[o + 1] = _palette[idx * 4 + 1];
          rgba[o + 2] = _palette[idx * 4 + 2];
          rgba[o + 3] = 255;
        }
      case _Variant.mask:
        for (int i = 0; i < indexed.length; ++i) {
          if (indexed[i] == 0) continue;
          final o = i * 4;
          rgba[o] = 255;
          rgba[o + 1] = 255;
          rgba[o + 2] = 255;
          rgba[o + 3] = 255;
        }
      case _Variant.glow:
        // Over black (palette 0), a glow pixel of intensity v becomes
        // table[(v - 1) * 256 + 0]; drawing that additively approximates
        // BW's blend tables, which add light onto what's underneath.
        final (table, rows) = _lightTables.putIfAbsent(key, () => _engine.getLightTable(key));
        for (int i = 0; i < indexed.length; ++i) {
          final value = indexed[i];
          if (value == 0 || value - 1 >= rows) continue;
          final idx = table[(value - 1) * 256];
          if (idx == 0) continue;
          final o = i * 4;
          rgba[o] = _palette[idx * 4];
          rgba[o + 1] = _palette[idx * 4 + 1];
          rgba[o + 2] = _palette[idx * 4 + 2];
          rgba[o + 3] = 255;
        }
    }

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }
}
