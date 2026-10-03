// lib/game/game_controller.dart
//
// Ties the engine (BwEngine), the sprite atlas, and a frame clock together.
// v0: Linux desktop only, hardcoded to the user's real install + Lost
// Temple, stepping continuously. No input/HUD yet (Phase 6).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../engine/bw_engine_io.dart';
import '../engine/sprite_info.dart';
import '../rendering/sprite_atlas.dart';

class GameController extends ChangeNotifier {
  late final BwEngine engine;
  late final SpriteAtlas atlas;
  Timer? _timer;
  List<SpriteInfo> sprites = const [];
  String? error;

  void start({required String dataDir, required String mapFile}) {
    try {
      engine = BwEngine.open();
      engine.loadAssets(dataDir);
      engine.newMeleeGame(mapFile, playerSlot: 0, race: 1);
      atlas = SpriteAtlas(engine);

      // ~Brood War's own tick rate in the "fastest" game speed is roughly
      // 24 logical frames/sec; stepping 1 frame per timer tick at ~42ms is
      // a reasonable first approximation, not yet speed-matched precisely.
      _timer = Timer.periodic(const Duration(milliseconds: 42), (_) {
        engine.step(1);
        sprites = engine.getVisibleSprites();
        notifyListeners();
      });
    } catch (e, st) {
      error = '$e';
      if (kDebugMode) {
        stderr.writeln('GameController.start failed: $e\n$st');
      }
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
