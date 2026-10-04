// Not a regular test: a Terran auto-plays an island game until it has a
// silo and covert ops, then a nuke is armed and called in by hand.
import 'dart:io';

import 'package:brood/engine/bw_engine.dart';
import 'package:brood/engine/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nuke probe', () async {
    const data = '/home/brito/box/media/games/BROOD';
    final e = await BwEngine.open();
    e.loadAssets(data);
    final slots = e.newGame('$data/maps/Brood/(8)Big Game Islands.scm', [(human: true, race: 1, team: 0), (human: false, race: 0, team: 0)], 3);
    final me = slots[0];
    e.setAutoplay(me, 15);
    List<UnitInfo> mine() => e.getUnits().where((u) => u.owner == me).toList();
    int m = 0;
    for (; m < 60; ++m) {
      e.step(24 * 60);
      final u = mine();
      if (u.any((x) => x.typeId == 108 && x.isCompleted) && u.any((x) => x.typeId == 117 && x.isCompleted)) break;
    }
    stdout.writeln('silo and covert ops by minute $m; victory state ${e.victoryState(me)}');
    final counts = <String, int>{};
    for (final u in mine()) {
      counts[e.unitType(u.typeId).name] = (counts[e.unitType(u.typeId).name] ?? 0) + 1;
    }
    stdout.writeln('$counts minerals ${e.minerals(me)} gas ${e.gas(me)}');
    final silo = mine().firstWhere((x) => x.typeId == 108);
    final barracks = mine().firstWhere((x) => x.typeId == 111 && x.isCompleted);
    e.setAutoplay(me, 1); // resources only from here
    String siloState() {
      final x = e.getUnit(silo.unitId)!;
      return 'silo queue ${x.queue} progress ${x.progressPermille}';
    }
    stdout.writeln('before arming: ${siloState()} supply ${e.supply(me, 1)}');
    e.selectUnits(me, [silo.unitId]);
    stdout.writeln('arm: ${e.train(me, 14)} ${siloState()}');
    e.selectUnits(me, [barracks.unitId]);
    stdout.writeln('ghost: ${e.train(me, 1)}');
    UnitInfo? ghost;
    for (int i = 0; i < 120 && ghost == null; ++i) {
      e.step(24);
      ghost = mine().where((x) => x.typeId == 1 && x.isCompleted).firstOrNull;
    }
    for (int i = 0; i < 6; ++i) {
      e.step(24 * 15);
      stdout.writeln(siloState());
    }
    stdout.writeln('ghost $ghost; units of type 14 now: ${e.getUnits().where((x) => x.typeId == 14).length}');
    e.selectUnits(me, [ghost!.unitId]);
    final target = (x: ghost.x + 200, y: ghost.y);
    stdout.writeln('nuke order: ${e.order(me, UnitOrder.nuke, target.x, target.y)}');
    var seenMissile = false;
    final before = mine().length;
    for (int i = 0; i < 40; ++i) {
      e.step(24);
      if (e.getUnits().any((x) => x.typeId == 14)) seenMissile = true;
    }
    stdout.writeln('missile seen in flight: $seenMissile; my units before $before after ${mine().length}');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
