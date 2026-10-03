// lib/ui/game_viewport.dart
//
// The world view: forwards input to the GameController.
//
// Mouse (desktop, or a Bluetooth mouse on a phone):
//   left click / drag ........ select / box select (shift adds)
//   double click ............. select all of that type on screen
//   right click .............. context command (move/attack/gather/rally...)
//   middle drag .............. pan
//   pointer at the edge ...... scroll
// While a targeted command is armed (attack/move/patrol/build), left click
// executes it and right click cancels.
//
// Touch:
//   tap ...................... select (double tap: all of that type on screen)
//   drag on the ground ....... box select
//   drag from your units ..... command arrow: on release they do the obvious
//                              thing there (attack an enemy, mine minerals or
//                              gas, follow a friend, move to the ground)
//   hold still ............... the same command at that spot
//   two fingers .............. move the map
// With a targeted command armed, the tap (or where a drag ends) is the
// target; while placing a building the ghost follows the finger.

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../game/game_controller.dart';
import '../rendering/bw_painter.dart';

class GameViewport extends StatefulWidget {
  final GameController controller;
  const GameViewport({super.key, required this.controller});

  @override
  State<GameViewport> createState() => _GameViewportState();
}

class _GameViewportState extends State<GameViewport> {
  GameController get c => widget.controller;

  // Mouse.
  Offset? _dragStart;
  bool _panning = false;
  int _lastClickMs = 0;
  int _lastClickUnit = 0;

  // Touch.
  final Map<int, Offset> _touches = {};
  int? _primary;
  Offset _touchStart = Offset.zero;
  bool _touchMoved = false;
  bool _commandDrag = false;
  bool _twoFingers = false;
  bool _longPressed = false;
  Offset _panLast = Offset.zero;
  Timer? _longPress;

  // --dart-define=BROOD_TOUCH_LOG=true prints what touch does (for testing
  // on a phone through adb).
  static const bool _touchLog = bool.fromEnvironment('BROOD_TOUCH_LOG');
  static void _log(String m) {
    if (_touchLog) debugPrint('touch $m');
  }

  static const double _dragThreshold = 5;
  static const double _touchSlop = 12;

  bool get _shift => HardwareKeyboard.instance.isShiftPressed;

  static bool _isTouch(PointerEvent e) => e.kind == PointerDeviceKind.touch || e.kind == PointerDeviceKind.stylus;

  // --- mouse ---

  void _down(PointerDownEvent e) {
    if (_isTouch(e)) return _touchDown(e);
    c.pointer = e.localPosition;
    if (e.buttons & kMiddleMouseButton != 0) {
      _panning = true;
      return;
    }
    if (e.buttons & kSecondaryMouseButton != 0) {
      c.smartCommand(c.screenToMap(e.localPosition), queue: _shift);
      return;
    }
    if (e.buttons & kPrimaryMouseButton != 0) {
      if (c.mode != CommandMode.none) {
        c.modeClick(c.screenToMap(e.localPosition), queue: _shift);
        return;
      }
      _dragStart = e.localPosition;
    }
  }

  void _move(PointerMoveEvent e) {
    if (_isTouch(e)) return _touchMove(e);
    c.pointer = e.localPosition;
    if (_panning) {
      c.panBy(-e.delta.dx, -e.delta.dy);
      return;
    }
    final start = _dragStart;
    if (start != null && (e.localPosition - start).distance >= _dragThreshold) {
      c.dragBox = Rect.fromPoints(start, e.localPosition);
      c.repaint.fire();
    } else if (c.mode == CommandMode.build) {
      c.repaint.fire();
    }
  }

  void _up(PointerUpEvent e) {
    if (_isTouch(e)) return _touchUp(e);
    if (_panning) {
      _panning = false;
      return;
    }
    final start = _dragStart;
    _dragStart = null;
    if (start == null) return;
    final box = c.dragBox;
    c.dragBox = null;
    if (box != null) {
      c.boxSelect(box, add: _shift);
      return;
    }
    _select(e.localPosition, add: _shift);
  }

  // A click or tap: select, or all of that type on a quick second one.
  void _select(Offset at, {bool add = false, bool touch = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final map = c.screenToMap(at);
    final picked = touch ? c.pickNear(map, slop: GameController.fingerSlop, ownFirst: true) : c.engine.pickUnitAt(map.dx.round(), map.dy.round());
    final unit = c.unitsById[picked];
    _log('select at=${at.dx.round()},${at.dy.round()} map=${map.dx.round()},${map.dy.round()} picked=$picked type=${unit?.typeId} units=${c.unitsById.length}');
    if (picked != 0 && picked == _lastClickUnit && now - _lastClickMs < 350 && unit != null && c.canControl(unit.owner)) {
      c.selectAllOfTypeOnScreen(unit.typeId);
    } else {
      c.clickSelect(at, add: add, touch: touch);
    }
    _lastClickMs = now;
    _lastClickUnit = picked;
  }

  // --- touch ---

  Offset get _touchCenter {
    var sum = Offset.zero;
    for (final p in _touches.values) {
      sum += p;
    }
    return sum / _touches.length.toDouble();
  }

  void _cancelSingle() {
    _longPress?.cancel();
    _primary = null;
    if (c.dragBox != null || c.commandDragTo != null) {
      c.dragBox = null;
      c.setCommandDrag(null);
    }
  }

  void _touchDown(PointerDownEvent e) {
    _log('down ${e.pointer} ${e.localPosition} known=${_touches.keys}');
    _touches[e.pointer] = e.localPosition;
    if (_touches.length >= 2) {
      // A second finger: the map moves; whatever the first one started stops.
      _cancelSingle();
      _twoFingers = true;
      _panLast = _touchCenter;
      return;
    }
    _primary = e.pointer;
    _touchStart = e.localPosition;
    _touchMoved = false;
    _longPressed = false;
    c.pointer = e.localPosition;
    c.pointerInside = true;
    _commandDrag = c.mode == CommandMode.none && c.nearSelected(e.localPosition);
    _log(
      'single commandDrag=$_commandDrag selected=${c.selectedUnits.length} mode=${c.mode.name} at=${e.localPosition.dx.round()},${e.localPosition.dy.round()}',
    );
    _longPress?.cancel();
    _longPress = Timer(const Duration(milliseconds: 500), () {
      if (_touchMoved || _twoFingers || _primary != e.pointer) return;
      if (c.mode != CommandMode.none || !c.selectionCommandable) return;
      _longPressed = true;
      HapticFeedback.mediumImpact();
      c.smartCommand(c.screenToMap(_touchStart), touch: true);
    });
    if (c.mode == CommandMode.build) c.repaint.fire();
  }

  void _touchMove(PointerMoveEvent e) {
    if (!_touches.containsKey(e.pointer)) return;
    _touches[e.pointer] = e.localPosition;
    if (_twoFingers) {
      if (_touches.length < 2) return;
      final center = _touchCenter;
      final d = center - _panLast;
      _panLast = center;
      c.panBy(-d.dx, -d.dy);
      return;
    }
    if (e.pointer != _primary) return;
    c.pointer = e.localPosition;
    if (!_touchMoved && (e.localPosition - _touchStart).distance > _touchSlop) {
      _touchMoved = true;
      _longPress?.cancel();
    }
    if (!_touchMoved || _longPressed) return;
    if (c.mode == CommandMode.build) {
      c.repaint.fire(); // the ghost follows the finger
      return;
    }
    if (c.mode != CommandMode.none) return; // the target is where it lifts
    if (_commandDrag) {
      c.setCommandDrag(e.localPosition);
    } else {
      c.dragBox = Rect.fromPoints(_touchStart, e.localPosition);
      c.repaint.fire();
    }
  }

  void _touchUp(PointerEvent e) {
    _log('${e is PointerCancelEvent ? 'cancel' : 'up'} ${e.pointer} ${e.localPosition} moved=$_touchMoved box=${c.dragBox} two=$_twoFingers');
    final known = _touches.remove(e.pointer) != null;
    if (!known) return;
    if (_twoFingers) {
      if (_touches.isEmpty) {
        _twoFingers = false;
      } else {
        _panLast = _touchCenter;
      }
      return;
    }
    if (e.pointer != _primary) return;
    _longPress?.cancel();
    _primary = null;
    if (_longPressed || e is PointerCancelEvent) {
      _cancelSingle();
      return;
    }
    final at = e.localPosition;
    if (c.mode != CommandMode.none) {
      c.modeClick(c.screenToMap(at), touch: true);
      _log('modeClick at=${at.dx.round()},${at.dy.round()} now mode=${c.mode.name} message=${c.message}');
      return;
    }
    if (_commandDrag && _touchMoved) {
      c.setCommandDrag(null);
      c.smartCommand(c.screenToMap(at), touch: true);
      return;
    }
    final box = c.dragBox;
    if (box != null) {
      c.dragBox = null;
      c.boxSelect(box);
      return;
    }
    if (!_touchMoved) _select(at, touch: true);
  }

  @override
  void dispose() {
    _longPress?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size != c.viewport) {
          WidgetsBinding.instance.addPostFrameCallback((_) => c.setViewport(size));
        }
        return MouseRegion(
          cursor: SystemMouseCursors.precise,
          onEnter: (e) {
            c.pointerInside = true;
            c.pointer = e.localPosition;
          },
          onExit: (_) => c.pointerInside = false,
          onHover: (e) {
            c.pointer = e.localPosition;
            if (c.mode == CommandMode.build) c.repaint.fire();
          },
          child: Listener(
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: (e) {
              if (_isTouch(e)) _touchUp(e);
            },
            child: CustomPaint(painter: BwPainter(c), size: size),
          ),
        );
      },
    );
  }
}
