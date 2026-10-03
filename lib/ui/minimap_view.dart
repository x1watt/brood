// lib/ui/minimap_view.dart
//
// Left click / drag jumps the camera; right click issues the context
// command at that map position (like the original's minimap).

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../game/game_controller.dart';
import '../rendering/minimap_painter.dart';

class MinimapView extends StatelessWidget {
  final GameController controller;
  const MinimapView({super.key, required this.controller});

  Offset _toMap(Offset local, Size size) {
    final (scale, origin) = MinimapPainter.layout(controller, size);
    return (local - origin) / scale;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        void jump(Offset local) {
          final p = _toMap(local, size);
          controller.centerOn(p.dx, p.dy);
        }

        return Listener(
          onPointerDown: (e) {
            if (e.buttons & kSecondaryMouseButton != 0) {
              controller.smartCommand(_toMap(e.localPosition, size), queue: HardwareKeyboard.instance.isShiftPressed);
            } else if (e.buttons & kPrimaryMouseButton != 0) {
              jump(e.localPosition);
            }
          },
          onPointerMove: (e) {
            if (e.buttons & kPrimaryMouseButton != 0) jump(e.localPosition);
          },
          child: CustomPaint(painter: MinimapPainter(controller), size: size),
        );
      },
    );
  }
}
