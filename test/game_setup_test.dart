// Starting alliances respect the three-member cap for every player count
// and seed.

import 'package:brood/game/game_setup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starting alliances have at most three members', () {
    for (final mode in [AllianceMode.randomTeams, AllianceMode.allAgainstYou]) {
      for (int n = 2; n <= GameSetup.maxPlayers; ++n) {
        for (int seed = 1; seed <= 50; ++seed) {
          final setup = GameSetup(
            players: [for (int i = 0; i < n; ++i) PlayerSetup(human: i == 0, race: 0)],
            alliances: mode,
            seed: seed,
          ).resolved();
          final sizes = <int, int>{};
          for (final p in setup.players) {
            sizes[p.team] = (sizes[p.team] ?? 0) + 1;
          }
          expect(sizes.values.every((v) => v <= GameSetup.maxAllianceSize), isTrue, reason: '$mode, $n players: $sizes');
          if (mode == AllianceMode.allAgainstYou) {
            // You stand alone.
            expect(setup.players.where((p) => p.team == setup.players[0].team).length, 1);
          } else {
            expect(sizes.length, greaterThanOrEqualTo(2));
          }
        }
      }
    }
  });
}
