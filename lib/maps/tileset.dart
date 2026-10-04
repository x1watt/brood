// lib/maps/tileset.dart
//
// A tileset's tables, read from the player's game files for the map editor
// (the game itself draws terrain through the bridge):
//   cv5  tile groups: per group its terrain type, edges and 16 megatiles
//        (a map tile is (group << 4) | variation),
//   vf4  per megatile the flags of its 4x4 minitiles (walkable, height),
//   vx4  per megatile its 4x4 minitiles (an 8x8 image of vr4, maybe flipped),
//   vr4  the 8x8 images, palette indices,
//   wpe  the palette.
// Plain data, so it can go to a background isolate.

import 'dart:typed_data';

const List<String> tilesetNames = ['badlands', 'platform', 'install', 'ashworld', 'jungle', 'desert', 'ice', 'twilight'];

/// Groups from 1024 on are doodads (multi-tile pictures: trees, temples,
/// statues), the rest terrain.
const int firstDoodadGroup = 1024;

class Tileset {
  final int index;
  final Uint16List cv5; // 26 words per group
  final Uint16List vf4; // 16 words per megatile
  final Uint16List vx4; // 16 words per megatile
  final Uint8List vr4; // 64 bytes per image
  final Uint8List palette; // 256 RGBA

  Tileset({required this.index, required this.cv5, required this.vf4, required this.vx4, required this.vr4, required this.palette});

  static const _groupWords = 26;

  String get name => tilesetNames[index];
  int get groupCount => cv5.length ~/ _groupWords;
  int get megatileCount => vx4.length ~/ 16;

  /// Reads the tables with [read] (a file from the game's archives).
  static Tileset? load(int index, Uint8List? Function(String path) read) {
    final n = tilesetNames[index];
    final cv5 = read('Tileset\\$n.cv5');
    final vf4 = read('Tileset\\$n.vf4');
    final vx4 = read('Tileset\\$n.vx4');
    final vr4 = read('Tileset\\$n.vr4');
    final wpe = read('Tileset\\$n.wpe');
    if (cv5 == null || vf4 == null || vx4 == null || vr4 == null || wpe == null || wpe.length < 1024) return null;
    Uint16List words(Uint8List b) {
      final d = ByteData.sublistView(b);
      return Uint16List.fromList([for (int i = 0; i + 1 < b.length; i += 2) d.getUint16(i, Endian.little)]);
    }

    final palette = Uint8List(1024);
    for (int i = 0; i < 256; ++i) {
      palette[i * 4] = wpe[i * 4];
      palette[i * 4 + 1] = wpe[i * 4 + 1];
      palette[i * 4 + 2] = wpe[i * 4 + 2];
      palette[i * 4 + 3] = 255;
    }
    return Tileset(index: index, cv5: words(cv5), vf4: words(vf4), vx4: words(vx4), vr4: vr4, palette: palette);
  }

  int _g(int group, int word) => group < groupCount ? cv5[group * _groupWords + word] : 0;

  /// The group's terrain type (0 unused, 1 doodad).
  int groupType(int group) => _g(group, 0);
  int groupFlags(int group) => _g(group, 1);

  /// Edge ids left, top, right, bottom. A plain terrain has the same id on
  /// every side.
  List<int> edges(int group) => [_g(group, 2), _g(group, 3), _g(group, 4), _g(group, 5)];

  int megatile(int tile) => _g(tile >> 4, 10 + (tile & 15));

  bool isDoodad(int group) => group >= firstDoodadGroup;

  /// Variations the group really has (unused ones point at megatile 0).
  List<int> variations(int group) {
    final out = <int>[];
    for (int v = 0; v < 16; ++v) {
      if (_g(group, 10 + v) != 0) out.add(v);
    }
    return out.isEmpty ? const [0] : out;
  }

  /// Minitile flags of a megatile (16, row by row): 1 walkable, 2 mid,
  /// 4 high ground, 8 blocks view, 0x10 ramp.
  int minitileFlags(int megatile, int i) => megatile * 16 + i < vf4.length ? vf4[megatile * 16 + i] : 0;

  /// How many of the tile's 16 minitiles are walkable.
  int walkable(int tile) {
    final m = megatile(tile);
    int n = 0;
    for (int i = 0; i < 16; ++i) {
      if (minitileFlags(m, i) & 1 != 0) n++;
    }
    return n;
  }

  /// A megatile as 32x32 palette indices.
  void decodeMegatile(int megatile, Uint8List out, [int offset = 0, int stride = 32]) {
    for (int my = 0; my < 4; ++my) {
      for (int mx = 0; mx < 4; ++mx) {
        final v = megatile * 16 + my * 4 + mx < vx4.length ? vx4[megatile * 16 + my * 4 + mx] : 0;
        final image = (v >> 1) * 64;
        final flipped = v & 1 != 0;
        for (int y = 0; y < 8; ++y) {
          final row = offset + (my * 8 + y) * stride + mx * 8;
          for (int x = 0; x < 8; ++x) {
            final src = image + y * 8 + (flipped ? 7 - x : x);
            out[row + x] = src < vr4.length ? vr4[src] : 0;
          }
        }
      }
    }
  }

  /// Plain terrains: groups whose four edges are the same id, keyed by that
  /// id (the brushes of the editor: water, dirt, high ground...). Pairs of
  /// groups (left and right columns) belong together.
  Map<int, List<int>> plainTerrains() {
    final out = <int, List<int>>{};
    for (int g = 0; g < firstDoodadGroup && g < groupCount; ++g) {
      final e = edges(g);
      if (e[0] == 0 || groupType(g) == 0) continue;
      if (e.every((v) => v == e[0])) out.putIfAbsent(e[0], () => []).add(g);
    }
    return out;
  }
}
