// Sessions of save points: creating, adding points, listing, reading back,
// and turning a save from before sessions into a session.

import 'dart:convert';

import 'package:brood/game/game_setup.dart';
import 'package:brood/game/saved_games.dart';
import 'package:brood/platform/storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MemoryStorage store;
  const setup = GameSetup(
    players: [PlayerSetup(human: true, race: 1, team: 0), PlayerSetup(human: false, race: 2, team: 0)],
    alliances: AllianceMode.freeForAll,
    seed: 7,
  );

  setUp(() => AppStorage.instance = store = MemoryStorage());

  test('a session keeps its points in time and reads them back', () async {
    final s = SaveSession.create(name: 'Lost Temple test', mapFile: '/maps/lt.scm', mapKey: 'maps/lt.scm', mapName: '(4)Lost Temple', setup: setup);
    await s.addPoint(const SavedGameData(commandLog: [1, 2, 3], frame: 1428, camX: 10, camY: 20));
    await s.addPoint(const SavedGameData(commandLog: [1, 2, 3, 4, 5], frame: 2856, camX: 30, camY: 40));
    await s.addPoint(const SavedGameData(commandLog: [9], frame: 3000, camX: 0, camY: 0), manual: true, name: 'before the attack');

    final listed = SaveSession.list();
    expect(listed, hasLength(1));
    final l = listed.single;
    expect(l.name, 'Lost Temple test');
    expect(l.points.map((p) => p.frame), [1428, 2856, 3000]);
    expect(l.latest!.manual, isTrue);
    expect(l.latest!.name, 'before the attack');
    expect(l.points.first.gameTime, '0:59');
    final data = l.readPoint(l.points[1]);
    expect(data.commandLog, [1, 2, 3, 4, 5]);
    expect(data.camX, 30);
    final launch = l.launch(l.points.first);
    expect(launch.continues, 'Lost Temple test at 0:59');
    expect(launch.setup.players, hasLength(2));
  });

  test('a save from before sessions becomes a session', () {
    store.write('saves/save_1.json', jsonEncode({
      'version': 1,
      'name': 'old save',
      'saved': '2026-10-03T13:06:25',
      'mapFile': '/maps/lt.scm',
      'mapKey': 'maps/lt.scm',
      'mapName': '(4)Lost Temple',
      'setup': setup.toJson(),
      'frame': 838,
      'camX': 1.0,
      'camY': 2.0,
      'log': base64Encode([1, 0, 0, 0]),
    }));
    final listed = SaveSession.list();
    expect(listed, hasLength(1));
    expect(listed.single.name, 'old save');
    expect(listed.single.points.single.frame, 838);
    expect(listed.single.readPoint(listed.single.points.single).commandLog, [1]);
    expect(store.read('saves/save_1.json'), isNull);
  });
}
