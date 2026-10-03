// lib/rendering/sprite_atlas.dart
//
// Turns the bridge's indexed-pixel GRP decode + palette + player-color
// tables into real ui.Image tiles Flutter can draw, caching one image per
// (imageTypeId, frameIndex, flipped, owner) combination actually seen.
//
// Decoding happens in batches keyed by (imageTypeId, owner): the first time
// a unit type is seen, every one of its animation frames (both flip
// states) is decoded up front, not just the single frame currently on
// screen. Animating units cycle through many distinct frame indices as
// they walk/attack/idle — decoding one frame at a time on first sight
// meant every still-undecoded frame popped the sprite out for a tick,
// which read as constant flicker on any moving unit. Batching removes
// that: once a unit type has been seen once, all its frames are already
// cached before they're needed.
//
// This is also the seam where custom/HD texture replacement plugs in
// later: resolve() below is the only place that decides "what picture
// represents this (imageTypeId, frameIndex, flipped, owner)" — swap its
// body for a lookup into a user-supplied texture pack, falling back to the
// original decode, and nothing else in the rendering pipeline needs to
// change.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../engine/bw_engine_io.dart';

class SpriteAtlas {
  final BwEngine _engine;
  final Uint8List _palette; // 256 * 4 RGBA
  final Uint8List _playerColors; // 16 * 8

  final Map<String, ui.Image> _cache = {};
  final Set<String> _batchesStarted = {};

  SpriteAtlas(this._engine)
    : _palette = _engine.getPalette(),
      _playerColors = _engine.getPlayerColors();

  static String _key(int imageTypeId, int frameIndex, bool flipped, int owner) =>
      '$imageTypeId:$frameIndex:${flipped ? 1 : 0}:$owner';

  static String _batchKey(int imageTypeId, int owner) => '$imageTypeId:$owner';

  /// Returns the cached image for this sprite identity if already decoded.
  /// On a miss, kicks off decoding every frame of this (imageTypeId, owner)
  /// pair (not just this one) and returns null for this call — the sprite
  /// is skipped for a tick or two the very first time its unit type is
  /// ever seen, then never again.
  ui.Image? resolve(int imageTypeId, int frameIndex, bool flipped, int owner) {
    final key = _key(imageTypeId, frameIndex, flipped, owner);
    final cached = _cache[key];
    if (cached != null) return cached;

    final batchKey = _batchKey(imageTypeId, owner);
    if (_batchesStarted.add(batchKey)) {
      unawaited(_decodeAllFrames(imageTypeId, owner));
    }
    return null;
  }

  Future<void> _decodeAllFrames(int imageTypeId, int owner) async {
    final frameCount = _engine.getImageFrameCount(imageTypeId);
    final colors = _playerColors.sublist(owner * 8, owner * 8 + 8);

    for (int frameIndex = 0; frameIndex != frameCount; ++frameIndex) {
      for (final flipped in const [false, true]) {
        final image = await _decodeOne(imageTypeId, frameIndex, flipped, owner, colors);
        _cache[_key(imageTypeId, frameIndex, flipped, owner)] = image;
      }
    }
  }

  Future<ui.Image> _decodeOne(
    int imageTypeId,
    int frameIndex,
    bool flipped,
    int owner,
    Uint8List colors,
  ) async {
    final (width, height) = _engine.getImageFrameSize(imageTypeId, frameIndex);
    final indexed = _engine.decodeImageFrame(imageTypeId, frameIndex, flipped);

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
