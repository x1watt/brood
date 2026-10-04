// Not a regular test: replays a saved game and times it.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:brood/engine/bw_engine.dart';
import 'package:brood/game/game_setup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('replay probe', () async {
    const dir = String.fromEnvironment('SAVE');
    const v1 = bool.fromEnvironment('V1', defaultValue: true);
    final session = jsonDecode(File('$dir/session.json').readAsStringSync()) as Map<String, dynamic>;
    final points = Directory(dir).listSync().whereType<File>().where((f) => f.path.contains('/t')).map((f) => f.path).toList()..sort();
    final point = jsonDecode(File(points.last).readAsStringSync()) as Map<String, dynamic>;
    final log = Uint8List.fromList(base64Decode(point['log'] as String)).buffer.asInt32List();
    final setup = GameSetup.fromJson(Map<String, dynamic>.from(session['setup'] as Map));
    final e = await BwEngine.open();
    e.loadAssets('/home/brito/box/media/games/BROOD');
    e.newGame(session['mapFile'] as String, [for (final p in setup.players) (human: p.human, race: p.race, team: p.team)], setup.seed);
    if (setup.legacyAi && v1) e.setAiVersion(1);
    final sw = Stopwatch()..start();
    int i = 0;
    for (int f = 1200; f <= (point['frame'] as int) + 1200; f += 1200) {
      final start = i;
      while (i + 3 <= log.length && log[i] <= f) {
        i += 3 + log[i + 2];
      }
      await e.replayCommands(log.sublist(start, i), f);
      stdout.writeln('frame $f: ${sw.elapsedMilliseconds} ms, units ${e.getUnits().length}');
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
