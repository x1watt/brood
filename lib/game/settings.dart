// lib/game/settings.dart
//
// Player preferences kept between runs ('settings.json' in the app storage,
// lib/platform/storage.dart): sound volume and mute, fullscreen, the last
// game setup chosen on the start screen, panel side, auto-save and the
// auto-play modes, the player's name for multiplayer, whether the player
// said they have the original game files, and sharing on the network.

import 'dart:convert';

import '../platform/storage.dart';

class Settings {
  static const key = 'settings.json';

  double volume;
  bool muted;
  bool fullscreen;
  Map<String, dynamic>? lastSetup; // GameSetup.toJson() of the last new game
  bool alliancePanelLeft; // dock the alliance panel on the left
  bool autosave; // save a point in time every few minutes of play
  int autoplayModes; // what auto-play does when switched on (AutoplayMode bits)
  String playerName; // shown to the others in multiplayer games
  bool ownsGameFiles; // answered yes to "I have a copy of the original game files"
  bool shareOnNetwork; // run the home server for others at home (lib/net/lan_host.dart)

  Settings._({
    this.volume = 0.7,
    this.muted = false,
    this.fullscreen = false,
    this.lastSetup,
    this.alliancePanelLeft = false,
    this.autosave = true,
    this.autoplayModes = 15,
    this.playerName = '',
    this.ownsGameFiles = false,
    this.shareOnNetwork = false,
  });

  static Settings load() {
    try {
      final text = AppStorage.instance.read(key);
      if (text != null) {
        final j = jsonDecode(text) as Map<String, dynamic>;
        return Settings._(
          volume: ((j['volume'] as num?)?.toDouble() ?? 0.7).clamp(0.0, 1.0),
          muted: j['muted'] == true,
          fullscreen: j['fullscreen'] == true,
          lastSetup: j['lastSetup'] is Map<String, dynamic> ? j['lastSetup'] as Map<String, dynamic> : null,
          alliancePanelLeft: j['alliancePanelLeft'] == true,
          autosave: j['autosave'] != false,
          autoplayModes: ((j['autoplayModes'] as num?)?.toInt() ?? 15).clamp(1, 15),
          playerName: j['playerName'] is String ? j['playerName'] as String : '',
          ownsGameFiles: j['ownsGameFiles'] == true,
          shareOnNetwork: j['shareOnNetwork'] == true,
        );
      }
    } catch (_) {
      // Unreadable settings fall back to defaults.
    }
    return Settings._();
  }

  void save() {
    try {
      AppStorage.instance.write(key, const JsonEncoder.withIndent('  ').convert({
        'volume': volume,
        'muted': muted,
        'fullscreen': fullscreen,
        if (lastSetup != null) 'lastSetup': lastSetup,
        'alliancePanelLeft': alliancePanelLeft,
        'autosave': autosave,
        'autoplayModes': autoplayModes,
        'playerName': playerName,
        'ownsGameFiles': ownsGameFiles,
        'shareOnNetwork': shareOnNetwork,
      }));
    } catch (_) {
      // Preferences are a convenience; never let them break the game.
    }
  }
}
