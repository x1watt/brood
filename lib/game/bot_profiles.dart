// lib/game/bot_profiles.dart
//
// Bot profiles (docs/bot_profiles.md): folders of BotScript files that set
// how a computer player plays. The app ships some (assets/bots); the
// player's own go in a bots/ folder of the game data (the home server hands
// them to browsers like maps), and a file there wins over a shipped file of
// the same path. A game keeps the text of the files its profiles use
// (GameSetup.botFiles), so a saved game and every player of a multiplayer
// game play exactly the same profiles.

import 'package:flutter/services.dart';

import '../engine/bw_engine.dart';
import '../engine/models.dart';
import 'game_data.dart';
import 'game_setup.dart';

class BotProfile {
  final String folder; // "rusher"; also what GameSetup stores
  final String name;
  final String description;
  const BotProfile(this.folder, this.name, this.description);
}

class BotLibrary {
  /// Every .bot file, by path relative to the bots folder.
  final Map<String, String> files;
  const BotLibrary(this.files);

  static const String standard = 'standard';
  static const String _assets = 'assets/bots/';

  /// The shipped profiles and the player's own.
  static Future<BotLibrary> load() async {
    final files = <String, String>{};
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      for (final key in manifest.listAssets()) {
        if (key.startsWith(_assets) && key.endsWith('.bot')) files[key.substring(_assets.length)] = await rootBundle.loadString(key);
      }
    } catch (_) {
      // No asset bundle (a test without one): the player's files only.
    }
    files.addAll(await GameFiles.instance.botFiles());
    return BotLibrary(files);
  }

  /// Folders holding a profile.bot, the standard player first.
  List<BotProfile> get profiles {
    final list = <BotProfile>[];
    for (final path in files.keys) {
      final parts = path.split('/');
      if (parts.length != 2 || parts[1] != 'profile.bot') continue;
      final text = _withoutComments(files[path]!);
      final name = RegExp(r'profile\s+"([^"]*)"').firstMatch(text)?.group(1) ?? parts[0];
      final description = RegExp(r'description\s+"([^"]*)"').firstMatch(text)?.group(1) ?? '';
      list.add(BotProfile(parts[0], name, description));
    }
    list.sort((a, b) {
      if (a.folder == standard) return -1;
      if (b.folder == standard) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  static String _withoutComments(String text) => text.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '').replaceAll(RegExp(r'//[^\n]*'), '');

  BotProfile? byFolder(String folder) => profiles.where((p) => p.folder == folder).firstOrNull;

  /// The files profile [folder] is made of: its profile.bot and what it
  /// extends and includes, found the way BotScript finds them (a name that
  /// only appears in a comment adds a file, which does no harm).
  Map<String, String> filesOf(String folder) {
    final out = <String, String>{};
    void add(String path) {
      final text = files[path];
      if (text == null || out.containsKey(path)) return;
      out[path] = text;
      final dir = path.contains('/') ? path.substring(0, path.lastIndexOf('/') + 1) : '';
      for (final m in RegExp(r'\b(extends|include)\s+"([^"]*)"').allMatches(text)) {
        final name = m.group(2)!;
        if (m.group(1) == 'extends') {
          add('$name/profile.bot');
        } else {
          add(files.containsKey('$dir$name') ? '$dir$name' : name);
        }
      }
    }

    add('$folder/profile.bot');
    return out;
  }

  /// [setup] with the files of its computer players' profiles.
  GameSetup bundle(GameSetup setup) {
    final used = <String, String>{};
    for (final p in setup.players) {
      if (!p.human && p.bot.isNotEmpty) used.addAll(filesOf(p.bot));
    }
    return setup.withBotFiles(used);
  }

  static BwEngine? _checker;

  /// Compiles profile [folder]: its name, or what is wrong with it.
  Future<BotProfileReport> check(String folder) async {
    final e = _checker ??= await BwEngine.open();
    return e.compileBot(filesOf(folder), folder);
  }
}
