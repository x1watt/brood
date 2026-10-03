// lib/game/play_stats.dart
//
// Per-map play time, games started and last played date, kept in
// $XDG_DATA_HOME/brood/play_stats.json (default ~/.local/share/brood/) so
// the start screen can list the most played maps first. BROOD_STATS_FILE
// overrides the location (used by tests).

import 'dart:convert';
import 'dart:io';

class MapStats {
  int seconds;
  int games;
  DateTime? lastPlayed;
  MapStats({this.seconds = 0, this.games = 0, this.lastPlayed});

  Map<String, dynamic> toJson() => {
    'seconds': seconds,
    'games': games,
    if (lastPlayed != null) 'lastPlayed': lastPlayed!.toIso8601String(),
  };

  static MapStats fromJson(Map<String, dynamic> j) => MapStats(
    seconds: (j['seconds'] as num?)?.toInt() ?? 0,
    games: (j['games'] as num?)?.toInt() ?? 0,
    lastPlayed: j['lastPlayed'] is String ? DateTime.tryParse(j['lastPlayed'] as String) : null,
  );
}

class PlayStats {
  final File file;
  final Map<String, MapStats> maps;

  PlayStats._(this.file, this.maps);

  static File defaultFile() {
    final env = Platform.environment;
    final override = env['BROOD_STATS_FILE'];
    if (override != null && override.isNotEmpty) return File(override);
    final base = env['XDG_DATA_HOME']?.isNotEmpty == true ? env['XDG_DATA_HOME']! : '${env['HOME'] ?? '.'}/.local/share';
    return File('$base/brood/play_stats.json');
  }

  static PlayStats load([File? file]) {
    final f = file ?? defaultFile();
    final maps = <String, MapStats>{};
    try {
      if (f.existsSync()) {
        final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final m = json['maps'] as Map<String, dynamic>? ?? const {};
        m.forEach((k, v) => maps[k] = MapStats.fromJson(v as Map<String, dynamic>));
      }
    } catch (_) {
      // A damaged file just starts the stats over.
    }
    return PlayStats._(f, maps);
  }

  MapStats of(String mapKey) => maps.putIfAbsent(mapKey, MapStats.new);

  void gameStarted(String mapKey) {
    final s = of(mapKey);
    s.games++;
    s.lastPlayed = DateTime.now();
    save();
  }

  void addPlayed(String mapKey, int seconds) {
    if (seconds <= 0) return;
    final s = of(mapKey);
    s.seconds += seconds;
    s.lastPlayed = DateTime.now();
    save();
  }

  void save() {
    try {
      file.parent.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
        'maps': {for (final e in maps.entries) e.key: e.value.toJson()},
      }));
      tmp.renameSync(file.path);
    } catch (_) {
      // Stats are a convenience; never let them break the game.
    }
  }

  /// "under a minute", "45m", "3h 12m", "2d 5h".
  static String formatDuration(int seconds) {
    if (seconds < 60) return 'under a minute';
    final minutes = seconds ~/ 60;
    if (minutes < 60) return '${minutes}m';
    final hours = minutes ~/ 60;
    if (hours < 24) return '${hours}h ${minutes % 60}m';
    return '${hours ~/ 24}d ${hours % 24}h';
  }
}
