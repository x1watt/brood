// lib/maps/chk.dart
//
// A map's scenario data (staredit\scenario.chk): a list of tagged sections.
// The map editor changes a few of them (the terrain in MTXM and TILE, units
// in UNIT, doodad sprites in THG2/DD2, which slots are players in OWNR, the
// name and description through STR/SPRP) and writes every other section back
// as it was read.

import 'dart:convert';
import 'dart:typed_data';

class ChkSection {
  final String tag; // four characters, "MTXM", "STR "...
  Uint8List data;
  ChkSection(this.tag, this.data);
}

/// One entry of the UNIT section (36 bytes): the map's placed units, which
/// for a melee map are the start locations and the resources.
class ChkUnit {
  static const size = 36;
  static const startLocation = 214;
  static const mineralTypes = [176, 177, 178];
  static const geyser = 188;
  static const neutral = 11;

  int serial;
  int x, y; // center, in pixels
  int type;
  int relation;
  int validProperties;
  int validElements;
  int owner;
  int hp, shield, energy; // percent
  int resources;
  int hangar;
  int state;
  int related;

  ChkUnit({
    required this.serial,
    required this.x,
    required this.y,
    required this.type,
    this.relation = 0,
    this.validProperties = 0,
    this.validElements = 0,
    this.owner = neutral,
    this.hp = 100,
    this.shield = 0,
    this.energy = 0,
    this.resources = 0,
    this.hangar = 0,
    this.state = 0,
    this.related = 0,
  });

  bool get isStart => type == startLocation;
  bool get isMineral => mineralTypes.contains(type);
  bool get isGeyser => type == geyser;
  bool get isResource => isMineral || isGeyser;

  /// A new start location for player [owner] (0-7).
  factory ChkUnit.start(int serial, int x, int y, int owner) =>
      ChkUnit(serial: serial, x: x, y: y, type: startLocation, owner: owner, hp: 0);

  /// A new resource as the original editor places them (owner neutral,
  /// hit points and the amount set).
  factory ChkUnit.resource(int serial, int type, int x, int y, int amount) =>
      ChkUnit(serial: serial, x: x, y: y, type: type, validProperties: 16, validElements: 18, resources: amount);

  ChkUnit copy() => ChkUnit(
    serial: serial,
    x: x,
    y: y,
    type: type,
    relation: relation,
    validProperties: validProperties,
    validElements: validElements,
    owner: owner,
    hp: hp,
    shield: shield,
    energy: energy,
    resources: resources,
    hangar: hangar,
    state: state,
    related: related,
  );

  static ChkUnit read(ByteData d, int o) => ChkUnit(
    serial: d.getUint32(o, Endian.little),
    x: d.getUint16(o + 4, Endian.little),
    y: d.getUint16(o + 6, Endian.little),
    type: d.getUint16(o + 8, Endian.little),
    relation: d.getUint16(o + 10, Endian.little),
    validProperties: d.getUint16(o + 12, Endian.little),
    validElements: d.getUint16(o + 14, Endian.little),
    owner: d.getUint8(o + 16),
    hp: d.getUint8(o + 17),
    shield: d.getUint8(o + 18),
    energy: d.getUint8(o + 19),
    resources: d.getUint32(o + 20, Endian.little),
    hangar: d.getUint16(o + 24, Endian.little),
    state: d.getUint16(o + 26, Endian.little),
    related: d.getUint32(o + 32, Endian.little),
  );

  void write(ByteData d, int o) {
    d.setUint32(o, serial, Endian.little);
    d.setUint16(o + 4, x, Endian.little);
    d.setUint16(o + 6, y, Endian.little);
    d.setUint16(o + 8, type, Endian.little);
    d.setUint16(o + 10, relation, Endian.little);
    d.setUint16(o + 12, validProperties, Endian.little);
    d.setUint16(o + 14, validElements, Endian.little);
    d.setUint8(o + 16, owner);
    d.setUint8(o + 17, hp);
    d.setUint8(o + 18, shield);
    d.setUint8(o + 19, energy);
    d.setUint32(o + 20, resources, Endian.little);
    d.setUint16(o + 24, hangar, Endian.little);
    d.setUint16(o + 26, state, Endian.little);
    d.setUint32(o + 28, 0, Endian.little);
    d.setUint32(o + 32, related, Endian.little);
  }
}

class ChkFile {
  final List<ChkSection> sections;
  ChkFile(this.sections);

  static ChkFile parse(Uint8List bytes) {
    final d = ByteData.sublistView(bytes);
    final out = <ChkSection>[];
    int i = 0;
    while (i + 8 <= bytes.length) {
      final tag = String.fromCharCodes(bytes.sublist(i, i + 4));
      final len = d.getInt32(i + 4, Endian.little);
      i += 8;
      // Protected maps put junk after the real sections: stop there.
      if (len < 0 || i + len > bytes.length) break;
      out.add(ChkSection(tag, Uint8List.fromList(bytes.sublist(i, i + len))));
      i += len;
    }
    return ChkFile(out);
  }

  Uint8List toBytes() {
    final b = BytesBuilder(copy: false);
    for (final s in sections) {
      final head = ByteData(8);
      for (int k = 0; k < 4; ++k) {
        head.setUint8(k, s.tag.codeUnitAt(k));
      }
      head.setInt32(4, s.data.length, Endian.little);
      b.add(head.buffer.asUint8List());
      b.add(s.data);
    }
    return b.toBytes();
  }

  /// The section the game reads: the last one with that tag.
  ChkSection? section(String tag) {
    for (int i = sections.length - 1; i >= 0; --i) {
      if (sections[i].tag == tag) return sections[i];
    }
    return null;
  }

  /// Replaces the section (the last of that tag) or adds it at the end.
  void put(String tag, Uint8List data) {
    final s = section(tag);
    if (s != null) {
      s.data = data;
    } else {
      sections.add(ChkSection(tag, data));
    }
  }

  int get tileset {
    final era = section('ERA ')?.data;
    if (era == null || era.length < 2) return 0;
    return ByteData.sublistView(era).getUint16(0, Endian.little) & 7;
  }

  (int, int) get size {
    final d = ByteData.sublistView(section('DIM ')!.data);
    return (d.getUint16(0, Endian.little), d.getUint16(2, Endian.little));
  }

  /// Tile values ((group << 4) | variation), width * height of them.
  Uint16List tiles() {
    final (w, h) = size;
    final out = Uint16List(w * h);
    final m = section('MTXM') ?? section('TILE');
    if (m == null) return out;
    final d = ByteData.sublistView(m.data);
    final n = (m.data.length ~/ 2).clamp(0, out.length);
    for (int i = 0; i < n; ++i) {
      out[i] = d.getUint16(i * 2, Endian.little);
    }
    return out;
  }

  void setTiles(Uint16List tiles) {
    final bytes = Uint8List(tiles.length * 2);
    final d = ByteData.sublistView(bytes);
    for (int i = 0; i < tiles.length; ++i) {
      d.setUint16(i * 2, tiles[i], Endian.little);
    }
    put('MTXM', bytes);
    put('TILE', Uint8List.fromList(bytes)); // the editor's copy of the terrain
  }

  List<ChkUnit> units() {
    final s = section('UNIT');
    if (s == null) return [];
    final d = ByteData.sublistView(s.data);
    return [for (int o = 0; o + ChkUnit.size <= s.data.length; o += ChkUnit.size) ChkUnit.read(d, o)];
  }

  void setUnits(List<ChkUnit> units) {
    final bytes = Uint8List(units.length * ChkUnit.size);
    final d = ByteData.sublistView(bytes);
    for (int i = 0; i < units.length; ++i) {
      units[i].write(d, i * ChkUnit.size);
    }
    put('UNIT', bytes);
  }

  /// Player slots (12): 0 inactive, 5 computer, 6 human (open), 7 neutral...
  List<int> owners() => List<int>.of(section('OWNR')?.data ?? Uint8List(12));

  void setOwners(List<int> owners) {
    put('OWNR', Uint8List.fromList(owners));
    // IOWN is StarEdit's copy.
    if (section('IOWN') != null) put('IOWN', Uint8List.fromList(owners));
  }

  // --- strings ---

  /// Every string of the STR section, 1-based in the game's use ([0] is
  /// string 1).
  List<Uint8List> strings() {
    final s = section('STR ');
    if (s == null || s.data.length < 2) return [];
    final d = ByteData.sublistView(s.data);
    final count = d.getUint16(0, Endian.little);
    final out = <Uint8List>[];
    for (int i = 0; i < count; ++i) {
      if (2 + i * 2 + 2 > s.data.length) break;
      final off = d.getUint16(2 + i * 2, Endian.little);
      if (off >= s.data.length) {
        out.add(Uint8List(0));
        continue;
      }
      int end = off;
      while (end < s.data.length && s.data[end] != 0) {
        end++;
      }
      out.add(s.data.sublist(off, end));
    }
    return out;
  }

  void _setStrings(List<Uint8List> strings) {
    final count = strings.length;
    final head = 2 + 2 * count;
    final body = BytesBuilder();
    final offsets = <int>[];
    for (final t in strings) {
      offsets.add(head + body.length);
      body.add(t);
      body.addByte(0);
    }
    final out = Uint8List(head + body.length);
    final d = ByteData.sublistView(out);
    d.setUint16(0, count, Endian.little);
    for (int i = 0; i < count; ++i) {
      d.setUint16(2 + i * 2, offsets[i], Endian.little);
    }
    out.setRange(head, out.length, body.toBytes());
    put('STR ', out);
  }

  static String decode(Uint8List bytes) => latin1.decode(bytes, allowInvalid: true);

  String _sprpString(int which) {
    final s = section('SPRP');
    if (s == null || s.data.length < 4) return '';
    final index = ByteData.sublistView(s.data).getUint16(which * 2, Endian.little);
    final all = strings();
    if (index == 0 || index > all.length) return '';
    return decode(all[index - 1]);
  }

  /// Sets SPRP's name ([which] 0) or description (1) to a new string. The
  /// old one stays (other sections may use the same string).
  void _setSprpString(int which, String text) {
    final all = strings();
    final bytes = Uint8List.fromList(latin1.encode(text.replaceAll(RegExp(r'[^\x00-\xff]'), '?')));
    // Reuse an equal string when there is one.
    int index = all.indexWhere((s) => _same(s, bytes)) + 1;
    if (index == 0) {
      all.add(bytes);
      index = all.length;
      _setStrings(all);
    }
    final sprp = section('SPRP')?.data ?? Uint8List(4);
    final d = ByteData.sublistView(sprp);
    d.setUint16(which * 2, index, Endian.little);
    put('SPRP', sprp);
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; ++i) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  String get name => _sprpString(0);
  set name(String v) => _setSprpString(0, v);
  String get description => _sprpString(1);
  set description(String v) => _setSprpString(1, v);
}
