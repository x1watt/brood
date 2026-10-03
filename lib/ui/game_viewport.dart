// lib/ui/game_viewport.dart
//
// The world view: forwards mouse input to the GameController.
//   left click / drag ........ select / box select (shift adds)
//   double click ............. select all of that type on screen
//   right click .............. context command (move/attack/gather/rally...)
//   middle drag .............. pan
//   pointer at the edge ...... scroll
// While a targeted command is armed (attack/move/patrol/build), left click
// executes it and right click cancels.

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

  Offset? _dragStart;
  bool _panning = false;
  int _lastClickMs = 0;
  int _lastClickUnit = 0;

  static const double _dragThreshold = 5;

  bool get _shift => HardwareKeyboard.instance.isShiftPressed;

  void _down(PointerDownEvent e) {
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
    final now = DateTime.now().millisecondsSinceEpoch;
    final map = c.screenToMap(e.localPosition);
    final picked = c.engine.pickUnitAt(map.dx.round(), map.dy.round());
    final unit = c.unitsById[picked];
    if (picked != 0 && picked == _lastClickUnit && now - _lastClickMs < 350 && unit != null && c.canControl(unit.owner)) {
      c.selectAllOfTypeOnScreen(unit.typeId);
    } else {
      c.clickSelect(e.localPosition, add: _shift);
    }
    _lastClickMs = now;
    _lastClickUnit = picked;
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
            child: CustomPaint(painter: BwPainter(c), size: size),
          ),
        );
      },
    );
  }
}
