// lib/game/settings.dart
//
// Player preferences kept between runs in $XDG_DATA_HOME/brood/settings.json
// (next to play_stats.json): sound volume and mute, whether the game runs
// fullscreen, and the last game setup chosen on the start screen.
// BROOD_SETTINGS_FILE overrides the location (tests).

import 'dart:convert';
import 'dart:io';

class Settings {
  final File file;
  double volume;
  bool muted;
  bool fullscreen;
  Map<String, dynamic>? lastSetup; // GameSetup.toJson() of the last new game
  bool alliancePanelLeft; // dock the alliance panel on the left
  bool autosave; // save a point in time every few minutes of play

  Settings._(this.file, {this.volume = 0.7, this.muted = false, this.fullscreen = false, this.lastSetup, this.alliancePanelLeft = false, this.autosave = true});

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
          lastSetup: j['lastSetup'] is Map<String, dynamic> ? j['lastSetup'] as Map<String, dynamic> : null,
          alliancePanelLeft: j['alliancePanelLeft'] == true,
          autosave: j['autosave'] != false,
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
        if (lastSetup != null) 'lastSetup': lastSetup,
        'alliancePanelLeft': alliancePanelLeft,
        'autosave': autosave,
      }));
      tmp.renameSync(file.path);
    } catch (_) {
      // Preferences are a convenience; never let them break the game.
    }
  }
}
