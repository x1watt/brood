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
import 'bot_bundle.dart';
import 'game_data.dart';
import 'game_setup.dart';

class BotProfile {
  final String folder; // "rusher"; also what GameSetup stores
  final String name;
  final String description;
  const BotProfile(this.folder, this.name, this.description);
}

class BotLibrary {
  /// The shipped files and the player's own, by path relative to the bots
  /// folder.
  final Map<String, String> shipped;
  final Map<String, String> own;
  BotLibrary(Map<String, String> shipped, {Map<String, String>? own}) : shipped = Map.of(shipped), own = Map.of(own ?? const {});

  static final BotLibrary empty = BotLibrary(const {});

  /// Every .bot file: the player's win over shipped ones of the same path.
  Map<String, String> get files => {...shipped, ...own};

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
    return BotLibrary(files, own: await GameFiles.instance.botFiles());
  }

  /// Folders holding a profile.bot, the standard player first.
  List<BotProfile> get profiles {
    final list = <BotProfile>[];
    final all = files;
    for (final path in all.keys) {
      final parts = path.split('/');
      if (parts.length != 2 || parts[1] != 'profile.bot') continue;
      final text = _withoutComments(all[path]!);
      final name = _string(RegExp(r'profile\s+"((?:[^"\\]|\\.)*)"').firstMatch(text)?.group(1)) ?? parts[0];
      final description = _string(RegExp(r'description\s+"((?:[^"\\]|\\.)*)"').firstMatch(text)?.group(1)) ?? '';
      list.add(BotProfile(parts[0], name, description));
    }
    list.sort((a, b) {
      if (a.folder == standard) return -1;
      if (b.folder == standard) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  /// A BotScript string's text (its escapes undone).
  static String? _string(String? quoted) => quoted?.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1] == 'n' ? ' ' : m[1]!);

  static String _withoutComments(String text) => text.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '').replaceAll(RegExp(r'//[^\n]*'), '');

  BotProfile? byFolder(String folder) => profiles.where((p) => p.folder == folder).firstOrNull;

  /// The files profile [folder] is made of: its profile.bot and what it
  /// extends and includes, found the way BotScript finds them (a name that
  /// only appears in a comment adds a file, which does no harm).
  Map<String, String> filesOf(String folder) => botFilesOf(files, folder);

  /// [setup] with the files of its computer players' profiles.
  GameSetup bundle(GameSetup setup) {
    final used = <String, String>{};
    for (final p in setup.players) {
      if (!p.human && p.bot.isNotEmpty) used.addAll(filesOf(p.bot));
    }
    return setup.withBotFiles(used);
  }

  static BwEngine? _checker;
  static Future<BwEngine> _engine() async => _checker ??= await BwEngine.open();

  /// Compiles profile [folder]: its name, or what is wrong with it.
  Future<BotProfileReport> check(String folder) async => (await _engine()).compileBot(filesOf(folder), folder);

  /// The numbers a player of [folder] starts with (null: the standard ones).
  Future<BotNumbers> numbers(String? folder) async => (await _engine()).botNumbers(folder == null ? const {} : filesOf(folder), folder);

  // --- editing (lib/ui/bot_editor.dart) ---

  /// The files in [folder], profile.bot first.
  List<String> filesIn(String folder) {
    final list = [for (final p in files.keys) if (p.startsWith('$folder/')) p];
    list.sort((a, b) {
      if (a.endsWith('/profile.bot')) return -1;
      if (b.endsWith('/profile.bot')) return 1;
      return a.compareTo(b);
    });
    return list;
  }

  /// Shipped with the game and not changed by the player: edited as a copy.
  bool isBuiltIn(String folder) => !own.keys.any((p) => p.startsWith('$folder/'));

  /// The player's folder replaces a shipped one of the same name.
  bool overridesShipped(String folder) => !isBuiltIn(folder) && shipped.keys.any((p) => p.startsWith('$folder/'));

  Future<void> saveFile(String path, String text) async {
    own[path] = text;
    await GameFiles.instance.saveBotFile(path, text);
  }

  Future<void> deleteFile(String path) async {
    if (own.remove(path) != null) await GameFiles.instance.deleteBotFile(path);
  }

  /// Deletes the player's files of [folder] (a shipped profile of the same
  /// name comes back).
  Future<void> deleteProfile(String folder) async {
    for (final p in [for (final p in own.keys) if (p.startsWith('$folder/')) p]) {
      await deleteFile(p);
    }
  }

  /// A new folder name for a profile called [name]: lower case letters,
  /// digits and underscores, not taken yet.
  String folderFor(String name) {
    var base = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    if (base.isEmpty || base == 'lib') base = 'profile';
    final taken = {for (final p in files.keys) p.split('/').first};
    var folder = base;
    for (int i = 2; taken.contains(folder); ++i) {
      folder = '${base}_$i';
    }
    return folder;
  }

  /// Makes a new profile called [name]: a copy of [copyOf]'s folder, or one
  /// that plays like the standard player. Returns its folder.
  Future<String> create(String name, String description, {String? copyOf}) async {
    final folder = folderFor(name);
    if (copyOf != null) {
      for (final path in filesIn(copyOf)) {
        var text = files[path]!;
        if (path.endsWith('/profile.bot')) text = withHeader(text, name: name, description: description);
        // The path in a file's first comment line.
        final nl = text.indexOf('\n');
        final first = nl < 0 ? text : text.substring(0, nl);
        if (first.startsWith('//')) text = first.replaceAll(RegExp('(assets/)?bots/${RegExp.escape(copyOf)}/'), 'bots/$folder/') + (nl < 0 ? '' : text.substring(nl));
        await saveFile('$folder/${path.substring(copyOf.length + 1)}', text);
      }
    } else {
      await saveFile('$folder/profile.bot', newProfileText(folder, name, description));
    }
    return folder;
  }

  static String _quoted(String s) => s.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', ' ');

  static String newProfileText(String folder, String name, String description) => '''// bots/$folder/profile.bot

profile "${_quoted(name)}" {
	extends "standard";
	description "${_quoted(description)}";
}

// The numbers set in the editor's Settings tab.
include "settings.bot";

// Events decide during the game (docs/bot_profiles.md). For example, no
// attack before the eighth minute:
//
// on wave(ready) {
//	if (time < 8 * MINUTE) return false;
// }
''';

  /// [text] (a profile.bot) with its name and description replaced.
  static String withHeader(String text, {required String name, required String description}) {
    var out = text.replaceFirstMapped(RegExp(r'^(\s*profile\s+)"(?:[^"\\]|\\.)*"', multiLine: true), (m) => '${m[1]}"${_quoted(name)}"');
    final d = RegExp(r'(\bdescription\s+)"(?:[^"\\]|\\.)*"');
    out = d.hasMatch(out)
        ? out.replaceFirstMapped(d, (m) => '${m[1]}"${_quoted(description)}"')
        : out.replaceFirstMapped(RegExp(r'(\bprofile\s+"(?:[^"\\]|\\.)*"\s*\{)'), (m) => '${m[1]}\n\tdescription "${_quoted(description)}";');
    return out;
  }

  // --- the Settings tab: numbers kept in <folder>/settings.bot ---

  static final RegExp _setLine = RegExp(r'^\s*set\s+(\w+\.\w+)\s*=\s*(-?\d+)\s*;', multiLine: true);

  /// The numbers [folder]'s settings.bot sets.
  Map<String, int> settingsOf(String folder) => {
    for (final m in _setLine.allMatches(files['$folder/settings.bot'] ?? '')) m[1]!: int.parse(m[2]!),
  };

  /// Writes [values] as [folder]'s settings.bot, and makes profile.bot
  /// include it (last, so they win over its own set statements).
  Future<void> saveSettings(String folder, Map<String, int> values) async {
    final names = values.keys.toList()..sort();
    final text = StringBuffer('''// bots/$folder/settings.bot
//
// Written by the bot profile editor (Settings tab): the numbers changed
// from what the profile would play with otherwise. Times are in seconds.

''');
    for (final n in names) {
      text.writeln('set $n = ${values[n]};');
    }
    await saveFile('$folder/settings.bot', text.toString());
    final profile = '$folder/profile.bot';
    final main = files[profile] ?? '';
    if (!RegExp(r'^\s*include\s+"settings\.bot"\s*;', multiLine: true).hasMatch(main)) {
      await saveFile(profile, '${main.trimRight()}\n\n// The numbers set in the editor\'s Settings tab.\ninclude "settings.bot";\n');
    }
  }

  /// What each number means, from the standard profile's numbers.bot: by
  /// group, in order.
  List<BotNumberInfo> numberInfo() {
    final text = files['standard/numbers.bot'] ?? '';
    final out = <BotNumberInfo>[];
    var heading = '';
    var group = '';
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      final comment = line.contains('//') ? line.substring(line.indexOf('//') + 2).trim() : '';
      final sets = line.startsWith('//') ? <RegExpMatch>[] : RegExp(r'set\s+(\w+)\.(\w+)').allMatches(line).toList();
      if (sets.isEmpty) {
        // "// group" starts a group; other comment lines explain the next numbers.
        if (RegExp(r'^//\s*[a-z]+$').hasMatch(line)) {
          group = comment;
          heading = '';
        } else if (line.startsWith('//') && group.isNotEmpty) {
          heading = heading.isEmpty ? comment : '$heading $comment';
        } else if (line.isEmpty) {
          heading = '';
        }
        continue;
      }
      for (final m in sets) {
        out.add(BotNumberInfo(m[1]!, '${m[1]}.${m[2]}', [heading, comment].where((t) => t.isNotEmpty).join(' ')));
      }
      if (comment.isEmpty) continue;
      heading = '';
    }
    return out;
  }
}

class BotNumberInfo {
  final String group; // "army"
  final String name; // "army.wave_first"
  final String help;
  const BotNumberInfo(this.group, this.name, this.help);

  /// "wave first"
  String get label => name.substring(name.indexOf('.') + 1).replaceAll('_', ' ');

  /// Counted in seconds.
  bool get isTime => const {
    'balance_interval', 'gas_everywhere_after', 'base1', 'base2', 'base3', 'base4', 'colonize_after', 'next_base_delay', 'attack_refresh',
    'late_game', 'threat_hold', 'militia_time', 'air_island_after', 'silos_late_after', 'fresh', 'refresh', 'load_time', 'give_up',
    'nuke_interval', 'first_invite', 'first_invite_spread', 'open_check', 'refused_window', 'hopeless_after', 'surrender_retry',
    'betray_after', 'betray_check', 'invite_losing', 'invite_interval', 'invite_spread', 'no_pester',
  }.contains(name.substring(name.indexOf('.') + 1));
}
