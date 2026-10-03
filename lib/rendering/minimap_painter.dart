// lib/rendering/minimap_painter.dart
//
// Whole map scaled into the minimap box: terrain, a dot per unit (own
// green, neutral resources cyan, others red) and the camera's view rectangle.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../game/game_controller.dart';

class MinimapPainter extends CustomPainter {
  final GameController c;

  MinimapPainter(this.c) : super(repaint: c.hud);

  /// Map-pixel to minimap-pixel scale and offset for a box of [size]
  /// (the map keeps its aspect ratio, centered).
  static (double scale, Offset origin) layout(GameController c, Size size) {
    final m = c.mapSize;
    if (m.isEmpty) return (1, Offset.zero);
    final scale = math.min(size.width / m.width, size.height / m.height);
    final origin = Offset((size.width - m.width * scale) / 2, (size.height - m.height * scale) / 2);
    return (scale, origin);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF000000));
    final terrain = c.terrain;
    if (terrain == null) return;
    final (scale, origin) = layout(c, size);
    final mapRect = Rect.fromLTWH(origin.dx, origin.dy, c.mapSize.width * scale, c.mapSize.height * scale);
    canvas.drawImageRect(
      terrain.minimap,
      Rect.fromLTWH(0, 0, terrain.minimap.width.toDouble(), terrain.minimap.height.toDouble()),
      mapRect,
      Paint()..filterQuality = FilterQuality.medium,
    );

    final own = Paint()..color = const Color(0xFF3CFF3C);
    final neutral = Paint()..color = const Color(0xFF6FD3FF);
    final enemy = Paint()..color = const Color(0xFFFF3B30);
    for (final u in c.units) {
      final p = origin + Offset(u.x * scale, u.y * scale);
      final w = math.max(2.0, u.width * scale);
      final h = math.max(2.0, u.height * scale);
      final paint = u.owner == GameController.myPlayer
          ? own
          : u.owner == GameController.neutralPlayer
          ? neutral
          : enemy;
      canvas.drawRect(Rect.fromCenter(center: p, width: w, height: h), paint);
    }

    final view = Rect.fromLTWH(
      origin.dx + c.camX * scale,
      origin.dy + c.camY * scale,
      c.viewport.width * scale,
      c.viewport.height * scale,
    );
    canvas.drawRect(
      view,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant MinimapPainter oldDelegate) => oldDelegate.c != c;
}
