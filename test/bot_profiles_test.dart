// Bot profiles: which files a profile is made of, how a game keeps them,
// and that every shipped profile compiles in the engine (which needs the
// bridge built: engine/bridge/build/libbwbridge.so).

import 'dart:io';
import 'dart:typed_data';

import 'package:brood/engine/bw_engine.dart';
import 'package:brood/game/bot_profiles.dart';
import 'package:brood/game/game_data.dart';
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
  editing();
  test('a profile is made of what it extends and includes', () {
    final lib = BotLibrary({
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

/// The player's files in memory (never the real game folder).
class _MemoryFiles extends GameFiles {
  final Map<String, String> bots = {};
  @override
  bool get ready => true;
  @override
  Future<bool> init() async => true;
  @override
  String get dataDir => '/nowhere';
  @override
  String get description => 'memory';
  @override
  List<GameMap> maps() => const [];
  @override
  bool exists(String path) => false;
  @override
  Future<String> saveMap(String relativePath, Uint8List bytes) async => relativePath;
  @override
  Future<Map<String, String>> botFiles() async => Map.of(bots);
  @override
  Future<void> saveBotFile(String relativePath, String text) async => bots[relativePath] = text;
  @override
  Future<void> deleteBotFile(String relativePath) async => bots.remove(relativePath);
}

void editing() {
  test('the editor makes, copies, sets numbers in and deletes profiles', () async {
    final files = _MemoryFiles();
    GameFiles.instance = files;
    final lib = BotLibrary(_shipped());
    final e = await BwEngine.open();
    expect(lib.isBuiltIn('rusher'), isTrue);

    // A new profile plays like the standard player and compiles.
    final mine = await lib.create('My "best" bot!', 'Mine.');
    expect(mine, 'my_best_bot');
    expect(files.bots.keys, ['my_best_bot/profile.bot']);
    expect(lib.byFolder(mine)!.name, 'My "best" bot!');
    var r = e.compileBot(lib.filesOf(mine), mine);
    expect(r.ok, isFalse, reason: 'it includes settings.bot, written on the first save');
    await lib.saveSettings(mine, {'army.wave_first': 5, 'expansion.base1': 240});
    r = e.compileBot(lib.filesOf(mine), mine);
    expect(r.ok, isTrue, reason: r.error);
    expect(lib.settingsOf(mine), {'army.wave_first': 5, 'expansion.base1': 240});
    final n = e.botNumbers(lib.filesOf(mine), mine);
    expect(n.values['army.wave_first'], 5);
    expect(n.values['expansion.base1'], 240);
    expect(n.values['army.wave_max'], e.botNumbers(const {}, null).values['army.wave_max']);
    expect(n.random, isFalse);

    // A copy keeps the original's files and gets the new name.
    final copy = await lib.create('Fast rusher', 'Faster.', copyOf: 'rusher');
    expect(lib.byFolder(copy)!.name, 'Fast rusher');
    expect(lib.byFolder(copy)!.description, 'Faster.');
    expect(lib.files['$copy/profile.bot'], startsWith('// bots/fast_rusher/profile.bot\n'));
    await lib.saveSettings(copy, {'army.wave_first': 4});
    expect(lib.files['$copy/profile.bot'], contains('include "settings.bot";'));
    r = e.compileBot(lib.filesOf(copy), copy);
    expect(r.ok, isTrue, reason: r.error);
    // Its own set statements come first, the Settings tab's win.
    expect(e.botNumbers(lib.filesOf(copy), copy).values['army.wave_first'], 4);
    expect(e.botNumbers(lib.filesOf('rusher'), 'rusher').values['army.wave_first'], 6);
    // The trust range of the loyal ally depends on nothing random; rusher's set doesn't either.
    expect(e.botNumbers(lib.filesOf('loyal'), 'loyal').values['personality.trust_min'], 70);

    // Read back from the player's files.
    final again = await BotLibrary.load();
    expect(again.isBuiltIn(copy), isFalse);
    expect(again.byFolder(mine), isNotNull);

    await lib.deleteProfile(copy);
    expect(lib.byFolder(copy), isNull);
    expect(files.bots.keys.where((k) => k.startsWith('$copy/')), isEmpty);

    // A folder named after a shipped profile replaces it, and deleting it brings that back.
    await lib.saveFile('turtle/profile.bot', 'profile "My turtle" { extends "standard"; }');
    expect(lib.overridesShipped('turtle'), isTrue);
    expect(lib.byFolder('turtle')!.name, 'My turtle');
    await lib.deleteProfile('turtle');
    expect(lib.byFolder('turtle')!.name, 'Turtle');
  });

  test('every number has a description', () {
    final info = BotLibrary(_shipped()).numberInfo();
    expect(info.length, 140);
    expect(info.map((i) => i.group).toSet(), {'personality', 'economy', 'expansion', 'army', 'defense', 'help', 'drops', 'spells', 'diplomacy'});
    final wave = info.firstWhere((i) => i.name == 'army.wave_first');
    expect(wave.help, contains('first attack wave'));
    expect(info.firstWhere((i) => i.name == 'expansion.base1').isTime, isTrue);
    expect(wave.isTime, isFalse);
  });

  test('a header is replaced, or a description added', () {
    expect(
      BotLibrary.withHeader('// profile "x"\nprofile "A" {\n\textends "standard";\n}', name: 'B', description: 'New'),
      '// profile "x"\nprofile "B" {\n\tdescription "New";\n\textends "standard";\n}',
    );
    expect(BotLibrary.withHeader('profile "A" { description "old"; }', name: 'A', description: 'n"ew'), 'profile "A" { description "n\\"ew"; }');
  });
}
