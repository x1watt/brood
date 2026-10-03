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
// sprites blink out for a tick on each new frame. The first frame needed is
// decoded on its own right away and stands in for the others until the
// batch is ready.
//
// A batch is packed into a few large textures rather than one per frame:
// phone GPUs (a Mali-G57 measured here) stall drawing while any texture
// upload is in flight, and thousands of small uploads at a game's start
// kept frames at 3 per second for minutes.
//
// resolve*() are the only places deciding which picture represents an
// image, so swapping in custom/HD textures later only touches this file.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Canvas, Offset, Paint, Rect;

import '../engine/bw_engine.dart';

enum _Variant { color, mask, glow }

/// One frame: a region of a (shared) texture.
class SpriteFrame {
  final ui.Image image;
  final Rect src;
  const SpriteFrame(this.image, this.src);

  int get width => src.width.toInt();
  int get height => src.height.toInt();

  void draw(Canvas canvas, Offset at, Paint paint) => canvas.drawImageRect(image, src, Rect.fromLTWH(at.dx, at.dy, src.width, src.height), paint);
}

class SpriteAtlas {
  final BwEngine _engine;
  final Uint8List _palette; // 256 * 4 RGBA
  final Uint8List _playerColors; // 16 * 8
  final Map<int, (Uint8List, int)> _lightTables = {};

  final Map<int, SpriteFrame> _cache = {};
  final Map<int, SpriteFrame> _anyFrame = {};
  final Set<int> _batches = {};

  SpriteAtlas(this._engine) : _palette = _engine.getPalette(), _playerColors = _engine.getPlayerColors();

  // Packs (variant, key, imageType, frame, flipped) into one int key.
  // imageType < 1024, frame < 4096, key < 64.
  static int _batchKey(_Variant v, int key, int imageTypeId) => (v.index << 16) | ((key & 0x3f) << 10) | (imageTypeId & 0x3ff);

  static int _frameKey(int batchKey, int frameIndex, bool flipped) => (batchKey << 13) | ((frameIndex & 0xfff) << 1) | (flipped ? 1 : 0);

  SpriteFrame? resolveColor(int imageTypeId, int frameIndex, bool flipped, int colorIndex) =>
      _resolve(_Variant.color, colorIndex, imageTypeId, frameIndex, flipped);

  SpriteFrame? resolveMask(int imageTypeId, int frameIndex, bool flipped) => _resolve(_Variant.mask, 0, imageTypeId, frameIndex, flipped);

  SpriteFrame? resolveGlow(int imageTypeId, int frameIndex, bool flipped, int lightIndex) =>
      _resolve(_Variant.glow, lightIndex, imageTypeId, frameIndex, flipped);

  SpriteFrame? _resolve(_Variant v, int key, int imageTypeId, int frameIndex, bool flipped) {
    final bk = _batchKey(v, key, imageTypeId);
    final hit = _cache[_frameKey(bk, frameIndex, flipped)];
    if (hit != null) return hit;
    if (_batches.add(bk)) {
      unawaited(_decodeBatch(v, key, imageTypeId, bk, frameIndex, flipped));
    }
    return _anyFrame[bk];
  }

  // Texture pages: frames packed in rows, one pixel apart.
  static const int _pageWidth = 2048;
  static const int _pageMaxHeight = 2048;

  Future<void> _decodeBatch(_Variant v, int key, int imageTypeId, int bk, int firstFrame, bool firstFlipped) async {
    final frameCount = _engine.getImageFrameCount(imageTypeId);
    if (firstFrame < frameCount) {
      final first = await _decodeOne(v, key, imageTypeId, firstFrame, firstFlipped);
      if (first != null) {
        final f = SpriteFrame(first, Rect.fromLTWH(0, 0, first.width.toDouble(), first.height.toDouble()));
        _cache[_frameKey(bk, firstFrame, firstFlipped)] = f;
        _anyFrame[bk] = f;
      }
    }

    // Lay every frame out on pages, then fill and upload one page at a time.
    final placed = <(int frame, bool flipped, int page, int x, int y, int w, int h)>[];
    final pageHeights = <int>[];
    int x = 0, y = 0, row = 0;
    for (int frame = 0; frame < frameCount; ++frame) {
      final (w, h) = _engine.getImageFrameSize(imageTypeId, frame);
      if (w == 0 || h == 0) continue;
      for (final flipped in const [false, true]) {
        if (x + w > _pageWidth) {
          x = 0;
          y += row + 1;
          row = 0;
        }
        if (y + h > _pageMaxHeight) {
          pageHeights.add(y);
          x = 0;
          y = 0;
          row = 0;
        }
        placed.add((frame, flipped, pageHeights.length, x, y, w, h));
        x += w + 1;
        if (h > row) row = h;
      }
    }
    if (placed.isEmpty) return;
    pageHeights.add(y + row);

    for (int page = 0; page < pageHeights.length; ++page) {
      final ph = pageHeights[page];
      final rgba = Uint8List(_pageWidth * ph * 4);
      final onPage = placed.where((p) => p.$3 == page).toList();
      for (int i = 0; i < onPage.length; ++i) {
        final (frame, flipped, _, px, py, w, h) = onPage[i];
        _fill(v, key, _engine.decodeImageFrame(imageTypeId, frame, flipped), rgba, px, py, w, _pageWidth);
        // Let a frame render now and then while a big batch fills.
        if (i % 64 == 63) await Future<void>.delayed(Duration.zero);
      }
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(rgba, _pageWidth, ph, ui.PixelFormat.rgba8888, completer.complete);
      final image = await completer.future;
      for (final (frame, flipped, _, px, py, w, h) in onPage) {
        final f = SpriteFrame(image, Rect.fromLTWH(px.toDouble(), py.toDouble(), w.toDouble(), h.toDouble()));
        _cache[_frameKey(bk, frame, flipped)] = f;
        if (frame == firstFrame && flipped == firstFlipped) _anyFrame[bk] = f;
        _anyFrame.putIfAbsent(bk, () => f);
      }
    }
  }

  // One frame's indexed pixels into [rgba] (rows [stride] pixels long) at
  // (px, py).
  void _fill(_Variant v, int key, Uint8List indexed, Uint8List rgba, int px, int py, int w, int stride) {
    void put(int i, int idx) {
      final o = ((py + i ~/ w) * stride + px + i % w) * 4;
      rgba[o] = _palette[idx * 4];
      rgba[o + 1] = _palette[idx * 4 + 1];
      rgba[o + 2] = _palette[idx * 4 + 2];
      rgba[o + 3] = 255;
    }

    switch (v) {
      case _Variant.color:
        final row = (key & 15) * 8;
        for (int i = 0; i < indexed.length; ++i) {
          int idx = indexed[i];
          if (idx == 0) continue;
          if (idx >= 8 && idx < 16) idx = _playerColors[row + idx - 8];
          put(i, idx);
        }
      case _Variant.mask:
        for (int i = 0; i < indexed.length; ++i) {
          if (indexed[i] == 0) continue;
          final o = ((py + i ~/ w) * stride + px + i % w) * 4;
          rgba[o] = 255;
          rgba[o + 1] = 255;
          rgba[o + 2] = 255;
          rgba[o + 3] = 255;
        }
      case _Variant.glow:
        final (table, rows) = _lightTables.putIfAbsent(key, () => _engine.getLightTable(key));
        for (int i = 0; i < indexed.length; ++i) {
          final value = indexed[i];
          if (value == 0 || value - 1 >= rows) continue;
          final idx = table[(value - 1) * 256];
          if (idx == 0) continue;
          put(i, idx);
        }
    }
  }

  Future<ui.Image?> _decodeOne(_Variant v, int key, int imageTypeId, int frameIndex, bool flipped) async {
    final (width, height) = _engine.getImageFrameSize(imageTypeId, frameIndex);
    if (width == 0 || height == 0) return null;
    final rgba = Uint8List(width * height * 4);
    _fill(v, key, _engine.decodeImageFrame(imageTypeId, frameIndex, flipped), rgba, 0, 0, width, width);
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }
}
