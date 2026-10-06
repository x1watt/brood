// What an assistant (tool/brood_agent.dart) may send for the player it
// assists (tool/brood_server.dart, docs/agent_api.md).

import 'package:flutter_test/flutter_test.dart';

import '../tool/brood_server.dart' as server;

void main() {
  test('assistants command only their player, as far as allowed', () {
    final steer = [0, server.opBotSteer, 4, 3, 1, 0, 0];
    final autoplay = [0, server.opAutoplay, 2, 3, 15];
    final order = [0, 2, 6, 3, 1, 100, 100, 0, 0];
    // Advice only: nothing.
    expect(server.assistantMay(0, 3, steer), isFalse);
    // Steering: the auto-play and its direction, nothing else.
    expect(server.assistantMay(1, 3, [...steer, ...autoplay]), isTrue);
    expect(server.assistantMay(1, 3, [...steer, ...order]), isFalse);
    // Everything for its own player...
    expect(server.assistantMay(2, 3, [...order, ...steer]), isTrue);
    // ...but not for another one, nor the game's settings.
    expect(server.assistantMay(2, 4, order), isFalse);
    expect(server.assistantMay(2, 3, [0, server.opSetController, 2, 3, 1]), isFalse);
    expect(server.assistantMay(2, 3, [0, 28, 1, 3]), isFalse);
    // Broken entries and empty batches.
    expect(server.assistantMay(2, 3, [0, 2, 9, 3]), isFalse);
    expect(server.assistantMay(2, 3, [0, 2]), isFalse);
    expect(server.assistantMay(2, 3, const []), isFalse);
  });
}
