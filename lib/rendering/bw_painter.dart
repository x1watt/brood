// lib/rendering/bw_painter.dart
//
// Draws the world: terrain, then the bridge's draw list in the exact order
// given (the engine already sorted it and positioned every frame's
// top-left), then UI overlays (building ghost, drag box). Modifiers are
// treated the way OpenBW's reference renderer (ui/ui.h draw_image) treats
// them: shadows darken, glows add light, cloaked images are translucent.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../engine/models.dart';
import '../game/game_controller.dart';
import 'sprite_atlas.dart';

class BwPainter extends CustomPainter {
  final GameController c;

  BwPainter(this.c) : super(repaint: c.repaint);

  static final Paint _plain = Paint()..filterQuality = FilterQuality.none;
  static final Paint _shadow = Paint()
    ..filterQuality = FilterQuality.none
    ..colorFilter = const ColorFilter.mode(Color(0x80000000), BlendMode.srcIn);
  static final Paint _glow = Paint()
    ..filterQuality = FilterQuality.none
    ..blendMode = BlendMode.plus;
  static final Paint _translucent = Paint()
    ..filterQuality = FilterQuality.none
    ..color = const Color(0x80FFFFFF);
  static final Paint _faint = Paint()
    ..filterQuality = FilterQuality.none
    ..color = const Color(0x55FFFFFF);

  static const Color ownColor = Color(0xFF3CFF3C);
  static const Color neutralColor = Color(0xFFFFE14D);
  static const Color enemyColor = Color(0xFFFF3B30);

  static final Map<Color, Paint> _circlePaints = {
    for (final color in const [ownColor, neutralColor, enemyColor])
      color: Paint()
        ..filterQuality = FilterQuality.none
        ..colorFilter = ColorFilter.mode(color, BlendMode.srcIn),
  };

  // Selection circles: green own, yellow allied or neutral, red enemy.
  Color relationColor(int owner) => switch (c.relation(owner)) {
    Relation.own => ownColor,
    Relation.ally || Relation.neutral => neutralColor,
    Relation.enemy => enemyColor,
  };

  static final Paint _fogPaint = Paint()..filterQuality = FilterQuality.medium;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF000000));
    final terrain = c.terrain;
    final atlas = c.atlas;
    if (terrain == null || atlas == null) return;

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final camX = c.camX.floorToDouble();
    final camY = c.camY.floorToDouble();

    final program = terrain.program;
    if (program != null) {
      // Palette-indexed terrain colored by the shader, with the palette
      // rotated by game time (animated water).
      final shader = _terrainShader ??= program.fragmentShader();
      shader
        ..setFloat(0, camX)
        ..setFloat(1, camY)
        ..setFloat(2, terrain.widthPx.toDouble())
        ..setFloat(3, terrain.heightPx.toDouble())
        ..setImageSampler(0, terrain.indices)
        ..setImageSampler(1, terrain.paletteForFrame(c.frame));
      canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    } else {
      final src = Rect.fromLTWH(camX, camY, size.width, size.height).intersect(
        Rect.fromLTWH(0, 0, terrain.widthPx.toDouble(), terrain.heightPx.toDouble()),
      );
      if (!src.isEmpty) canvas.drawImageRect(terrain.colors!, src, src.shift(Offset(-camX, -camY)), _plain);
    }

    for (final item in c.drawItems) {
      final pos = Offset(item.x - camX, item.y - camY);
      if (item.kind == DrawItem.kindSelectionCircle) {
        _drawSelection(canvas, atlas, item, pos);
        continue;
      }
      switch (item.modifier) {
        case DrawItem.modShadow:
          final img = atlas.resolveMask(item.imageTypeId, item.frameIndex, item.flipped);
          if (img != null) canvas.drawImage(img, pos, _shadow);
        case DrawItem.modGlow:
        case 17:
          final light = item.modifier == 17 ? 1 : item.colorShift;
          if (light >= 1 && light <= 7) {
            final img = atlas.resolveGlow(item.imageTypeId, item.frameIndex, item.flipped, light);
            if (img != null) canvas.drawImage(img, pos, _glow);
          }
        case 2:
        case 3:
        case 4:
        case 5:
        case 6:
        case 7:
        case 12:
          final img = atlas.resolveColor(item.imageTypeId, item.frameIndex, item.flipped, item.colorIndex);
          if (img != null) canvas.drawImage(img, pos, _translucent);
        case 8:
          final img = atlas.resolveColor(item.imageTypeId, item.frameIndex, item.flipped, item.colorIndex);
          if (img != null) canvas.drawImage(img, pos, _faint);
        default:
          final img = atlas.resolveColor(item.imageTypeId, item.frameIndex, item.flipped, item.colorIndex);
          if (img != null) canvas.drawImage(img, pos, _plain);
      }
    }

    // Fog of war: one texel per tile stretched over the map, so the
    // bilinear filter softens its edges.
    final fog = c.fogImage;
    if (fog != null) {
      canvas.drawImageRect(
        fog,
        Rect.fromLTWH(0, 0, fog.width.toDouble(), fog.height.toDouble()),
        Rect.fromLTWH(-camX, -camY, fog.width * 32.0, fog.height * 32.0),
        _fogPaint,
      );
    }

    _drawRally(canvas, atlas, camX, camY);
    _drawMarkers(canvas, atlas, camX, camY);
    _drawPlacementGhost(canvas, camX, camY);

    final box = c.dragBox;
    if (box != null) {
      canvas.drawRect(box, Paint()..color = const Color(0x2238FF38));
      canvas.drawRect(
        box,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = ownColor
          ..strokeWidth = 1,
      );
    }
    canvas.restore();
  }

  void _drawSelection(Canvas canvas, SpriteAtlas atlas, DrawItem item, Offset pos) {
    final color = relationColor(item.owner);
    final img = atlas.resolveMask(item.imageTypeId, 0, false);
    if (img == null) return;
    canvas.drawImage(img, pos, _circlePaints[color]!);

    // Health bar under the circle, like the original's selection display.
    if (item.hpPermille < 0 || item.owner == GameController.neutralPlayer) return;
    final double w = img.width.toDouble().clamp(16.0, 120.0);
    final left = pos.dx + (img.width - w) / 2;
    var top = pos.dy + img.height + 2;
    void bar(double fraction, Color fill) {
      final r = Rect.fromLTWH(left, top, w, 4);
      canvas.drawRect(r, Paint()..color = const Color(0xFF101010));
      canvas.drawRect(Rect.fromLTWH(left, top, w * fraction.clamp(0, 1), 4), Paint()..color = fill);
      canvas.drawRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = const Color(0xFF000000)
          ..strokeWidth = 1,
      );
      top += 5;
    }

    if (item.shieldPermille >= 0) bar(item.shieldPermille / 1000, const Color(0xFF4FA3FF));
    final hp = item.hpPermille / 1000;
    bar(hp, hp > 0.66 ? const Color(0xFF2EE62E) : hp > 0.33 ? const Color(0xFFF5D90A) : const Color(0xFFE5322E));
  }

  // Right-click confirmation, as in the original: the cursor marker animates
  // on the ground at the destination, or the target's selection circle
  // flashes three times (green own, yellow neutral, red enemy).
  void _drawMarkers(Canvas canvas, SpriteAtlas atlas, double camX, double camY) {
    if (c.markers.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final markerImage = c.engine.cursorMarkerImage;
    final frames = _markerFrames ??= c.engine.getImageFrameCount(markerImage);
    for (final m in c.markers) {
      final age = now - m.startMs;
      final ground = m.ground;
      if (ground != null) {
        if (frames <= 0) continue;
        final frame = (age * frames ~/ GameController.markerMs).clamp(0, frames - 1);
        final img = atlas.resolveColor(markerImage, frame, false, 0);
        if (img == null) continue;
        canvas.drawImage(img, Offset(ground.dx - camX - img.width / 2, ground.dy - camY - img.height / 2), _plain);
        continue;
      }
      if ((age ~/ 100).isOdd) continue; // flash: 100 ms on, 100 ms off
      final circle = c.engine.selectionCircle(m.unitId);
      if (circle == null) continue;
      final (imageId, x, y) = circle;
      final img = atlas.resolveMask(imageId, 0, false);
      if (img == null) continue;
      canvas.drawImage(img, Offset(x - camX, y - camY), _circlePaints[relationColor(m.owner)]!);
    }
  }

  static int? _markerFrames;
  ui.FragmentShader? _terrainShader;

  // Where a selected production building sends new units: a line from the
  // building to the rally point and the original's marker at the end.
  void _drawRally(Canvas canvas, SpriteAtlas atlas, double camX, double camY) {
    final sel = c.selectedUnits;
    if (sel.length != 1) return;
    final b = sel.first;
    if (b.owner != c.myPlayer || !b.hasRally) return;
    final from = Offset(b.x - camX, b.y - camY);
    final to = Offset(b.rallyX - camX, b.rallyY - camY);
    final line = Paint()
      ..color = const Color(0xCC3CFF3C)
      ..strokeWidth = 1.5;
    final d = to - from;
    final len = d.distance;
    if (len > 1) {
      final step = d / len;
      for (double t = 0; t < len; t += 10) {
        canvas.drawLine(from + step * t, from + step * (t + 6 < len ? t + 6 : len), line);
      }
    }
    final img = atlas.resolveColor(c.engine.cursorMarkerImage, 0, false, 0);
    if (img != null) {
      canvas.drawImage(img, Offset(to.dx - img.width / 2, to.dy - img.height / 2), _plain);
    } else {
      canvas.drawCircle(to, 6, line..style = PaintingStyle.stroke);
    }
  }

  void _drawPlacementGhost(Canvas canvas, double camX, double camY) {
    final type = c.buildTypeId;
    final p = c.pointer;
    if (c.mode != CommandMode.build || type == null || p == null || !c.pointerInside) return;
    final t = c.engine.unitType(type);
    final (tx, ty) = c.placementTile(c.screenToMap(p), type);
    final ok = c.canPlaceAt(type, tx, ty);
    final rect = Rect.fromLTWH(tx * 32 - camX, ty * 32 - camY, t.placementWidth.toDouble(), t.placementHeight.toDouble());
    canvas.drawRect(rect, Paint()..color = ok ? const Color(0x5538FF38) : const Color(0x55FF3030));
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = ok ? const Color(0xFF38FF38) : const Color(0xFFFF3030);
    for (double x = rect.left; x < rect.right; x += 32) {
      for (double y = rect.top; y < rect.bottom; y += 32) {
        canvas.drawRect(Rect.fromLTWH(x, y, 32, 32), grid);
      }
    }
  }

  @override
  bool shouldRepaint(covariant BwPainter oldDelegate) => oldDelegate.c != c;
}
