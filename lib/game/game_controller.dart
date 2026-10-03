// lib/game/game_controller.dart
//
// Owns the engine and all game-screen state: frame pacing, camera,
// selection, command card and hotkeys, control groups, command feedback
// markers, sound. Widgets only forward input here and read state back.
//
// Two notifiers so the widget tree isn't rebuilt every frame: `repaint`
// fires when the world view must be redrawn (sim step or camera move) and
// only drives CustomPaint repaints; `hud` fires at most ~10x/s, or right
// away on selection/mode changes, and drives the panels.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../audio/sound_system.dart';
import '../engine/bw_engine_io.dart';
import '../engine/models.dart';
import '../rendering/icon_atlas.dart';
import '../rendering/sprite_atlas.dart';
import '../rendering/terrain_layer.dart';
import 'command_cards.dart';

enum CommandMode { none, move, attack, patrol, gather, repair, build, cast, rally }

enum CardMenu { main, basic, advanced }

enum CmdKind { move, stop, attack, patrol, hold, gather, returnCargo, repair, basicMenu, advancedMenu, back, produce, selectLarva, cancel, cancelTarget, ability, research, upgrade, rally }

class CmdButton {
  final CmdKind kind;
  final String hotkey; // single uppercase letter, '' for none, 'Esc' for back/cancel
  final String label;
  final int icon; // cmdicons.grp frame
  final int typeId; // unit type (produce), tech (research/ability) or upgrade id
  final AbilityEntry? ability;
  final int mineralCost;
  final int gasCost;
  final int energyCost;
  final bool enabled;
  final bool active;
  const CmdButton(
    this.kind,
    this.hotkey,
    this.label, {
    this.icon = -1,
    this.typeId = -1,
    this.ability,
    this.mineralCost = 0,
    this.gasCost = 0,
    this.energyCost = 0,
    this.enabled = true,
    this.active = false,
  });
}

/// A right-click confirmation, drawn like the original: a marker animating
/// on the ground, or the target's selection circle flashing.
class CommandMarker {
  final Offset? ground; // map position, for ground markers
  final int unitId; // flashing target, for unit markers
  final int owner;
  final int startMs;
  const CommandMarker({this.ground, this.unitId = 0, this.owner = 0, required this.startMs});
}

enum _Edge { none, top, bottom, left, right }

class GameController {
  static const int myPlayer = 0;
  static const int neutralPlayer = 11;
  // Brood War's "Fastest" game speed: one simulation frame every 42 ms.
  static const int frameMicros = 42000;
  static const double edgeScrollMargin = 8;
  static const double scrollSpeed = 1100; // map pixels per second
  static const int markerMs = 600;

  final Signal repaint = Signal();
  final Signal hud = Signal();

  BwEngine? _engine;
  SpriteAtlas? atlas;
  IconAtlas? icons;
  TerrainLayer? terrain;
  SoundSystem? sound;
  String? error;
  int myRace = 1; // 0 zerg, 1 terran, 2 protoss
  bool get ready => _engine != null && terrain != null && atlas != null;
  BwEngine get engine => _engine!;

  // Camera: map-pixel position of the viewport's top-left corner.
  double camX = 0;
  double camY = 0;
  Size viewport = Size.zero;
  final Set<_Scroll> _keyScroll = {};
  Offset? pointer; // pointer over the world viewport, viewport space
  bool pointerInside = false;

  // Pointer relative to the whole window, for edge scrolling anywhere along
  // the window border (including over the panels).
  Offset? _windowPointer;
  Size _windowSize = Size.zero;
  bool _pointerInWindow = false;
  _Edge _exitEdge = _Edge.none;

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
  CardMenu cardMenu = CardMenu.main;
  int? buildTypeId;
  AbilityEntry? castAbility;
  Rect? dragBox; // viewport space

  final List<CommandMarker> markers = [];

  String? message;
  int _messageUntilMs = 0;

  Duration? _lastTick;
  int _accMicros = 0;
  int _lastHudMs = 0;

  Set<int> _buildable = const {};
  final Set<int> _completedSeen = {};
  int _lastClickedUnit = 0;
  int _sameUnitClicks = 0;
  int _lastClickMs = 0;
  int _lastGroup = -1;
  int _lastGroupMs = 0;

  int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  // --- startup ---

  Future<void> start({required String dataDir, required String mapFile, required int race}) async {
    myRace = race;
    try {
      final e = BwEngine.open();
      e.loadAssets(dataDir);
      e.newMeleeGame(mapFile, playerSlot: myPlayer, race: race);
      e.step(1);
      _engine = e;
      atlas = SpriteAtlas(e);
      icons = IconAtlas(e)..onLoaded = () => _notifyHud(force: true);
      final s = SoundSystem(e);
      await s.init();
      sound = s;
      terrain = await TerrainLayer.build(e);
      _refreshUnits();
      for (final u in units) {
        if (u.owner == myPlayer && u.isCompleted) _completedSeen.add(u.unitId);
      }
      _startWorkersMining();
      engine.pollSounds(); // drop sounds from setup
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
    sound?.dispose();
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
  /// something changed (markers count as a change while animating).
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
      sound?.drainEngine(screenRect);
      _announceCompletedUnits();
      changed = true;
    }

    if (markers.isNotEmpty) {
      final now = _nowMs;
      markers.removeWhere((m) => now - m.startMs > markerMs);
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
    final previous = selection;
    selection = engine.getSelectedUnits(myPlayer);
    if (!listEquals(previous, selection)) cardMenu = CardMenu.main;
    minerals = engine.minerals(myPlayer);
    gas = engine.gas(myPlayer);
    final (used, max) = engine.supply(myPlayer, myRace);
    supplyUsed = used;
    supplyMax = max;
    frame = engine.currentFrame;
    _buildable = selectionIsMine ? engine.getBuildable(myPlayer).toSet() : const {};
  }

  // A newly finished unit says its "ready" line, like the original.
  void _announceCompletedUnits() {
    for (final u in units) {
      if (u.owner != myPlayer || !u.isCompleted || _completedSeen.contains(u.unitId)) continue;
      _completedSeen.add(u.unitId);
      final t = engine.unitType(u.typeId);
      if (t.readySound > 0) sound?.play(t.readySound, ui: true, unitTypeId: u.typeId);
    }
  }

  void _refreshView() {
    if (viewport.isEmpty) return;
    drawItems = engine.getDrawList(myPlayer, camX.floor(), camY.floor(), viewport.width.ceil(), viewport.height.ceil());
  }

  void _notifyHud({bool force = false}) {
    final now = _nowMs;
    if (!force && now - _lastHudMs < 100) return;
    _lastHudMs = now;
    if (message != null && now > _messageUntilMs) message = null;
    hud.fire();
  }

  void _changed() {
    if (!ready) return;
    _refreshUnits();
    _refreshView();
    repaint.fire();
    _notifyHud(force: true);
  }

  // --- camera ---

  Size get mapSize => terrain == null ? Size.zero : Size(terrain!.widthPx.toDouble(), terrain!.heightPx.toDouble());

  Rect get screenRect => Rect.fromLTWH(camX, camY, viewport.width, viewport.height);

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

  void stopAllScrolling() {
    _keyScroll.clear();
    _exitEdge = _Edge.none;
    _pointerInWindow = false;
  }

  // Window-level pointer tracking. In fullscreen (or a maximized window) the
  // window border is the screen border, so pushing the mouse against any
  // screen edge or corner scrolls, as in the original.
  void onWindowPointer(Offset position, Size windowSize) {
    _windowPointer = position;
    _windowSize = windowSize;
    _pointerInWindow = true;
    _exitEdge = _Edge.none;
  }

  // Leaving through the top edge of a maximized window lands on the title
  // bar, not the screen edge, so keep scrolling that way until the pointer
  // comes back (or focus is lost).
  void onWindowExit(Offset lastPosition, Size windowSize) {
    _pointerInWindow = false;
    _exitEdge = _Edge.none;
    if (lastPosition.dy <= edgeScrollMargin * 3) {
      _exitEdge = _Edge.top;
    } else if (lastPosition.dy >= windowSize.height - edgeScrollMargin * 3) {
      _exitEdge = _Edge.bottom;
    } else if (lastPosition.dx <= edgeScrollMargin * 3) {
      _exitEdge = _Edge.left;
    } else if (lastPosition.dx >= windowSize.width - edgeScrollMargin * 3) {
      _exitEdge = _Edge.right;
    }
  }

  bool _applyScroll(double dt) {
    double dx = 0, dy = 0;
    for (final s in _keyScroll) {
      dx += s.dx;
      dy += s.dy;
    }
    final p = _windowPointer;
    if (dragBox == null) {
      if (_pointerInWindow && p != null && !_windowSize.isEmpty) {
        if (p.dx <= edgeScrollMargin) dx -= 1;
        if (p.dx >= _windowSize.width - 1 - edgeScrollMargin) dx += 1;
        if (p.dy <= edgeScrollMargin) dy -= 1;
        if (p.dy >= _windowSize.height - 1 - edgeScrollMargin) dy += 1;
      } else {
        switch (_exitEdge) {
          case _Edge.top:
            dy -= 1;
          case _Edge.bottom:
            dy += 1;
          case _Edge.left:
            dx -= 1;
          case _Edge.right:
            dx += 1;
          case _Edge.none:
            break;
        }
      }
    }
    if (dx == 0 && dy == 0) return false;
    final oldX = camX, oldY = camY;
    camX += dx.sign * scrollSpeed * dt;
    camY += dy.sign * scrollSpeed * dt;
    _clampCamera();
    return camX != oldX || camY != oldY;
  }

  Offset screenToMap(Offset screen) => Offset(screen.dx + camX, screen.dy + camY);

  // --- messages and feedback ---

  void showMessage(String text, {int advisorSound = -1}) {
    message = text;
    _messageUntilMs = _nowMs + 2500;
    if (advisorSound >= 0) {
      sound?.play(advisorSound + myRace, ui: true);
    } else {
      sound?.play(soundErrorBuzz, ui: true);
    }
    _notifyHud(force: true);
  }

  void _markGround(Offset mapPos) {
    markers.add(CommandMarker(ground: mapPos, startMs: _nowMs));
  }

  void _markUnit(int unitId) {
    final u = unitsById[unitId];
    if (u == null) return;
    markers.add(CommandMarker(unitId: unitId, owner: u.owner, startMs: _nowMs));
  }

  UnitTypeInfo? get _voiceType {
    final sel = selectedUnits;
    if (sel.isEmpty || sel.first.owner != myPlayer) return null;
    return engine.unitType(sel.first.typeId);
  }

  void _sayYes() {
    final t = _voiceType;
    if (t != null) sound?.playRandom(t.yesFirst, t.yesLast, unitTypeId: t.typeId);
  }

  // Selecting plays a "what" line; clicking the same unit over and over
  // eventually gets the "pissed" lines, as in the original.
  void _sayWhat({required bool repeatedClick}) {
    final t = _voiceType;
    if (t == null) return;
    if (repeatedClick && _sameUnitClicks >= 4 && t.pissedFirst > 0 && t.pissedLast >= t.pissedFirst) {
      final count = t.pissedLast - t.pissedFirst + 1;
      sound?.play(t.pissedFirst + (_sameUnitClicks - 4) % count, ui: true, unitTypeId: t.typeId);
    } else {
      sound?.playRandom(t.whatFirst, t.whatLast, unitTypeId: t.typeId);
    }
  }

  // --- selection ---

  List<UnitInfo> get selectedUnits => [for (final id in selection) if (unitsById[id] != null) unitsById[id]!];

  bool get selectionIsMine => selection.isNotEmpty && selectedUnits.every((u) => u.owner == myPlayer);

  void select(List<int> ids, {bool voice = true, bool repeatedClick = false}) {
    engine.selectUnits(myPlayer, ids.take(12).toList());
    if (mode != CommandMode.none) mode = CommandMode.none;
    buildTypeId = null;
    cardMenu = CardMenu.main;
    _changed();
    if (voice) _sayWhat(repeatedClick: repeatedClick);
  }

  void clickSelect(Offset screen, {bool add = false}) {
    final p = screenToMap(screen);
    final id = engine.pickUnitAt(p.dx.round(), p.dy.round());
    if (id == 0) {
      if (!add) select(const [], voice: false);
      return;
    }
    final now = _nowMs;
    if (id == _lastClickedUnit && now - _lastClickMs < 2000) {
      _sameUnitClicks++;
    } else {
      _sameUnitClicks = 1;
    }
    _lastClickedUnit = id;
    _lastClickMs = now;

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
      select([id], repeatedClick: true);
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
    if (chosen.isEmpty && !add) {
      select(const [], voice: false);
      return;
    }
    if (add && selectionIsMine) {
      select({...selection, ...chosen}.toList());
    } else {
      select(chosen);
    }
  }

  void selectAllOfTypeOnScreen(int typeId) {
    final r = screenRect;
    select(units
        .where((u) => u.owner == myPlayer && u.typeId == typeId && r.contains(Offset(u.x.toDouble(), u.y.toDouble())))
        .map((u) => u.unitId)
        .toList());
  }

  // --- control groups (Ctrl+N assign, Shift+N add, N recall, N twice = jump) ---

  void controlGroup(int n, {required bool assign, required bool add}) {
    if (!ready) return;
    if (assign || add) {
      if (!selectionIsMine) return;
      engine.controlGroup(myPlayer, n, assign ? GroupAction.assign : GroupAction.add);
      showMessageQuiet(assign ? 'Group $n assigned.' : 'Added to group $n.');
      return;
    }
    final now = _nowMs;
    final doubleTap = _lastGroup == n && now - _lastGroupMs < 450;
    _lastGroup = n;
    _lastGroupMs = now;
    if (!engine.controlGroup(myPlayer, n, GroupAction.recall)) return;
    mode = CommandMode.none;
    buildTypeId = null;
    cardMenu = CardMenu.main;
    _changed();
    final sel = selectedUnits;
    if (doubleTap && sel.isNotEmpty) {
      centerOn(sel.first.x.toDouble(), sel.first.y.toDouble());
    }
  }

  void showMessageQuiet(String text) {
    message = text;
    _messageUntilMs = _nowMs + 1500;
    _notifyHud(force: true);
  }

  // --- command card ---

  bool get _uniform => selection.isNotEmpty && selectedUnits.every((u) => u.typeId == selectedUnits.first.typeId);

  List<CmdButton> commandCard() {
    if (!ready || !selectionIsMine) return const [];
    final sel = selectedUnits;
    if (sel.isEmpty) return const [];
    final first = sel.first;
    final uniform = _uniform;
    final worker = uniform ? workerMenus[first.typeId] : null;

    // While choosing a target or a building spot the original shows only
    // Cancel, so no other hotkey fires by accident.
    if (mode != CommandMode.none) return const [CmdButton(CmdKind.cancelTarget, 'Esc', 'Cancel', icon: CmdIcon.cancel)];

    CmdButton produceButton(String key, int typeId) {
      final t = engine.unitType(typeId);
      return CmdButton(
        CmdKind.produce,
        key,
        t.shortName,
        icon: typeId,
        typeId: typeId,
        mineralCost: t.mineralCost,
        gasCost: t.gasCost,
        enabled: _buildable.contains(typeId),
        active: mode == CommandMode.build && buildTypeId == typeId,
      );
    }

    if (worker != null && cardMenu != CardMenu.main) {
      final entries = cardMenu == CardMenu.basic ? worker.basic : worker.advanced;
      return [
        for (final (key, typeId) in entries) produceButton(key, typeId),
        const CmdButton(CmdKind.back, 'Esc', 'Back', icon: CmdIcon.cancel),
      ];
    }

    final buttons = <CmdButton>[];
    final mobile = sel.any((u) => u.canMove);
    if (mobile) {
      buttons.addAll([
        const CmdButton(CmdKind.move, 'M', 'Move', icon: CmdIcon.move),
        const CmdButton(CmdKind.stop, 'S', 'Stop', icon: CmdIcon.stop),
        const CmdButton(CmdKind.attack, 'A', 'Attack', icon: CmdIcon.attack),
      ]);
      if (worker != null) {
        buttons.add(const CmdButton(CmdKind.gather, 'G', 'Gather', icon: CmdIcon.gather));
        buttons.add(const CmdButton(CmdKind.returnCargo, 'C', 'Return Cargo', icon: CmdIcon.returnCargo));
        if (first.typeId == terranScv) {
          buttons.add(const CmdButton(CmdKind.repair, 'R', 'Repair', icon: CmdIcon.repair));
        }
        final menuIcons = buildMenuIcons[first.typeId] ?? (CmdIcon.buildBasic, CmdIcon.buildAdvanced);
        buttons.add(CmdButton(CmdKind.basicMenu, 'B', 'Build Structure', icon: menuIcons.$1));
        buttons.add(CmdButton(CmdKind.advancedMenu, 'V', 'Build Advanced Structure', icon: menuIcons.$2));
      } else {
        buttons.add(const CmdButton(CmdKind.patrol, 'P', 'Patrol', icon: CmdIcon.patrol));
        buttons.add(const CmdButton(CmdKind.hold, 'H', 'Hold Position', icon: CmdIcon.hold));
      }
    }

    // Abilities of this unit type (greyed until researched).
    if (uniform) {
      for (final a in unitAbilities[first.typeId] ?? const <AbilityEntry>[]) {
        buttons.add(_abilityButton(a, first));
      }
    }

    final busy = sel.length == 1 && first.isBusyResearching;
    if (uniform && !busy) {
      if (larvaProducers.contains(first.typeId)) {
        buttons.add(const CmdButton(CmdKind.selectLarva, 'S', 'Select Larva', icon: zergLarva));
      }
      final table = productionMenus[first.typeId];
      final listed = <int>{};
      if (table != null) {
        for (final (key, typeId) in table) {
          listed.add(typeId);
          buttons.add(produceButton(key, typeId));
        }
      }
      // Anything else the engine says this unit can make (e.g. rare
      // addons) still gets a button, just without a hotkey.
      if (worker == null) {
        for (final typeId in _buildable) {
          if (!listed.contains(typeId)) buttons.add(produceButton('', typeId));
        }
      }
    }

    // Research and upgrades of a single completed building.
    if (sel.length == 1 && first.isBuilding && first.isCompleted && !busy) {
      final researchable = engine.getResearchable(myPlayer).toSet();
      final upgradable = engine.getUpgradable(myPlayer).toSet();
      for (final (key, id, isTech) in researchMenus[first.typeId] ?? const <ResearchEntry>[]) {
        if (isTech) {
          final t = engine.techInfo(myPlayer, id);
          if (t == null || t.researched) continue;
          buttons.add(CmdButton(CmdKind.research, key, 'Research ${t.name}', icon: t.icon, typeId: id,
              mineralCost: t.mineralCost, gasCost: t.gasCost, enabled: researchable.contains(id)));
        } else {
          final u = engine.upgradeInfo(myPlayer, id);
          if (u == null || u.level >= u.maxLevel) continue;
          buttons.add(CmdButton(CmdKind.upgrade, key, 'Upgrade ${u.name}${u.maxLevel > 1 ? ' (level ${u.level + 1})' : ''}',
              icon: u.icon, typeId: id, mineralCost: u.mineralCost, gasCost: u.gasCost, enabled: upgradable.contains(id)));
        }
      }
    }

    if (sel.length == 1 && first.isCompleted && hasRally(first.typeId)) {
      buttons.add(const CmdButton(CmdKind.rally, 'R', 'Set Rally Point', icon: CmdIcon.rally));
    }

    if (sel.length == 1 && first.isBuilding && (first.queue.isNotEmpty || !first.isCompleted || busy)) {
      buttons.add(const CmdButton(CmdKind.cancel, 'Esc', 'Cancel', icon: CmdIcon.cancel));
    }
    return buttons;
  }

  CmdButton _abilityButton(AbilityEntry a, UnitInfo first) {
    var entry = a;
    var label = a.label;
    // Toggles show the opposite action once active, as in the original.
    if (a.instant == 'cloak' && first.isCloaked) {
      entry = AbilityEntry(a.hotkey, a.tech, a.targeting, instant: 'decloak', label: 'Decloak', icon: a.icon);
      label = 'Decloak';
    } else if (a.instant == 'burrow' && first.isBurrowed) {
      entry = AbilityEntry(a.hotkey, a.tech, a.targeting, instant: 'unburrow', label: 'Unburrow', icon: a.icon);
      label = 'Unburrow';
    }
    final tech = a.tech >= 0 ? engine.techInfo(myPlayer, a.tech) : null;
    return CmdButton(
      CmdKind.ability,
      a.hotkey,
      label.isNotEmpty ? label : (tech?.name ?? 'Ability'),
      icon: a.icon >= 0 ? a.icon : (tech?.icon ?? -1),
      typeId: a.tech,
      ability: entry,
      energyCost: tech?.energyCost ?? 0,
      enabled: a.tech < 0 || engine.canUseTech(myPlayer, a.tech),
      active: mode == CommandMode.cast && castAbility?.hotkey == a.hotkey,
    );
  }

  void activate(CmdButton b, {bool fromClick = false}) {
    if (fromClick) sound?.play(soundButton, ui: true);
    if (!b.enabled) {
      final needs = b.kind == CmdKind.produce ? requirementText[b.typeId] : null;
      showMessage(needs != null ? '${b.label} requires $needs.' : 'Requirements not met for ${b.label}.');
      return;
    }
    switch (b.kind) {
      case CmdKind.move:
        _setMode(CommandMode.move);
      case CmdKind.attack:
        _setMode(CommandMode.attack);
      case CmdKind.patrol:
        _setMode(CommandMode.patrol);
      case CmdKind.gather:
        _setMode(CommandMode.gather);
      case CmdKind.repair:
        _setMode(CommandMode.repair);
      case CmdKind.stop:
        _instantOrder(UnitOrder.stop);
      case CmdKind.hold:
        _instantOrder(UnitOrder.hold);
      case CmdKind.returnCargo:
        _instantOrder(UnitOrder.returnCargo);
      case CmdKind.basicMenu:
        _setMenu(CardMenu.basic);
      case CmdKind.advancedMenu:
        _setMenu(CardMenu.advanced);
      case CmdKind.back:
        _setMenu(CardMenu.main);
      case CmdKind.produce:
        _produce(b.typeId);
      case CmdKind.selectLarva:
        _selectLarva();
      case CmdKind.cancel:
        _cancelLast();
      case CmdKind.cancelTarget:
        cancelMode();
      case CmdKind.ability:
        _useAbility(b);
      case CmdKind.research:
        _research(b);
      case CmdKind.upgrade:
        _upgrade(b);
      case CmdKind.rally:
        _setMode(CommandMode.rally);
    }
  }

  /// A letter key: runs the command card button with that hotkey, as in the
  /// original. Returns false when nothing on the card uses it.
  bool pressHotkey(String letter) {
    final card = commandCard();
    final matching = card.where((b) => b.hotkey == letter).toList();
    if (matching.isEmpty) return false;
    activate(matching.firstWhere((b) => b.enabled, orElse: () => matching.first));
    return true;
  }

  /// Esc: cancel a targeting mode, else leave a build submenu, else cancel
  /// the last queued item (as the original's Cancel hotkey).
  void escape() {
    if (mode != CommandMode.none) {
      cancelMode();
      return;
    }
    if (cardMenu != CardMenu.main) {
      _setMenu(CardMenu.main);
      return;
    }
    final cancel = commandCard().where((b) => b.kind == CmdKind.cancel);
    if (cancel.isNotEmpty) activate(cancel.first);
  }

  void _setMenu(CardMenu menu) {
    cardMenu = menu;
    mode = CommandMode.none;
    buildTypeId = null;
    _notifyHud(force: true);
    repaint.fire();
  }

  void _setMode(CommandMode m) {
    if (!selectionIsMine) return;
    mode = m;
    buildTypeId = null;
    if (m != CommandMode.cast) castAbility = null;
    _notifyHud(force: true);
    repaint.fire();
  }

  void cancelMode() {
    mode = CommandMode.none;
    buildTypeId = null;
    castAbility = null;
    _notifyHud(force: true);
    repaint.fire();
  }

  void _instantOrder(UnitOrder order) {
    if (!selectionIsMine) return;
    if (engine.order(myPlayer, order, 0, 0)) _sayYes();
    _changed();
  }

  void _selectLarva() {
    final hatcheries = selectedUnits.where((u) => larvaProducers.contains(u.typeId)).toList();
    final larvae = units.where((l) {
      if (l.owner != myPlayer || l.typeId != zergLarva) return false;
      return hatcheries.any((h) {
        final dx = l.x - h.x, dy = l.y - h.y;
        return dx * dx + dy * dy < 160 * 160;
      });
    }).map((l) => l.unitId).toList();
    if (larvae.isEmpty) {
      showMessage('No larva available.');
      return;
    }
    select(larvae, voice: false);
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
    if (engine.order(myPlayer, UnitOrder.smart, x, y, targetUnitId: target, queue: queue)) {
      target != 0 ? _markUnit(target) : _markGround(mapPos);
      _sayYes();
    }
    _changed();
  }

  /// Left click while a targeted command is armed.
  void modeClick(Offset mapPos, {bool queue = false}) {
    final x = mapPos.dx.round(), y = mapPos.dy.round();
    switch (mode) {
      case CommandMode.move:
      case CommandMode.attack:
      case CommandMode.patrol:
      case CommandMode.gather:
      case CommandMode.repair:
        final order = switch (mode) {
          CommandMode.move => UnitOrder.move,
          CommandMode.attack => UnitOrder.attack,
          CommandMode.patrol => UnitOrder.patrol,
          CommandMode.repair => UnitOrder.repair,
          _ => UnitOrder.smart,
        };
        final target = order == UnitOrder.patrol ? 0 : engine.pickUnitAt(x, y);
        if ((mode == CommandMode.gather || mode == CommandMode.repair) && target == 0) {
          showMessage(mode == CommandMode.gather ? 'Must target a resource.' : 'Must target a unit to repair.');
          return;
        }
        if (engine.order(myPlayer, order, x, y, targetUnitId: target, queue: queue)) {
          target != 0 ? _markUnit(target) : _markGround(mapPos);
          _sayYes();
        } else {
          showMessage('Invalid target.');
        }
        if (!queue) mode = CommandMode.none;
      case CommandMode.build:
        final type = buildTypeId;
        if (type == null) return;
        final (tx, ty) = placementTile(mapPos, type);
        if (!_canAfford(engine.unitType(type), checkSupply: false)) return;
        if (engine.build(myPlayer, type, tx, ty)) {
          _sayYes();
          if (!queue) {
            mode = CommandMode.none;
            buildTypeId = null;
            cardMenu = CardMenu.main;
          }
        } else {
          showMessage("Can't build there.");
        }
      case CommandMode.cast:
        final a = castAbility;
        if (a == null) return;
        final target = engine.pickUnitAt(x, y);
        if (a.targeting == Targeting.unit && target == 0) {
          showMessage('Invalid target.');
          return;
        }
        if (engine.cast(myPlayer, a.tech, x, y, targetUnitId: a.targeting == Targeting.unit ? target : 0, queue: queue)) {
          a.targeting == Targeting.unit ? _markUnit(target) : _markGround(mapPos);
          _sayYes();
          if (!queue) {
            mode = CommandMode.none;
            castAbility = null;
          }
        } else {
          showMessage('Invalid target.');
        }
      case CommandMode.rally:
        final target = engine.pickUnitAt(x, y);
        if (engine.setRally(myPlayer, x, y, targetUnitId: target)) {
          target != 0 ? _markUnit(target) : _markGround(mapPos);
        }
        mode = CommandMode.none;
      case CommandMode.none:
        break;
    }
    _changed();
  }

  void _useAbility(CmdButton b) {
    final a = b.ability;
    if (a == null) return;
    if (b.energyCost > 0 && !selectedUnits.any((u) => u.energy >= b.energyCost)) {
      showMessage('Not enough energy.', advisorSound: soundNotEnoughEnergy);
      return;
    }
    if (a.targeting != Targeting.instant) {
      mode = CommandMode.cast;
      castAbility = a;
      buildTypeId = null;
      _notifyHud(force: true);
      repaint.fire();
      return;
    }
    final ability = switch (a.instant) {
      'stim' => Ability.stim,
      'siege' => Ability.siege,
      'unsiege' => Ability.unsiege,
      'cloak' => Ability.cloak,
      'decloak' => Ability.decloak,
      'burrow' => Ability.burrow,
      'unburrow' => Ability.unburrow,
      'fighter' => Ability.trainFighter,
      'archon' => Ability.archonWarp,
      'darkArchon' => Ability.darkArchonMeld,
      'unload' => Ability.unloadAll,
      _ => null,
    };
    if (ability == null) return;
    if (ability == Ability.trainFighter) {
      // Interceptors 25, scarabs 15 minerals.
      final cost = selectedUnits.first.typeId == 72 ? 25 : 15;
      if (minerals < cost) {
        showMessage('Not enough minerals.', advisorSound: soundNotEnoughMinerals);
        return;
      }
    }
    if (engine.ability(myPlayer, ability)) {
      _sayYes();
    } else {
      showMessage('Unable to use ${b.label} right now.');
    }
    _changed();
  }

  void _research(CmdButton b) {
    if (!_canAffordCost(b.mineralCost, b.gasCost)) return;
    if (!engine.research(myPlayer, b.typeId)) showMessage('Unable to research right now.');
    _changed();
  }

  void _upgrade(CmdButton b) {
    if (!_canAffordCost(b.mineralCost, b.gasCost)) return;
    if (!engine.upgrade(myPlayer, b.typeId)) showMessage('Unable to upgrade right now.');
    _changed();
  }

  bool _canAffordCost(int mineralCost, int gasCost) {
    if (minerals < mineralCost) {
      showMessage('Not enough minerals.', advisorSound: soundNotEnoughMinerals);
      return false;
    }
    if (gas < gasCost) {
      showMessage('Not enough Vespene gas.', advisorSound: soundNotEnoughGas);
      return false;
    }
    return true;
  }

  void _produce(int typeId) {
    if (!selectionIsMine) return;
    final t = engine.unitType(typeId);
    final builder = selectedUnits.first;
    final placesBuilding = t.isBuilding && !t.isAddon && builder.isWorker;
    if (!_canAfford(t, checkSupply: !t.isBuilding)) return;
    if (placesBuilding) {
      if (selection.length != 1) select([builder.unitId], voice: false);
      mode = CommandMode.build;
      buildTypeId = typeId;
      _notifyHud(force: true);
      repaint.fire();
      return;
    }
    if (!engine.train(myPlayer, typeId)) {
      showMessage('Unable to build ${t.shortName} right now.');
    }
    _changed();
  }

  bool _canAfford(UnitTypeInfo t, {required bool checkSupply}) {
    if (minerals < t.mineralCost) {
      showMessage('Not enough minerals.', advisorSound: soundNotEnoughMinerals);
      return false;
    }
    if (gas < t.gasCost) {
      showMessage('Not enough Vespene gas.', advisorSound: soundNotEnoughGas);
      return false;
    }
    if (checkSupply && t.supply > 0 && supplyUsed + t.supply > supplyMax) {
      const needs = ['Spawn more Overlords.', 'You must construct additional Supply Depots.', 'You must construct additional Pylons.'];
      showMessage(needs[myRace.clamp(0, 2)], advisorSound: soundNeedSupply);
      return false;
    }
    return true;
  }

  /// Clicking a queued item cancels it (slot 0 is the one in production).
  void cancelQueueSlot(int slot) {
    if (!selectionIsMine || selection.length != 1) return;
    sound?.play(soundButton, ui: true);
    engine.cancelQueueSlot(myPlayer, slot);
    _changed();
  }

  void cancelResearch() {
    if (!selectionIsMine || selection.length != 1) return;
    sound?.play(soundButton, ui: true);
    _cancelLast();
  }

  void _cancelLast() {
    if (!selectionIsMine || selection.length != 1) return;
    final u = selectedUnits.first;
    if (u.researchingTech >= 0) {
      engine.ability(myPlayer, Ability.cancelResearch);
    } else if (u.upgrading >= 0) {
      engine.ability(myPlayer, Ability.cancelUpgrade);
    } else {
      engine.cancelLast(myPlayer);
    }
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
