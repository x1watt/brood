// tool/blend_terrain.dart
//
// Blends terrain changed by a script with the map editor's terrain blending
// (lib/maps/terrain_blend.dart): every column pair that differs between
// <before> and <painted> is kept as painted, and the edges around it get
// the transitions (shores, cliffs) learned from the player's maps of the
// same tileset. Start locations and resources keep their ground.
// tool/make_island_map.py runs it on the channels it cuts.
//
//   dart run tool/blend_terrain.dart <data_dir> <before.scm> <painted.scm> <out.scm>

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:brood/engine/bw_engine.dart';
import 'package:brood/maps/chk.dart';
import 'package:brood/maps/mpq_writer.dart';
import 'package:brood/maps/terrain_blend.dart';
import 'package:brood/maps/tileset.dart';

Future<void> main(List<String> args) async {
  if (args.length != 4) {
    stderr.writeln('usage: dart run tool/blend_terrain.dart <data_dir> <before.scm> <painted.scm> <out.scm>');
    exit(2);
  }
  final [dataDir, beforePath, paintedPath, outPath] = args;
  final engine = await BwEngine.open();
  engine.loadAssets(dataDir);
  ChkFile read(String path) {
    final bytes = engine.readMapFile(path, r'staredit\scenario.chk');
    if (bytes == null) throw StateError('cannot read $path');
    return ChkFile.parse(bytes);
  }

  final before = read(beforePath), painted = read(paintedPath);
  final (w, h) = before.size;
  if (painted.size != (w, h) || painted.tileset != before.tileset) throw StateError('the maps differ in size or tileset');
  final tileset = Tileset.load(before.tileset, engine.readFile)!;
  final a = before.tiles(), b = painted.tiles();

  // Learn from every map of this tileset but these two.
  final model = BlendModel();
  final skip = {File(beforePath).absolute.path, File(paintedPath).absolute.path, File(outPath).absolute.path};
  for (final f in Directory('$dataDir/maps').listSync(recursive: true).whereType<File>()) {
    final p = f.path.toLowerCase();
    if (!(p.endsWith('.scm') || p.endsWith('.scx')) || skip.contains(f.absolute.path)) continue;
    final bytes = engine.readMapFile(f.path, r'staredit\scenario.chk');
    if (bytes == null) continue;
    try {
      final c = ChkFile.parse(bytes);
      if (c.tileset != before.tileset) continue;
      final (cw, ch) = c.size;
      model.add(c.tiles(), cw, ch);
    } catch (_) {}
  }
  final learned = model.maps;
  model.add(a, w, h, weight: 100);

  // Painted tiles name a terrain; scripts may not keep the column pairs
  // (water on both columns of a pair), so a painted plain terrain becomes
  // its proper pair.
  final plainPair = <int, int>{};
  for (final groups in tileset.plainTerrains().values) {
    if (groups.length < 2) continue;
    for (final g in groups) {
      plainPair[g] = pairValue(groups[0], groups[1]);
    }
  }
  final pw = w ~/ 2;
  final forced = <int, Set<int>>{};
  for (int i = 0; i < a.length; ++i) {
    if (a[i] == b[i]) continue;
    final c = (i ~/ w) * pw + (i % w) ~/ 2;
    final y = c ~/ pw, x = (c % pw) * 2;
    final l = b[y * w + x] >> 4, rt = b[y * w + x + 1] >> 4;
    // The terrain of the tile that changed (the other may be untouched).
    final painted = a[y * w + x] != b[y * w + x] ? l : rt;
    forced[c] = {plainPair[painted] ?? pairValue(l, rt)};
  }
  final keep = <int>{};
  for (final u in painted.units()) {
    if (!(u.isResource || u.isStart)) continue;
    final (fw, fh) = u.isStart ? (4, 3) : (u.isGeyser ? (4, 2) : (2, 1));
    final tx = (u.x - fw * 16) ~/ 32, ty = (u.y - fh * 16) ~/ 32;
    for (int y = ty; y < ty + fh; ++y) {
      for (int x = tx; x < tx + fw; ++x) {
        if (x >= 0 && y >= 0 && x < w && y < h) keep.add(y * pw + x ~/ 2);
      }
    }
  }
  final r = model.blend(pairGrid(a, w, h), pw, h, forced, keep: keep);

  final rng = math.Random(1);
  final out = Uint16List.fromList(a);
  final gone = <int>{};
  r.changed.forEach((c, v) {
    final y = c ~/ pw, x = (c % pw) * 2;
    final (l, rt) = pairTiles(v, tileset.variations, rng);
    for (final (i, t) in [(y * w + x, l), (y * w + x + 1, rt)]) {
      if (tileset.isDoodad(out[i] >> 4)) gone.add(i);
      out[i] = t;
    }
  });
  painted.setTiles(out);
  // Doodad pictures on tiles that are no longer their doodad.
  for (final (tag, size) in [('THG2', 10), ('DD2 ', 8)]) {
    final s = painted.section(tag);
    if (s == null) continue;
    final d = ByteData.sublistView(s.data);
    final kept = BytesBuilder();
    for (int o = 0; o + size <= s.data.length; o += size) {
      final i = (d.getUint16(o + 4, Endian.little) ~/ 32) * w + d.getUint16(o + 2, Endian.little) ~/ 32;
      if (!gone.contains(i)) kept.add(s.data.sublist(o, o + size));
    }
    s.data = kept.toBytes();
  }
  File(outPath).writeAsBytesSync(writeMapArchive(painted.toBytes()));
  stdout.writeln('learned from $learned maps; ${forced.length} painted cells, ${r.changed.length} changed, ${r.failed} areas not blended');
  engine.dispose();
}
