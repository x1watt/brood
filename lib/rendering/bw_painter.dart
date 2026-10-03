// lib/rendering/bw_painter.dart
//
// Draws the world: terrain, then the bridge's draw list in the exact order
// given (the engine already sorted it and positioned every frame's
// top-left), then UI overlays (building ghost, drag box). Modifiers are
// treated the way OpenBW's reference renderer (ui/ui.h draw_image) treats
// them: shadows darken, glows add light, cloaked images are translucent.

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

  static Color relationColor(int owner) => owner == GameController.myPlayer
      ? ownColor
      : owner == GameController.neutralPlayer
      ? neutralColor
      : enemyColor;

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

    final src = Rect.fromLTWH(camX, camY, size.width, size.height).intersect(
      Rect.fromLTWH(0, 0, terrain.widthPx.toDouble(), terrain.heightPx.toDouble()),
    );
    if (!src.isEmpty) {
      canvas.drawImageRect(terrain.image, src, src.shift(Offset(-camX, -camY)), _plain);
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
