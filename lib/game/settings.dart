// lib/game/settings.dart
//
// Player preferences kept between runs in $XDG_DATA_HOME/brood/settings.json
// (next to play_stats.json): sound volume and mute, and whether the game
// runs fullscreen. BROOD_SETTINGS_FILE overrides the location (tests).

import 'dart:convert';
import 'dart:io';

class Settings {
  final File file;
  double volume;
  bool muted;
  bool fullscreen;

  Settings._(this.file, {this.volume = 0.7, this.muted = false, this.fullscreen = false});

  static File defaultFile() {
    final env = Platform.environment;
    final override = env['BROOD_SETTINGS_FILE'];
    if (override != null && override.isNotEmpty) return File(override);
    final base = env['XDG_DATA_HOME']?.isNotEmpty == true ? env['XDG_DATA_HOME']! : '${env['HOME'] ?? '.'}/.local/share';
    return File('$base/brood/settings.json');
  }

  static Settings load([File? file]) {
    final f = file ?? defaultFile();
    try {
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        return Settings._(
          f,
          volume: ((j['volume'] as num?)?.toDouble() ?? 0.7).clamp(0.0, 1.0),
          muted: j['muted'] == true,
          fullscreen: j['fullscreen'] == true,
        );
      }
    } catch (_) {
      // Unreadable settings fall back to defaults.
    }
    return Settings._(f);
  }

  void save() {
    try {
      file.parent.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
        'volume': volume,
        'muted': muted,
        'fullscreen': fullscreen,
      }));
      tmp.renameSync(file.path);
    } catch (_) {
      // Preferences are a convenience; never let them break the game.
    }
  }
}
