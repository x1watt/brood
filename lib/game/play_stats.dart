// lib/game/play_stats.dart
//
// Per-map play time, games started and last played date ('play_stats.json'
// in the app storage, lib/platform/storage.dart), so the start screen can
// list the most played maps first. A page from a home server adds the
// server's own (the app that shares the LAN party, lib/net/home_server.dart),
// so its most played maps come first there too.

import 'dart:convert';

import '../platform/storage.dart';

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
  static const key = 'play_stats.json';
  final Map<String, MapStats> maps;

  PlayStats._(this.maps);

  static PlayStats load() => parse(AppStorage.instance.read(key));

  /// The stats of a play_stats.json text; none when it is missing or damaged.
  static PlayStats parse(String? text) {
    final maps = <String, MapStats>{};
    try {
      if (text != null) {
        final json = jsonDecode(text) as Map<String, dynamic>;
        final m = json['maps'] as Map<String, dynamic>? ?? const {};
        m.forEach((k, v) => maps[k] = MapStats.fromJson(v as Map<String, dynamic>));
      }
    } catch (_) {
      // A damaged file just starts the stats over.
    }
    return PlayStats._(maps);
  }

  /// These stats and [other]'s added up, for showing (never saved).
  PlayStats plus(PlayStats other) {
    final out = <String, MapStats>{};
    for (final e in [...maps.entries, ...other.maps.entries]) {
      final s = out.putIfAbsent(e.key, MapStats.new);
      s.seconds += e.value.seconds;
      s.games += e.value.games;
      final last = e.value.lastPlayed;
      if (last != null && (s.lastPlayed == null || last.isAfter(s.lastPlayed!))) s.lastPlayed = last;
    }
    return PlayStats._(out);
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
      AppStorage.instance.write(key, const JsonEncoder.withIndent('  ').convert({
        'maps': {for (final e in maps.entries) e.key: e.value.toJson()},
      }));
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
