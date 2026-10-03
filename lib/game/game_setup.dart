// lib/game/game_setup.dart
//
// What the start screen decides before a game: who plays (you plus up to
// seven computer opponents), their races and how they are allied. The
// engine only ever sees a resolved setup (no "random" left in it), which is
// also what a saved game stores so loading recreates the same game.

import 'dart:math' as math;

const List<String> raceNames = ['Zerg', 'Terran', 'Protoss'];
const int randomRace = 3;

String raceName(int race) => race >= 0 && race < 3 ? raceNames[race] : 'Random';

enum AllianceMode {
  freeForAll('Free for all', 'Everyone fights everyone.'),
  allAgainstYou('All against you', 'The computer players are allied against you.'),
  randomTeams('Random teams', 'Players are split into two random teams.');

  final String label;
  final String description;
  const AllianceMode(this.label, this.description);
}

class PlayerSetup {
  final bool human;
  final int race; // 0 zerg, 1 terran, 2 protoss, 3 random (before resolving)
  final int team; // 0 = no team; equal teams are allied

  const PlayerSetup({required this.human, required this.race, this.team = 0});

  PlayerSetup copyWith({int? race, int? team}) => PlayerSetup(human: human, race: race ?? this.race, team: team ?? this.team);

  Map<String, dynamic> toJson() => {'human': human, 'race': race, 'team': team};

  static PlayerSetup fromJson(Map<String, dynamic> j) =>
      PlayerSetup(human: j['human'] == true, race: (j['race'] as num).toInt(), team: (j['team'] as num?)?.toInt() ?? 0);
}

class GameSetup {
  static const int maxPlayers = 8;

  /// The human player first, then the computer opponents.
  final List<PlayerSetup> players;
  final AllianceMode alliances;
  final int seed;

  const GameSetup({required this.players, required this.alliances, required this.seed});

  bool get isResolved => players.every((p) => p.race >= 0 && p.race < 3);

  /// Random races and random teams fixed by the seed; teams filled in from
  /// the alliance mode.
  GameSetup resolved() {
    final rng = math.Random(seed);
    final races = [for (final p in players) p.race >= 0 && p.race < 3 ? p.race : rng.nextInt(3)];
    final teams = List<int>.filled(players.length, 0);
    switch (alliances) {
      case AllianceMode.freeForAll:
        break;
      case AllianceMode.allAgainstYou:
        for (int i = 0; i < players.length; ++i) {
          teams[i] = players[i].human ? 1 : 2;
        }
      case AllianceMode.randomTeams:
        final order = List<int>.generate(players.length, (i) => i)..shuffle(rng);
        for (int k = 0; k < order.length; ++k) {
          teams[order[k]] = k.isEven ? 1 : 2;
        }
    }
    return GameSetup(
      players: [for (int i = 0; i < players.length; ++i) PlayerSetup(human: players[i].human, race: races[i], team: teams[i])],
      alliances: alliances,
      seed: seed,
    );
  }

  Map<String, dynamic> toJson() => {
    'players': [for (final p in players) p.toJson()],
    'alliances': alliances.name,
    'seed': seed,
  };

  static GameSetup fromJson(Map<String, dynamic> j) => GameSetup(
    players: [for (final p in j['players'] as List) PlayerSetup.fromJson(p as Map<String, dynamic>)],
    alliances: AllianceMode.values.firstWhere((m) => m.name == j['alliances'], orElse: () => AllianceMode.freeForAll),
    seed: (j['seed'] as num).toInt(),
  );

  static int newSeed() => DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
}

/// Everything needed to open the game screen: a new game, or a saved one.
class GameLaunch {
  final String mapFile;
  final String mapKey; // map path relative to the game data folder
  final String mapName;
  final GameSetup setup; // resolved
  final SavedGameData? saved;
  final String continues; // for a loaded game: which session and point it carries on from

  const GameLaunch({required this.mapFile, required this.mapKey, required this.mapName, required this.setup, this.saved, this.continues = ''});
}

/// The parts of a saved game the engine replays.
class SavedGameData {
  final List<int> commandLog;
  final int frame;
  final double camX;
  final double camY;
  const SavedGameData({required this.commandLog, required this.frame, required this.camX, required this.camY});
}
