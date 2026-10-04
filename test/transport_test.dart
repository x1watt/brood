// Transports through the bridge: auto-play builds a shuttle on an island
// map; zealots load into it, one is unloaded by itself, and the rest are
// dropped at a spot it flies to. Needs the player's game files and the built
// bridge (skipped otherwise).

import 'dart:io';

import 'package:brood/engine/bw_engine.dart';
import 'package:brood/engine/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final data = Platform.environment['BROOD_DATA'] ?? '${Platform.environment['HOME']}/box/media/games/BROOD';
  final map = '$data/maps/Brood/(8)Big Game Islands.scm';
  final ok = File(map).existsSync() && File('engine/bridge/build/libbwbridge.so').existsSync();

  test('load, unload one, unload at a spot', () async {
    final e = await BwEngine.open();
    e.loadAssets(data);
    final slots = e.newGame(map, [(human: true, race: 2, team: 0), (human: false, race: 1, team: 0)], 5);
    final me = slots[0];
    e.setAutoplay(me, 15);
    UnitInfo? shuttle;
    List<UnitInfo> zealots = [];
    for (int m = 0; m < 20 && (shuttle == null || zealots.length < 3); ++m) {
      e.step(24 * 60);
      final mine = e.getUnits().where((u) => u.owner == me).toList();
      shuttle = mine.where((u) => u.typeId == 69 && u.isCompleted).firstOrNull;
      zealots = mine.where((u) => u.typeId == 65 && u.isCompleted).toList();
    }
    expect(shuttle, isNotNull, reason: 'auto-play built no shuttle');
    // Hand-commanded from here: auto-play off.
    e.setAutoplay(me, 0);
    // Empty it first (auto-play may have loaded it).
    e.selectUnits(me, [shuttle!.unitId]);
    e.ability(me, Ability.unloadAll);
    e.step(24 * 5);
    final riders = zealots.take(3).map((u) => u.unitId).toList();
    e.selectUnits(me, riders);
    expect(e.order(me, UnitOrder.smart, shuttle.x, shuttle.y, targetUnitId: shuttle.unitId), true);
    for (int i = 0; i < 40 && e.loadedUnits(shuttle.unitId).length < riders.length; ++i) {
      e.step(24);
    }
    final loaded = e.loadedUnits(shuttle.unitId);
    expect(loaded.length, riders.length, reason: 'the zealots got in');
    // The selection panel shows them by type.
    expect(loaded.map((id) => e.getUnit(id)?.typeId), everyElement(65));
    expect(e.unloadUnit(me, loaded.first), true);
    for (int i = 0; i < 10 && e.loadedUnits(shuttle.unitId).length == riders.length; ++i) {
      e.step(12);
    }
    expect(e.loadedUnits(shuttle.unitId).length, riders.length - 1, reason: 'one got out');
    // The rest at a spot on the same island, a little away.
    final spot = (x: shuttle.x + 160, y: shuttle.y);
    e.selectUnits(me, [shuttle.unitId]);
    expect(e.order(me, UnitOrder.unloadAt, spot.x, spot.y), true);
    for (int i = 0; i < 40 && e.loadedUnits(shuttle.unitId).isNotEmpty; ++i) {
      e.step(24);
    }
    expect(e.loadedUnits(shuttle.unitId), isEmpty, reason: 'everyone got out at the spot');
    final s = e.getUnit(shuttle.unitId)!;
    expect((s.x - spot.x).abs() + (s.y - spot.y).abs(), lessThan(200), reason: 'it flew there first');
    e.dispose();
  }, skip: ok ? false : 'needs the game files and the built bridge', timeout: const Timeout(Duration(minutes: 5)));
}
