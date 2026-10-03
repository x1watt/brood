// lib/rendering/bw_painter.dart
//
// Draws the bridge's per-frame "parts list" (List<SpriteInfo>) using
// Flutter's own canvas, resolving each sprite's picture through
// SpriteAtlas — the chosen rendering strategy (see docs/architecture.md):
// no pre-composited picture crosses the bridge, so textures stay swappable.
//
// v0: no terrain background, no fog-of-war, approximate z-order via
// elevation_level only (ties broken by list order). Good enough to prove
// the pipeline renders real, correctly colored sprites on screen.

import 'package:flutter/material.dart';

import '../engine/sprite_info.dart';
import 'camera.dart';
import 'sprite_atlas.dart';

class BwPainter extends CustomPainter {
  final List<SpriteInfo> sprites;
  final SpriteAtlas atlas;
  final Camera camera;

  BwPainter({required this.sprites, required this.atlas, required this.camera}) : super();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF101014));

    final sorted = [...sprites]..sort((a, b) => a.elevationLevel.compareTo(b.elevationLevel));

    final paint = Paint()..filterQuality = FilterQuality.none;
    for (final s in sorted) {
      final image = atlas.resolve(s.imageTypeId, s.frameIndex, s.flipped, s.owner);
      if (image == null) continue; // not decoded yet; will appear in a later frame
      final dx = s.x - camera.x - image.width / 2;
      final dy = s.y - camera.y - image.height / 2;
      canvas.drawImage(image, Offset(dx, dy), paint);
    }
  }

  @override
  bool shouldRepaint(covariant BwPainter oldDelegate) => true;
}
