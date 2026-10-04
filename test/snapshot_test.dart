// Saved games as state through the Dart engine API: a state saved after a
// few minutes of play, compressed and back, loads into a second engine, and
// both play on identically. Needs the player's game files and the built
// bridge (skipped otherwise).

import 'dart:io';

import 'package:brood/engine/bw_engine.dart';
import 'package:brood/platform/compress.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final data = Platform.environment['BROOD_DATA'] ?? '${Platform.environment['HOME']}/box/media/games/BROOD';
  final map = '$data/maps/ladder/(4)Lost Temple.scm';
  final ok = File(map).existsSync() && File('engine/bridge/build/libbwbridge.so').existsSync();

  test('a saved state loads and plays on identically', () async {
    final players = [(human: true, race: 2, team: 0), (human: false, race: 0, team: 0), (human: false, race: 1, team: 0)];
    final a = await BwEngine.open();
    a.loadAssets(data);
    final slots = a.newGame(map, players, 99);
    a.setAutoplay(slots[0], 15);
    a.step(24 * 60 * 6);
    final raw = a.saveSnapshot()!;
    final packed = await deflate(raw);
    expect(packed.length, lessThan(raw.length ~/ 3), reason: 'compresses well (${raw.length} -> ${packed.length})');
    final b = await BwEngine.open();
    b.loadAssets(data);
    b.newGame(map, players, 99);
    final sw = Stopwatch()..start();
    expect(b.loadSnapshot(await inflate(packed)), true);
    expect(sw.elapsedMilliseconds, lessThan(1000));
    expect(b.currentFrame, a.currentFrame);
    expect(b.commandLog(), a.commandLog());
    for (int i = 0; i < 10; ++i) {
      expect(b.stateHash(), a.stateHash(), reason: 'after ${i * 240} frames');
      a.step(240);
      b.step(240);
    }
    // Something that isn't a state is refused.
    final c = await BwEngine.open();
    c.loadAssets(data);
    c.newGame(map, players, 99);
    expect(c.loadSnapshot(raw.sublist(0, 100)), false);
  }, skip: ok ? false : 'needs the game files and the built bridge', timeout: const Timeout(Duration(minutes: 5)));
}
