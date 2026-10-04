// The map editor's file handling: the MPQ writer's hashes, CHK sections
// and strings, and (with the player's game files on this machine) a whole
// round: open a real map, paint water with blended edges, move a start
// location, set the resources, save, read it back through the engine and
// start a game on it.

import 'dart:io';
import 'dart:typed_data';

import 'package:brood/engine/bw_engine.dart';
import 'package:brood/maps/chk.dart';
import 'package:brood/maps/map_document.dart';
import 'package:brood/maps/mpq_writer.dart';
import 'package:brood/maps/terrain_blend.dart';
import 'package:brood/maps/tileset.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _section(String tag, List<int> data) =>
    Uint8List.fromList([...tag.codeUnits, data.length & 0xff, (data.length >> 8) & 0xff, 0, 0, ...data]);

void main() {
  test('MPQ table keys are the well-known ones', () {
    expect(mpqHash('(hash table)', 3), 0xC3AF3770);
    expect(mpqHash('(block table)', 3), 0xEC83B3A3);
  });

  test('CHK sections, units and strings round-trip', () {
    final bytes = Uint8List.fromList([
      ..._section('VER ', [205, 0]),
      ..._section('DIM ', [2, 0, 1, 0]),
      ..._section('ERA ', [4, 0]),
      ..._section('MTXM', [0x20, 0, 0x30, 0]),
      ..._section('STR ', [1, 0, 4, 0, 0x41, 0x42, 0]), // one string: "AB"
      ..._section('SPRP', [1, 0, 0, 0]),
    ]);
    final chk = ChkFile.parse(bytes);
    expect(chk.size, (2, 1));
    expect(chk.tileset, 4);
    expect(chk.tiles(), [0x20, 0x30]);
    expect(chk.name, 'AB');
    chk.name = 'New name';
    expect(chk.name, 'New name');
    expect(chk.strings().length, 2);
    chk.setUnits([ChkUnit.resource(1, 176, 64, 48, 1500), ChkUnit.start(2, 128, 96, 3)]);
    final again = ChkFile.parse(chk.toBytes());
    final units = again.units();
    expect(units.length, 2);
    expect(units[0].isMineral, true);
    expect(units[0].resources, 1500);
    expect(units[1].isStart, true);
    expect(units[1].owner, 3);
    expect(again.name, 'New name');
  });

  final data = Platform.environment['BROOD_DATA'] ?? '${Platform.environment['HOME']}/box/media/games/BROOD';
  final map = '$data/maps/BroodWar/WebMaps/(8)Big Game Hunters.scm';
  final haveData = File(map).existsSync() && File('engine/bridge/build/libbwbridge.so').existsSync();

  test('edit, save and play a real map', () async {
    final engine = await BwEngine.open();
    engine.loadAssets(data);
    final doc = MapDocument.open(engine.readMapFile(map, r'staredit\scenario.chk')!, (i) => Tileset.load(i, engine.readFile))!;
    expect(doc.width, 128);
    expect(doc.starts.length, 8);

    // Water across the middle, edges blended with what the map itself shows.
    final model = BlendModel()..add(doc.tiles, doc.width, doc.height, weight: 100);
    final pw = doc.width ~/ 2;
    final water = doc.tileset.plainTerrains().values.firstWhere((g) => doc.tileset.walkable(g[0] << 4 | doc.tileset.variations(g[0]).first) == 0);
    final forced = {for (int y = 60; y < 68; ++y) for (int x = 28; x < 36; ++x) y * pw + x: {pairValue(water[0], water[1])}};
    final r = model.blend(pairGrid(doc.tiles, doc.width, doc.height), pw, doc.height, forced);
    expect(r.failed, 0);
    expect(r.changed.length, greaterThan(forced.length)); // the edges changed too
    doc.checkpoint();
    final changes = <int, int>{};
    r.changed.forEach((c, v) {
      changes[(c ~/ pw) * doc.width + (c % pw) * 2] = pairLeft(v) << 4 | doc.tileset.variations(pairLeft(v)).first;
      changes[(c ~/ pw) * doc.width + (c % pw) * 2 + 1] = pairRight(v) << 4 | doc.tileset.variations(pairRight(v)).first;
    });
    doc.setTiles(changes);

    // Undo and redo.
    final painted = Uint16List.fromList(doc.tiles);
    doc.undo();
    expect(doc.tiles, isNot(painted));
    doc.redo();
    expect(doc.tiles, painted);

    // One start location less, resources set.
    doc.checkpoint();
    doc.removeUnit(doc.starts.last);
    doc.setAllAmounts(minerals: 1500, gas: 5000);
    doc.setInfo('Big Game Test', 'made by the editor test');

    final out = File('${Directory.systemTemp.createTempSync('brood_map').path}/(7)Big Game Test.scm');
    out.writeAsBytesSync(doc.save());
    final back = ChkFile.parse(engine.readMapFile(out.path, r'staredit\scenario.chk')!);
    expect(back.tiles(), painted);
    expect(back.units().where((u) => u.isStart).length, 7);
    expect(back.units().where((u) => u.isMineral).every((u) => u.resources == 1500), true);
    expect(back.owners().sublist(0, 8).where((o) => o == 6).length, 7);
    expect(back.name, 'Big Game Test');

    // The engine plays it.
    engine.newMeleeGame(out.path);
    engine.dispose();
    out.parent.deleteSync(recursive: true);
  }, skip: haveData ? false : 'needs the game files and the built bridge');
}
