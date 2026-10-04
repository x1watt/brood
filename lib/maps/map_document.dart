// lib/maps/map_document.dart
//
// The map being edited: its terrain, start locations and resources, with
// undo and redo, read from and written back to the map's scenario data
// (chk.dart). Every other part of the map (triggers, forces, sounds...) is
// written back unchanged.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'chk.dart';
import 'mpq_writer.dart';
import 'tileset.dart';

class MapDocument extends ChangeNotifier {
  final ChkFile chk;
  final Tileset tileset;
  final int width; // tiles
  final int height;
  Uint16List tiles;
  List<ChkUnit> units;
  Uint8List _thg2; // doodad sprites, 10 bytes each
  Uint8List _dd2; // doodads, 8 bytes each
  String name;
  String description;

  /// Bumped on every change (painters repaint, the minimap rebuilds).
  int revision = 0;
  bool dirty = false;

  final List<_Snapshot> _undo = [];
  final List<_Snapshot> _redo = [];
  static const int _maxUndo = 100;

  MapDocument._(this.chk, this.tileset, this.width, this.height, this.tiles, this.units, this._thg2, this._dd2, this.name, this.description);

  /// Reads a map's scenario data; [tilesetOf] loads the tileset it uses.
  static MapDocument? open(Uint8List chkBytes, Tileset? Function(int index) tilesetOf) {
    final chk = ChkFile.parse(chkBytes);
    if (chk.section('DIM ') == null || chk.section('MTXM') == null) return null;
    final tileset = tilesetOf(chk.tileset);
    if (tileset == null) return null;
    final (w, h) = chk.size;
    return MapDocument._(
      chk,
      tileset,
      w,
      h,
      chk.tiles(),
      chk.units(),
      chk.section('THG2')?.data ?? Uint8List(0),
      chk.section('DD2 ')?.data ?? Uint8List(0),
      chk.name,
      chk.description,
    );
  }

  // --- undo ---

  _Snapshot _snap() => _Snapshot(Uint16List.fromList(tiles), [for (final u in units) u.copy()], _thg2, _dd2, name, description);

  void _restore(_Snapshot s) {
    tiles = Uint16List.fromList(s.tiles);
    units = [for (final u in s.units) u.copy()];
    _thg2 = s.thg2;
    _dd2 = s.dd2;
    name = s.name;
    description = s.description;
  }

  /// Call before each user action: what undo goes back to.
  void checkpoint() {
    _undo.add(_snap());
    if (_undo.length > _maxUndo) _undo.removeAt(0);
    _redo.clear();
  }

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(_snap());
    _restore(_undo.removeLast());
    _changed();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_snap());
    _restore(_redo.removeLast());
    _changed();
  }

  void _changed() {
    revision++;
    dirty = true;
    notifyListeners();
  }

  // --- terrain ---

  int tileAt(int x, int y) => tiles[y * width + x];

  /// Sets tiles (index -> value). Doodad pictures standing on tiles that
  /// stop being part of their doodad go too.
  void setTiles(Map<int, int> changes) {
    if (changes.isEmpty) return;
    final gone = <int>{};
    changes.forEach((i, v) {
      if (tileset.isDoodad(tiles[i] >> 4) && !tileset.isDoodad(v >> 4)) gone.add(i);
      tiles[i] = v;
    });
    if (gone.isNotEmpty) {
      _thg2 = _dropOn(_thg2, 10, gone);
      _dd2 = _dropOn(_dd2, 8, gone);
    }
    _changed();
  }

  Uint8List _dropOn(Uint8List entries, int size, Set<int> tilesGone) {
    final d = ByteData.sublistView(entries);
    final keep = BytesBuilder();
    for (int o = 0; o + size <= entries.length; o += size) {
      final x = d.getUint16(o + 2, Endian.little) ~/ 32, y = d.getUint16(o + 4, Endian.little) ~/ 32;
      if (!tilesGone.contains(y * width + x)) keep.add(entries.sublist(o, o + size));
    }
    return keep.toBytes();
  }

  // --- units ---

  List<ChkUnit> get starts => units.where((u) => u.isStart && u.owner < 8).toList();
  List<ChkUnit> get resources => units.where((u) => u.isResource).toList();

  int _nextSerial() => units.fold<int>(0, (m, u) => math.max(m, u.serial)) + 1;

  /// The lowest player (0-7) without a start location, or null when all
  /// eight have one.
  int? get freePlayer {
    final used = starts.map((u) => u.owner).toSet();
    for (int p = 0; p < 8; ++p) {
      if (!used.contains(p)) return p;
    }
    return null;
  }

  ChkUnit? addStart(int x, int y) {
    final p = freePlayer;
    if (p == null) return null;
    final u = ChkUnit.start(_nextSerial(), x, y, p);
    units.add(u);
    _changed();
    return u;
  }

  ChkUnit addResource(int type, int x, int y, int amount) {
    final u = ChkUnit.resource(_nextSerial(), type, x, y, amount);
    units.add(u);
    _changed();
    return u;
  }

  void moveUnit(ChkUnit u, int x, int y) {
    u.x = x;
    u.y = y;
    _changed();
  }

  void removeUnit(ChkUnit u) {
    units.remove(u);
    _changed();
  }

  void setAmount(ChkUnit u, int amount) {
    u.resources = amount;
    u.validElements |= 16; // the amount is set
    _changed();
  }

  /// Gives the start location to another player; swaps with that player's
  /// start when there is one.
  void setStartPlayer(ChkUnit u, int player) {
    for (final other in starts) {
      if (other != u && other.owner == player) other.owner = u.owner;
    }
    u.owner = player;
    _changed();
  }

  /// Sets every mineral field and geyser at once (either may be null).
  void setAllAmounts({int? minerals, int? gas}) {
    for (final u in resources) {
      final v = u.isGeyser ? gas : minerals;
      if (v == null) continue;
      u.resources = v;
      u.validElements |= 16;
    }
    _changed();
  }

  void setInfo(String name, String description) {
    this.name = name;
    this.description = description;
    _changed();
  }

  // --- placement ---

  /// Footprint in tiles of what the editor places, centered on the unit's
  /// position as the game stores it.
  static (int, int) footprint(int type) => switch (type) {
    ChkUnit.startLocation => (4, 3),
    ChkUnit.geyser => (4, 2),
    _ => (2, 1), // mineral fields
  };

  /// The unit's center when its top-left tile is ([tx], [ty]).
  static (int, int) centerAt(int type, int tx, int ty) {
    final (w, h) = footprint(type);
    return (tx * 32 + w * 16, ty * 32 + h * 16);
  }

  /// Top-left tile of a unit placed with its center near ([px], [py]).
  static (int, int) snap(int type, double px, double py) {
    final (w, h) = footprint(type);
    return (((px - w * 16) / 32).round(), ((py - h * 16) / 32).round());
  }

  /// Why a unit can't stand there, or null when it can: inside the map,
  /// not over another resource or start location, and (for resources and
  /// starts) on ground.
  String? placementProblem(int type, int tx, int ty, {ChkUnit? ignore}) {
    final (w, h) = footprint(type);
    if (tx < 0 || ty < 0 || tx + w > width || ty + h > height) return 'Outside the map';
    for (final u in units) {
      if (u == ignore || !(u.isResource || u.isStart)) continue;
      final (uw, uh) = footprint(u.type);
      final ux = (u.x - uw * 16) ~/ 32, uy = (u.y - uh * 16) ~/ 32;
      if (tx < ux + uw && ux < tx + w && ty < uy + uh && uy < ty + h) return 'Overlaps another';
    }
    for (int y = ty; y < ty + h; ++y) {
      for (int x = tx; x < tx + w; ++x) {
        if (tileset.walkable(tileAt(x, y)) < 8) return 'Not on open ground';
      }
    }
    return null;
  }

  // --- writing ---

  /// The map archive with the edits.
  Uint8List save() {
    chk.setTiles(tiles);
    chk.setUnits(units);
    chk.put('THG2', _thg2);
    chk.put('DD2 ', _dd2);
    // Slots with a start location are players (open to a human or a
    // computer), slots without one are not.
    final owners = chk.owners();
    final with_ = starts.map((u) => u.owner).toSet();
    for (int p = 0; p < 8; ++p) {
      if (with_.contains(p)) {
        if (owners[p] != 5 && owners[p] != 6) owners[p] = 6;
      } else {
        owners[p] = 0;
      }
    }
    chk.setOwners(owners);
    final side = chk.section('SIDE')?.data;
    if (side != null && side.length >= 8) {
      for (final p in with_) {
        if (side[p] > 2 && side[p] != 5) side[p] = 5; // the player chooses the race
      }
    }
    if (name != chk.name) chk.name = name;
    if (description != chk.description) chk.description = description;
    dirty = false;
    notifyListeners();
    return writeMapArchive(chk.toBytes());
  }
}

class _Snapshot {
  final Uint16List tiles;
  final List<ChkUnit> units;
  final Uint8List thg2;
  final Uint8List dd2;
  final String name;
  final String description;
  _Snapshot(this.tiles, this.units, this.thg2, this.dd2, this.name, this.description);
}
