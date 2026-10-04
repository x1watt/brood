// lib/rendering/megatile_atlas.dart
//
// The map editor's terrain: megatiles decoded from the tileset (no game is
// running) into pages of 32x32 slots, each page one image, so the visible
// map is one drawAtlas call per page and painted tiles only add what is
// new. Also keeps each megatile's average color for the minimap. Decoding
// many megatiles at once runs in a background isolate.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;

import '../maps/tileset.dart';

class MegatileAtlas {
  static const int _side = 32; // slots per page row
  static const int _perPage = _side * _side;
  static const int _pagePx = _side * 32;

  final Tileset tileset;
  final Map<int, int> _slot = {}; // megatile -> slot
  final List<Uint8List> _pixels = []; // RGBA per page
  final List<ui.Image?> pages = [];
  final Map<int, int> averageColor = {}; // megatile -> 0xAARRGGBB
  final Uint32List _palette;

  MegatileAtlas(this.tileset) : _palette = _paletteWords(tileset.palette);

  static Uint32List _paletteWords(Uint8List p) {
    final out = Uint32List(256);
    for (int i = 0; i < 256; ++i) {
      out[i] = p[i * 4] | (p[i * 4 + 1] << 8) | (p[i * 4 + 2] << 16) | (0xff << 24); // RGBA bytes in memory
    }
    return out;
  }

  bool has(int megatile) => _slot.containsKey(megatile);

  /// Page and source rectangle of a megatile already in the atlas.
  (int, ui.Rect) source(int megatile) {
    final s = _slot[megatile] ?? 0;
    final page = s ~/ _perPage, i = s % _perPage;
    return (page, ui.Rect.fromLTWH((i % _side) * 32.0, (i ~/ _side) * 32.0, 32, 32));
  }

  /// Decodes the megatiles not in the atlas yet and refreshes the pages
  /// they went into.
  Future<void> ensure(Iterable<int> megatiles) async {
    final missing = megatiles.where((m) => !_slot.containsKey(m)).toSet().toList();
    if (missing.isEmpty) return;
    final decoded = missing.length > 64
        ? await compute(_decode, (tileset, missing, _palette))
        : _decode((tileset, missing, _palette));
    final touched = <int>{};
    for (int k = 0; k < missing.length; ++k) {
      final s = _slot.length;
      _slot[missing[k]] = s;
      final page = s ~/ _perPage, i = s % _perPage;
      while (_pixels.length <= page) {
        _pixels.add(Uint8List(_pagePx * _pagePx * 4));
        pages.add(null);
      }
      final dst = _pixels[page].buffer.asUint32List();
      final src = decoded.$1.buffer.asUint32List(k * 4096, 1024);
      final ox = (i % _side) * 32, oy = (i ~/ _side) * 32;
      for (int y = 0; y < 32; ++y) {
        dst.setRange((oy + y) * _pagePx + ox, (oy + y) * _pagePx + ox + 32, src, y * 32);
      }
      averageColor[missing[k]] = decoded.$2[k];
      touched.add(page);
    }
    for (final page in touched) {
      final c = Completer<ui.Image>();
      ui.decodeImageFromPixels(_pixels[page], _pagePx, _pagePx, ui.PixelFormat.rgba8888, c.complete);
      final old = pages[page];
      pages[page] = await c.future;
      old?.dispose();
    }
  }

  /// RGBA pixels (4096 bytes each) and average colors of [megatiles].
  static (Uint8List, List<int>) _decode((Tileset, List<int>, Uint32List) a) {
    final (ts, list, palette) = a;
    final out = Uint8List(list.length * 4096);
    final words = out.buffer.asUint32List();
    final idx = Uint8List(1024);
    final avg = <int>[];
    for (int k = 0; k < list.length; ++k) {
      ts.decodeMegatile(list[k], idx);
      int r = 0, g = 0, b = 0;
      for (int p = 0; p < 1024; ++p) {
        final c = palette[idx[p]];
        words[k * 1024 + p] = c;
        r += c & 0xff;
        g += (c >> 8) & 0xff;
        b += (c >> 16) & 0xff;
      }
      avg.add(0xff000000 | ((r >> 10) << 16) | ((g >> 10) << 8) | (b >> 10));
    }
    return (out, avg);
  }

  void dispose() {
    for (final p in pages) {
      p?.dispose();
    }
  }
}
