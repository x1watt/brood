// Not a regular test: runs computer-only games and prints what each player
// fields. Run with: flutter test test/probe/ai_probe.dart --dart-define=MAP=... --dart-define=MINUTES=...
import 'dart:io';

import 'package:brood/engine/bw_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ai probe', () async {
    const map = String.fromEnvironment('MAP', defaultValue: 'maps/ladder/(4)Lost Temple.scm');
    const minutes = int.fromEnvironment('MINUTES', defaultValue: 20);
    const players = int.fromEnvironment('PLAYERS', defaultValue: 4);
    const races = String.fromEnvironment('RACES', defaultValue: '1,2,0,1,2,0,1,2');
    const teams = String.fromEnvironment('TEAMS', defaultValue: '0,0,0,0,0,0,0,0');
    const data = '/home/brito/box/media/games/BROOD';
    final e = await BwEngine.open();
    e.loadAssets(data);
    final r = races.split(',').map(int.parse).toList();
    final slots = e.newGame('$data/$map', [for (int i = 0; i < players; ++i) (human: i == 0, race: r[i], team: int.parse(teams.split(',')[i]))], 11);
    e.setAutoplay(slots[0], 15);
    final nukes = <int>{};
    var drops = 0;
    final seen = <int, Set<String>>{};
    final sw = Stopwatch()..start();
    for (int m = 1; m <= minutes; ++m) {
      for (int k = 0; k < 12; ++k) {
        e.step(24 * 5);
        for (final u in e.getUnits()) {
          if (u.typeId == 14) nukes.add(u.unitId); // a nuclear missile in flight or in a silo
          if ((u.typeId == 11 || u.typeId == 69) && e.loadedUnits(u.unitId).isNotEmpty) drops++;
        }
      }
      final units = e.getUnits();
      if (m % 5 != 0 && m != minutes) {
        for (final u in units) {
          if (u.owner < 8) seen.putIfAbsent(u.owner, () => {}).add(e.unitType(u.typeId).name);
        }
        continue;
      }
      stdout.writeln('--- minute $m (${sw.elapsedMilliseconds} ms)');
      for (final s in slots) {
        final counts = <String, int>{};
        for (final u in units.where((u) => u.owner == s)) {
          final n = e.unitType(u.typeId).name;
          counts[n] = (counts[n] ?? 0) + 1;
          seen.putIfAbsent(s, () => {}).add(n);
        }
        final sorted = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
        stdout.writeln('P$s state ${e.victoryState(s)} min ${e.minerals(s)} gas ${e.gas(s)}: ${sorted.map((x) => '${x.key} ${x.value}').join(', ')}');
      }
    }
    stdout.writeln('--- nukes built ${nukes.length}, transport-loaded samples $drops');
    stdout.writeln('--- ever seen');
    for (final s in slots) {
      stdout.writeln('P$s: ${(seen[s] ?? {}).join(', ')}');
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
