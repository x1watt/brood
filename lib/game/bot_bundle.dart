// lib/game/bot_bundle.dart
//
// Which bot profile files a profile is made of (docs/bot_profiles.md), in
// plain Dart so command-line tools (tool/brood_agent.dart) share it with
// the app (lib/game/bot_profiles.dart).

/// The files profile [folder] is made of, out of [files] (by path relative
/// to the bots folder): its profile.bot and what it extends and includes,
/// found the way BotScript finds them (a name that only appears in a
/// comment adds a file, which does no harm).
Map<String, String> botFilesOf(Map<String, String> files, String folder) {
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
