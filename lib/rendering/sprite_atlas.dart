// lib/rendering/sprite_atlas.dart
//
// Turns the bridge's indexed-pixel GRP decode + palette + player-color
// tables into real ui.Image tiles Flutter can draw, caching one image per
// (imageTypeId, frameIndex, flipped, owner) combination actually seen.
//
// This is the seam where custom/HD texture replacement plugs in later:
// resolve() below is the only place that decides "what picture represents
// this (imageTypeId, frameIndex, flipped, owner)" — swap its body for a
// lookup into a user-supplied texture pack, falling back to the original
// decode, and nothing else in the rendering pipeline needs to change.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../engine/bw_engine_io.dart';

class SpriteAtlas {
  final BwEngine _engine;
  final Uint8List _palette; // 256 * 4 RGBA
  final Uint8List _playerColors; // 16 * 8

  final Map<String, ui.Image> _cache = {};
  final Map<String, Future<ui.Image>> _pending = {};

  SpriteAtlas(this._engine)
    : _palette = _engine.getPalette(),
      _playerColors = _engine.getPlayerColors();

  static String _key(int imageTypeId, int frameIndex, bool flipped, int owner) =>
      '$imageTypeId:$frameIndex:${flipped ? 1 : 0}:$owner';

  /// Returns the cached image for this sprite identity if already decoded,
  /// kicking off a decode for next time if not. Returns null on a cache
  /// miss so the first frame or two of a never-before-seen sprite can be
  /// skipped rather than block the paint call on an async decode.
  ui.Image? resolve(int imageTypeId, int frameIndex, bool flipped, int owner) {
    final key = _key(imageTypeId, frameIndex, flipped, owner);
    final cached = _cache[key];
    if (cached != null) return cached;
    if (!_pending.containsKey(key)) {
      _pending[key] = _decode(imageTypeId, frameIndex, flipped, owner).then((image) {
        _cache[key] = image;
        _pending.remove(key);
        return image;
      });
    }
    return null;
  }

  Future<ui.Image> _decode(int imageTypeId, int frameIndex, bool flipped, int owner) async {
    final (width, height) = _engine.getImageFrameSize(imageTypeId, frameIndex);
    final indexed = _engine.decodeImageFrame(imageTypeId, frameIndex, flipped);

    final colors = _playerColors.sublist(owner * 8, owner * 8 + 8);
    final rgba = Uint8List(width * height * 4);
    for (int i = 0; i != width * height; ++i) {
      int idx = indexed[i];
      // index 0 is BW's transparent index — leave fully transparent.
      if (idx == 0) continue;
      if (idx >= 8 && idx < 16) idx = colors[idx - 8];
      rgba[i * 4 + 0] = _palette[idx * 4 + 0];
      rgba[i * 4 + 1] = _palette[idx * 4 + 1];
      rgba[i * 4 + 2] = _palette[idx * 4 + 2];
      rgba[i * 4 + 3] = 255;
    }

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}
