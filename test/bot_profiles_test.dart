// Bot profiles: which files a profile is made of, how a game keeps them,
// and that every shipped profile compiles in the engine (which needs the
// bridge built: engine/bridge/build/libbwbridge.so).

import 'dart:io';

import 'package:brood/engine/bw_engine.dart';
import 'package:brood/game/bot_profiles.dart';
import 'package:brood/game/game_setup.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, String> _shipped() {
  final dir = Directory('assets/bots');
  return {
    for (final f in dir.listSync(recursive: true).whereType<File>())
      if (f.path.endsWith('.bot')) f.path.substring(dir.path.length + 1): f.readAsStringSync(),
  };
}

void main() {
  test('a profile is made of what it extends and includes', () {
    const lib = BotLibrary({
      'base/profile.bot': 'profile "Base" { description "b"; }\ninclude "more.bot";',
      'base/more.bot': 'include "lib/x.bot"; // include "lib/never.bot" is only a comment',
      'lib/x.bot': 'const X = 1;',
      'lib/never.bot': 'const Y = 2;',
      'kid/profile.bot': 'profile "A kid" {\n  extends "base";\n  description "Plays like base.";\n}',
      'other/profile.bot': 'profile "Other" { }',
      'standard/profile.bot': 'profile "Standard" { }',
    });
    expect(lib.filesOf('kid').keys.toSet(), {'kid/profile.bot', 'base/profile.bot', 'base/more.bot', 'lib/x.bot', 'lib/never.bot'});
    expect(lib.filesOf('other').keys, ['other/profile.bot']);
    expect([for (final p in lib.profiles) p.folder], ['standard', 'kid', 'base', 'other']);
    expect(lib.byFolder('kid')!.name, 'A kid');
    expect(lib.byFolder('kid')!.description, 'Plays like base.');

    final setup = lib.bundle(
      const GameSetup(
        players: [
          PlayerSetup(human: true, race: 1, bot: 'other'), // a human's is ignored
          PlayerSetup(human: false, race: 0, bot: 'base'),
          PlayerSetup(human: false, race: 3),
        ],
        alliances: AllianceMode.freeForAll,
        seed: 5,
      ),
    );
    expect(setup.botFiles.keys.toSet(), {'base/profile.bot', 'base/more.bot', 'lib/x.bot', 'lib/never.bot'});
    // Kept through resolving and saving.
    final again = GameSetup.fromJson(setup.resolved().toJson());
    expect(again.players[1].bot, 'base');
    expect(again.players[2].bot, '');
    expect(again.botFiles, setup.botFiles);
    // Older setups have none.
    expect(GameSetup.fromJson(const GameSetup(players: [PlayerSetup(human: true, race: 1)], alliances: AllianceMode.freeForAll, seed: 1).toJson()).botFiles, isEmpty);
  });

  test('the shipped profiles compile', () async {
    final lib = BotLibrary(_shipped());
    final e = await BwEngine.open();
    final folders = [for (final p in lib.profiles) p.folder];
    expect(folders, containsAll(['standard', 'rusher', 'turtle', 'loyal', 'opportunist']));
    for (final f in folders) {
      final r = e.compileBot(lib.filesOf(f), f);
      expect(r.ok, isTrue, reason: '$f: ${r.error}');
      expect(r.name, lib.byFolder(f)!.name);
      // What the library gathers is what the engine read.
      expect(r.files.toSet().difference(lib.filesOf(f).keys.toSet()), isEmpty, reason: f);
    }
    final broken = {'bad/profile.bot': 'on think {\n  attack(;\n}'};
    final r = e.compileBot(broken, 'bad');
    expect(r.ok, isFalse);
    expect(r.error, startsWith('bad/profile.bot:2:'));
    expect(e.setBotProfile(1, broken, 'bad'), isFalse);
    expect(e.setBotProfile(1, lib.filesOf('rusher'), 'rusher'), isTrue);
    expect(e.setBotProfile(1, const {}, null), isTrue);
  });
}
