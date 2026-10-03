// lib/game/game_controller.dart
//
// Owns the engine and all game-screen state: frame pacing, camera,
// selection, command modes and building placement. Widgets only forward
// input here and read state back.
//
// Two notifiers so the widget tree isn't rebuilt every frame: `repaint`
// fires when the world view must be redrawn (sim step or camera move) and
// only drives CustomPaint repaints; `hud` fires at most ~10x/s, or right
// away on selection/mode changes, and drives the panels.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../engine/bw_engine_io.dart';
import '../engine/models.dart';
import '../rendering/sprite_atlas.dart';
import '../rendering/terrain_layer.dart';

enum CommandMode { none, move, attack, patrol, build }

class GameController {
  static const int myPlayer = 0;
  static const int myRace = 1; // terran
  static const int neutralPlayer = 11;
  // Brood War's "Fastest" game speed: one simulation frame every 42 ms.
  static const int frameMicros = 42000;
  static const double edgeScrollMargin = 14;
  static const double scrollSpeed = 900; // map pixels per second

  final Signal repaint = Signal();
  final Signal hud = Signal();

  BwEngine? _engine;
  SpriteAtlas? atlas;
  TerrainLayer? terrain;
  String? error;
  bool get ready => _engine != null && terrain != null && atlas != null;
  BwEngine get engine => _engine!;

  // Camera: map-pixel position of the viewport's top-left corner.
  double camX = 0;
  double camY = 0;
  Size viewport = Size.zero;
  final Set<_Scroll> _keyScroll = {};
  Offset? pointer; // last known pointer position over the viewport, screen space
  bool pointerInside = false;

  List<DrawItem> drawItems = const [];
  List<UnitInfo> units = const [];
  Map<int, UnitInfo> unitsById = const {};
  List<int> selection = const [];
  int minerals = 0;
  int gas = 0;
  double supplyUsed = 0;
  double supplyMax = 0;
  int frame = 0;

  CommandMode mode = CommandMode.none;
  int? buildTypeId;
  Rect? dragBox; // screen space

  String? message;
  int _messageUntilMs = 0;

  Duration? _lastTick;
  int _accMicros = 0;
  int _lastHudMs = 0;

  // --- startup ---

  Future<void> start({required String dataDir, required String mapFile}) async {
    try {
      final e = BwEngine.open();
      e.loadAssets(dataDir);
      e.newMeleeGame(mapFile, playerSlot: myPlayer, race: myRace);
      e.step(1);
      _engine = e;
      atlas = SpriteAtlas(e);
      terrain = await TerrainLayer.build(e);
      _refreshUnits();
      _startWorkersMining();
      _centerOnHome();
      _refreshView();
    } catch (err, st) {
      error = '$err';
      debugPrint('GameController.start failed: $err\n$st');
    }
    _notifyHud(force: true);
    repaint.fire();
  }

  void dispose() {
    _engine?.dispose();
    repaint.dispose();
    hud.dispose();
  }

  // Classic melee starts with idle workers; send each to its nearest mineral
  // patch through the engine's own right-click handling, as a player would.
  void _startWorkersMining() {
    final minerals = units.where((u) => u.isResource && u.typeId >= 176 && u.typeId <= 178).toList();
    if (minerals.isEmpty) return;
    for (final w in units.where((u) => u.owner == myPlayer && u.isWorker)) {
      var best = minerals.first;
      var bestD = -1;
      for (final m in minerals) {
        final dx = m.x - w.x, dy = m.y - w.y;
        final d = dx * dx + dy * dy;
        if (bestD < 0 || d < bestD) {
          bestD = d;
          best = m;
        }
      }
      engine.selectUnits(myPlayer, [w.unitId]);
      engine.order(myPlayer, UnitOrder.smart, best.x, best.y, targetUnitId: best.unitId);
    }
    engine.selectUnits(myPlayer, const []);
  }

  Offset? _pendingCenter;

  // The viewport size isn't known until first layout, so the home position
  // is remembered and applied in setViewport.
  void _centerOnHome() {
    final own = units.where((u) => u.owner == myPlayer).toList();
    if (own.isEmpty) return;
    final home = own.firstWhere((u) => u.isBuilding, orElse: () => own.first);
    if (viewport.isEmpty) {
      _pendingCenter = Offset(home.x.toDouble(), home.y.toDouble());
    } else {
      centerOn(home.x.toDouble(), home.y.toDouble());
    }
  }

  // --- frame loop ---

  /// Called from a vsync Ticker. Steps the simulation at a fixed 42 ms per
  /// frame regardless of display refresh rate, and redraws only when
  /// something changed.
  void tick(Duration elapsed) {
    if (!ready) return;
    final last = _lastTick ?? elapsed;
    _lastTick = elapsed;
    final dtMicros = (elapsed - last).inMicroseconds.clamp(0, 250000);

    var changed = _applyScroll(dtMicros / 1e6);

    _accMicros += dtMicros;
    var steps = _accMicros ~/ frameMicros;
    if (steps > 0) {
      if (steps > 6) steps = 6; // don't spiral after a stall
      _accMicros -= steps * frameMicros;
      if (_accMicros > frameMicros) _accMicros = 0;
      engine.step(steps);
      _refreshUnits();
      changed = true;
    }

    if (changed) {
      _refreshView();
      repaint.fire();
    }
    _notifyHud();
  }

  void _refreshUnits() {
    units = engine.getUnits();
    unitsById = {for (final u in units) u.unitId: u};
    selection = engine.getSelectedUnits(myPlayer);
    minerals = engine.minerals(myPlayer);
    gas = engine.gas(myPlayer);
    final (used, max) = engine.supply(myPlayer, myRace);
    supplyUsed = used;
    supplyMax = max;
    frame = engine.currentFrame;
  }

  void _refreshView() {
    if (viewport.isEmpty) return;
    drawItems = engine.getDrawList(
      myPlayer,
      camX.floor(),
      camY.floor(),
      viewport.width.ceil(),
      viewport.height.ceil(),
    );
  }

  void _notifyHud({bool force = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastHudMs < 100) return;
    _lastHudMs = now;
    if (message != null && now > _messageUntilMs) message = null;
    hud.fire();
  }

  void _changed() {
    if (!ready) return;
    _refreshView();
    repaint.fire();
    _notifyHud(force: true);
  }

  // --- camera ---

  Size get mapSize => terrain == null
      ? Size.zero
      : Size(terrain!.widthPx.toDouble(), terrain!.heightPx.toDouble());

  void setViewport(Size size) {
    if (size == viewport) return;
    final firstLayout = viewport.isEmpty;
    final center = Offset(camX + viewport.width / 2, camY + viewport.height / 2);
    viewport = size;
    final pending = _pendingCenter;
    if (pending != null) {
      _pendingCenter = null;
      camX = pending.dx - size.width / 2;
      camY = pending.dy - size.height / 2;
    } else if (!firstLayout) {
      // Keep the same spot centered when the window is resized.
      camX = center.dx - size.width / 2;
      camY = center.dy - size.height / 2;
    }
    _clampCamera();
    if (ready) {
      _refreshView();
      repaint.fire();
    }
  }

  void _clampCamera() {
    final m = mapSize;
    if (m.isEmpty) return;
    camX = camX.clamp(0.0, math.max(0.0, m.width - viewport.width));
    camY = camY.clamp(0.0, math.max(0.0, m.height - viewport.height));
  }

  void centerOn(double mapX, double mapY) {
    camX = mapX - viewport.width / 2;
    camY = mapY - viewport.height / 2;
    _clampCamera();
    _changed();
  }

  void panBy(double dx, double dy) {
    camX += dx;
    camY += dy;
    _clampCamera();
    _changed();
  }

  void setKeyScroll(int dx, int dy, bool down) {
    final s = _Scroll(dx, dy);
    if (down) {
      _keyScroll.add(s);
    } else {
      _keyScroll.remove(s);
    }
  }

  bool _applyScroll(double dt) {
    double dx = 0, dy = 0;
    for (final s in _keyScroll) {
      dx += s.dx;
      dy += s.dy;
    }
    final p = pointer;
    if (pointerInside && p != null && dragBox == null && !viewport.isEmpty) {
      if (p.dx <= edgeScrollMargin) dx -= 1;
      if (p.dx >= viewport.width - edgeScrollMargin) dx += 1;
      if (p.dy <= edgeScrollMargin) dy -= 1;
      if (p.dy >= viewport.height - edgeScrollMargin) dy += 1;
    }
    if (dx == 0 && dy == 0) return false;
    final oldX = camX, oldY = camY;
    camX += dx.sign * scrollSpeed * dt;
    camY += dy.sign * scrollSpeed * dt;
    _clampCamera();
    return camX != oldX || camY != oldY;
  }

  Offset screenToMap(Offset screen) => Offset(screen.dx + camX, screen.dy + camY);

  // --- messages ---

  void showMessage(String text) {
    message = text;
    _messageUntilMs = DateTime.now().millisecondsSinceEpoch + 2500;
    _notifyHud(force: true);
  }

  // --- selection ---

  List<UnitInfo> get selectedUnits =>
      [for (final id in selection) if (unitsById[id] != null) unitsById[id]!];

  bool get selectionIsMine => selection.isNotEmpty && selectedUnits.every((u) => u.owner == myPlayer);

  void select(List<int> ids) {
    engine.selectUnits(myPlayer, ids.take(12).toList());
    selection = engine.getSelectedUnits(myPlayer);
    if (mode != CommandMode.none) cancelMode();
    _changed();
  }

  void clickSelect(Offset screen, {bool add = false}) {
    final p = screenToMap(screen);
    final id = engine.pickUnitAt(p.dx.round(), p.dy.round());
    if (id == 0) {
      if (!add) select(const []);
      return;
    }
    final u = unitsById[id];
    if (add && u != null && u.owner == myPlayer && selectionIsMine) {
      final next = [...selection];
      if (next.contains(id)) {
        next.remove(id);
      } else {
        next.add(id);
      }
      select(next);
    } else {
      select([id]);
    }
  }

  void boxSelect(Rect screenRect, {bool add = false}) {
    final r = Rect.fromPoints(screenToMap(screenRect.topLeft), screenToMap(screenRect.bottomRight));
    final hit = units.where((u) {
      if (u.owner != myPlayer) return false;
      final ur = Rect.fromCenter(center: Offset(u.x.toDouble(), u.y.toDouble()), width: u.width.toDouble(), height: u.height.toDouble());
      return ur.overlaps(r);
    }).toList();
    // Like the original: a box with units in it ignores buildings.
    final mobile = hit.where((u) => !u.isBuilding).toList();
    final chosen = (mobile.isNotEmpty ? mobile : hit.take(1)).map((u) => u.unitId).toList();
    if (add && selectionIsMine) {
      select({...selection, ...chosen}.toList());
    } else {
      select(chosen);
    }
  }

  void selectAllOfTypeOnScreen(int typeId) {
    final r = Rect.fromLTWH(camX, camY, viewport.width, viewport.height);
    select(units
        .where((u) => u.owner == myPlayer && u.typeId == typeId && r.contains(Offset(u.x.toDouble(), u.y.toDouble())))
        .map((u) => u.unitId)
        .toList());
  }

  // --- commands ---

  void setMode(CommandMode m) {
    if (!selectionIsMine) return;
    mode = m;
    buildTypeId = null;
    _notifyHud(force: true);
    repaint.fire();
  }

  void cancelMode() {
    mode = CommandMode.none;
    buildTypeId = null;
    _notifyHud(force: true);
    repaint.fire();
  }

  /// Right click in the world: the original game's context command.
  void smartCommand(Offset mapPos, {bool queue = false}) {
    if (mode != CommandMode.none) {
      cancelMode();
      return;
    }
    if (!selectionIsMine) return;
    final x = mapPos.dx.round(), y = mapPos.dy.round();
    final target = engine.pickUnitAt(x, y);
    engine.order(myPlayer, UnitOrder.smart, x, y, targetUnitId: target, queue: queue);
    _changed();
  }

  /// Left click while a targeted command (attack/move/patrol/build) is armed.
  void modeClick(Offset mapPos, {bool queue = false}) {
    final x = mapPos.dx.round(), y = mapPos.dy.round();
    switch (mode) {
      case CommandMode.move:
      case CommandMode.attack:
      case CommandMode.patrol:
        final order = switch (mode) {
          CommandMode.move => UnitOrder.move,
          CommandMode.attack => UnitOrder.attack,
          _ => UnitOrder.patrol,
        };
        final target = order == UnitOrder.patrol ? 0 : engine.pickUnitAt(x, y);
        engine.order(myPlayer, order, x, y, targetUnitId: target, queue: queue);
        if (!queue) cancelMode();
      case CommandMode.build:
        final type = buildTypeId;
        if (type == null) return;
        final (tx, ty) = placementTile(mapPos, type);
        if (!_canAfford(engine.unitType(type), checkSupply: false)) return;
        if (engine.build(myPlayer, type, tx, ty)) {
          if (!queue) cancelMode();
        } else {
          showMessage("Can't build there.");
        }
      case CommandMode.none:
        break;
    }
    _changed();
  }

  void instantOrder(UnitOrder order) {
    if (!selectionIsMine) return;
    engine.order(myPlayer, order, 0, 0);
    _changed();
  }

  /// Production / build-menu button for unit type [typeId].
  void produce(int typeId) {
    if (!selectionIsMine || selection.length != 1) return;
    final t = engine.unitType(typeId);
    final builder = selectedUnits.first;
    final placesBuilding = t.isBuilding && !t.isAddon && builder.isWorker;
    if (!_canAfford(t, checkSupply: !t.isBuilding)) return;
    if (placesBuilding) {
      mode = CommandMode.build;
      buildTypeId = typeId;
      _notifyHud(force: true);
      repaint.fire();
      return;
    }
    if (!engine.train(myPlayer, typeId)) {
      showMessage('Unable to build ${t.shortName} right now.');
    }
    _refreshUnits();
    _changed();
  }

  bool _canAfford(UnitTypeInfo t, {required bool checkSupply}) {
    if (minerals < t.mineralCost) {
      showMessage('Not enough minerals.');
      return false;
    }
    if (gas < t.gasCost) {
      showMessage('Not enough Vespene gas.');
      return false;
    }
    if (checkSupply && t.supply > 0 && supplyUsed + t.supply > supplyMax) {
      showMessage('You must construct additional Supply Depots.');
      return false;
    }
    return true;
  }

  void cancelLast() {
    if (!selectionIsMine || selection.length != 1) return;
    engine.cancelLast(myPlayer);
    _refreshUnits();
    _changed();
  }

  /// Top-left tile for a building of [typeId] centered under [mapPos].
  (int, int) placementTile(Offset mapPos, int typeId) {
    final t = engine.unitType(typeId);
    final tx = ((mapPos.dx - t.placementWidth / 2) / 32).round();
    final ty = ((mapPos.dy - t.placementHeight / 2) / 32).round();
    return (tx, ty);
  }

  bool canPlaceAt(int typeId, int tx, int ty) => engine.canPlace(myPlayer, typeId, tx, ty);
}

/// A ChangeNotifier anyone can trigger.
class Signal extends ChangeNotifier {
  void fire() => notifyListeners();
}

class _Scroll {
  final int dx;
  final int dy;
  const _Scroll(this.dx, this.dy);
  @override
  bool operator ==(Object other) => other is _Scroll && other.dx == dx && other.dy == dy;
  @override
  int get hashCode => dx * 3 + dy;
}
