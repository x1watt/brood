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
import '../rendering/terrain_layer.dart';

class GameController extends ChangeNotifier {
  static const int myPlayer = 0;
  static const int myRace = 1; // terran

  late final BwEngine engine;
  late final SpriteAtlas atlas;
  TerrainLayer? terrain;
  Timer? _timer;
  List<SpriteInfo> sprites = const [];
  List<int> selectedUnitIds = const [];
  double suppliesUsed = 0;
  double suppliesAvailable = 0;
  String? error;

  Future<void> start({required String dataDir, required String mapFile}) async {
    try {
      engine = BwEngine.open();
      engine.loadAssets(dataDir);
      engine.newMeleeGame(mapFile, playerSlot: 0, race: 1);
      atlas = SpriteAtlas(engine);

      terrain = await TerrainLayer.build(engine);
      notifyListeners();

      // ~Brood War's own tick rate in the "fastest" game speed is roughly
      // 24 logical frames/sec; stepping 1 frame per timer tick at ~42ms is
      // a reasonable first approximation, not yet speed-matched precisely.
      _timer = Timer.periodic(const Duration(milliseconds: 42), (_) {
        engine.step(1);
        sprites = engine.getVisibleSprites();
        selectedUnitIds = engine.getSelectedUnits(myPlayer);
        final (used, available) = engine.supply(myPlayer, myRace);
        suppliesUsed = used;
        suppliesAvailable = available;
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

  /// Selects the single unit at (x, y), or clears the selection if there's
  /// none there.
  void selectAt(int x, int y) {
    final id = engine.pickUnitAt(x, y);
    engine.selectUnits(myPlayer, id == 0 ? const [] : [id]);
  }

  /// Box-select: every currently-visible own-player unit whose position
  /// falls in the given map-space rectangle.
  void selectBox(int left, int top, int right, int bottom) {
    final lo = left < right ? left : right;
    final hi = left < right ? right : left;
    final topY = top < bottom ? top : bottom;
    final botY = top < bottom ? bottom : top;
    final ids = sprites
        .where((s) => s.owner == myPlayer && s.unitId != 0)
        .where((s) => s.x >= lo && s.x <= hi && s.y >= topY && s.y <= botY)
        .map((s) => s.unitId)
        .toSet()
        .toList();
    engine.selectUnits(myPlayer, ids);
  }

  /// Right-click "smart command" at (x, y) for the current selection.
  void commandAt(int x, int y) {
    final targetId = engine.pickUnitAt(x, y);
    engine.orderRightClick(myPlayer, x, y, targetUnitId: targetId);
  }

  void stop() => engine.orderStop(myPlayer);

  void train(int unitTypeId) => engine.train(myPlayer, unitTypeId);

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
