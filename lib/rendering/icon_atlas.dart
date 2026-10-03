// lib/rendering/icon_atlas.dart
//
// The original game's UI icons, decoded from the user's MPQs:
//   - unit\cmdbtns\cmdicons.grp: command card icons. Frame N is unit type N
//     for units/buildings (0-227); tech and upgrade icons come from the
//     engine (tech_type_t/upgrade_type_t icon); basic commands are fixed
//     frames (CmdIcon). Pixels are 1-15 brightness levels, colored through a
//     row of unit\cmdbtns\ticon.pcx: row 0 available (yellow), row 1
//     unavailable (grey), row 2 active (bright), as in the original.
//   - game\icons.grp: the top bar's mineral, gas and supply icons (per race),
//     drawn with the normal palette.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../engine/bw_engine_io.dart';

/// Fixed cmdicons.grp frames for commands that aren't a unit/tech/upgrade.
abstract class CmdIcon {
  static const move = 228;
  static const stop = 229;
  static const attack = 230;
  static const gather = 231;
  static const repair = 232;
  static const returnCargo = 233;
  static const buildBasic = 234;
  static const buildAdvanced = 235;
  static const cancel = 236;
  static const patrol = 254;
  static const hold = 255;
  static const rally = 286;
  static const unload = 283;
}

enum IconState { normal, disabled, active }

class IconAtlas {
  final BwEngine _engine;
  final Uint8List _palette;
  final int _cmdIcons;
  final int _resourceIcons;
  final List<Uint8List> _rows = [];

  final Map<int, ui.Image> _cache = {};
  final Set<int> _pending = {};

  /// Called when an icon finishes decoding so panels can redraw.
  void Function()? onLoaded;

  IconAtlas(this._engine)
    : _palette = _engine.getPalette(),
      _cmdIcons = _engine.grpLoad(r'unit\cmdbtns\cmdicons.grp'),
      _resourceIcons = _engine.grpLoad(r'game\icons.grp') {
    final ticon = _engine.loadPcx(r'unit\cmdbtns\ticon.pcx');
    if (ticon != null) {
      final (w, h, px) = ticon;
      final all = Uint8List.fromList(px);
      // 16 entries per state row, laid out side by side.
      for (int r = 0; r * 16 + 16 <= w * h; ++r) {
        _rows.add(Uint8List.sublistView(all, r * 16, r * 16 + 16));
      }
    }
  }

  ui.Image? command(int frame, IconState state) =>
      _get(0, frame, state.index, () => _decodeCommand(frame, state.index));

  /// 0 = minerals, 1-3 = gas, 4-6 = supply (zerg, terran, protoss).
  ui.Image? resource(int frame) => _get(1, frame, 0, () => _decodeResource(frame));

  ui.Image? _get(int kind, int frame, int state, Future<ui.Image?> Function() decode) {
    if (frame < 0) return null;
    final key = (kind << 20) | (state << 12) | frame;
    final hit = _cache[key];
    if (hit != null) return hit;
    if (_pending.add(key)) {
      decode().then((img) {
        if (img != null) {
          _cache[key] = img;
          onLoaded?.call();
        }
      });
    }
    return null;
  }

  Future<ui.Image?> _decodeCommand(int frame, int state) async {
    if (_cmdIcons < 0) return null;
    final f = _engine.grpFrame(_cmdIcons, frame);
    if (f == null) return null;
    final (w, h, px) = f;
    final row = state < _rows.length ? _rows[state] : null;
    final rgba = Uint8List(w * h * 4);
    for (int i = 0; i < px.length; ++i) {
      final v = px[i];
      if (v == 0) continue;
      final idx = row != null && v < 16 ? row[v] : v;
      _put(rgba, i, idx);
    }
    return _image(rgba, w, h);
  }

  Future<ui.Image?> _decodeResource(int frame) async {
    if (_resourceIcons < 0) return null;
    final f = _engine.grpFrame(_resourceIcons, frame);
    if (f == null) return null;
    final (w, h, px) = f;
    final rgba = Uint8List(w * h * 4);
    for (int i = 0; i < px.length; ++i) {
      if (px[i] == 0) continue;
      _put(rgba, i, px[i]);
    }
    return _image(rgba, w, h);
  }

  void _put(Uint8List rgba, int i, int idx) {
    rgba[i * 4] = _palette[idx * 4];
    rgba[i * 4 + 1] = _palette[idx * 4 + 1];
    rgba[i * 4 + 2] = _palette[idx * 4 + 2];
    rgba[i * 4 + 3] = 255;
  }

  Future<ui.Image> _image(Uint8List rgba, int w, int h) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }
}
