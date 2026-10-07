// The home server the app runs when it shares the game on the network
// (lib/net/home_server.dart): pages, the game files and the home.json that
// tells a page where it came from, and the play time per map.

import 'dart:convert';
import 'dart:io';

import 'package:brood/game/play_stats.dart';
import 'package:brood/net/home_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('serves the page, home.json and the game files', () async {
    final tmp = await Directory.systemTemp.createTemp('brood_home_server');
    addTearDown(() => tmp.delete(recursive: true));
    final web = await Directory('${tmp.path}/web').create();
    await File('${web.path}/index.html').writeAsString('<html>brood</html>');
    final data = await Directory('${tmp.path}/data/maps').create(recursive: true);
    for (final a in ['StarDat.mpq', 'BrooDat.mpq', 'Patch_rt.mpq']) {
      await File('${data.parent.path}/$a').writeAsString(a);
    }
    await File('${data.path}/(2)Test.scm').writeAsString('map');

    final stats = File('${tmp.path}/play_stats.json');
    await stats.writeAsString('{"maps": {"maps/(2)Test.scm": {"seconds": 600, "games": 2}}}');
    final server = await HomeServer.start(web: web, data: data.parent, stats: stats, port: 0);
    addTearDown(server.close);
    final client = HttpClient();
    addTearDown(client.close);
    Future<(int, String)> get(String path) async {
      final r = await (await client.get('127.0.0.1', server.port, path)).close();
      return (r.statusCode, await r.transform(utf8.decoder).join());
    }

    expect(await get('/'), (200, '<html>brood</html>'));
    expect((await get('/home.json')).$1, 200);
    final (status, manifest) = await get('/gamedata/manifest.json');
    expect(status, 200);
    expect(jsonDecode(manifest), containsAll(['StarDat.mpq', 'BrooDat.mpq', 'Patch_rt.mpq', 'maps/(2)Test.scm']));
    expect(await get('/gamedata/StarDat.mpq'), (200, 'StarDat.mpq'));
    expect((await get('/../etc/passwd')).$1, 404);
    expect(await get('/playstats.json'), (200, await stats.readAsString()));
  });

  test('a page adds the server\'s play time to its own', () {
    final mine = PlayStats.parse('{"maps": {"a": {"seconds": 60, "games": 1, "lastPlayed": "2026-01-02T00:00:00"}}}');
    final home = PlayStats.parse('{"maps": {"a": {"seconds": 30, "games": 2, "lastPlayed": "2026-03-01T00:00:00"}, "b": {"seconds": 5, "games": 1}}}');
    final both = mine.plus(home);
    expect(both.maps['a']!.seconds, 90);
    expect(both.maps['a']!.games, 3);
    expect(both.maps['a']!.lastPlayed, DateTime(2026, 3, 1));
    expect(both.maps['b']!.seconds, 5);
    expect(mine.maps['a']!.seconds, 60); // the player's own stay as they are
    expect(PlayStats.parse('not json').maps, isEmpty);
  });
}
