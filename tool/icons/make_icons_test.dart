// tool/icons/make_icons_test.dart
//
// Draws Brood's app icon and writes every size the platforms need:
//
//   flutter test tool/icons/make_icons_test.dart
//
// The design is original (no artwork from the game): a glowing alien eye
// with a slit pupil inside a gold hive cell, on black with a faint
// honeycomb. Outputs:
//   - Android: legacy mipmap-*/ic_launcher.png, and the adaptive icon's
//     layers mipmap-*/ic_launcher_background/foreground/monochrome.png
//     (monochrome is the themed icon; mipmap-anydpi-v26/ic_launcher.xml
//     puts them together)
//   - Web: favicon.png, icons/Icon-192/512.png and the maskable variants
//   - linux/runner/resources/brood.png: the Linux window icon

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _gold = Color(0xFFFFD54F);
const _amber = Color(0xFFFF8F00);
const _black = Color(0xFF000000);

enum _Layer { full, background, foreground, monochrome }

Path _hexagon(Offset c, double r) {
  final path = Path();
  for (int i = 0; i < 6; ++i) {
    final a = math.pi / 6 + i * math.pi / 3; // pointy top
    final p = c + Offset(math.cos(a), math.sin(a)) * r;
    i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
  }
  return path..close();
}

/// [size] is the square drawn; [scale] shrinks the emblem (adaptive and
/// maskable icons keep it inside their safe zone); [rounded] gives the
/// legacy icon its rounded corners.
void _paint(Canvas canvas, double size, {_Layer layer = _Layer.full, double scale = 1, bool rounded = false}) {
  final c = Offset(size / 2, size / 2);
  final mono = layer == _Layer.monochrome;

  if (layer == _Layer.full || layer == _Layer.background) {
    final rect = Offset.zero & Size(size, size);
    final shape = rounded ? RRect.fromRectAndRadius(rect, Radius.circular(size * 0.18)) : RRect.fromRectAndRadius(rect, Radius.zero);
    canvas.save();
    canvas.clipRRect(shape);
    canvas.drawRect(
      rect,
      Paint()..shader = ui.Gradient.radial(c, size * 0.75, [const Color(0xFF1C1712), _black], [0, 1]),
    );
    // Faint honeycomb behind the emblem.
    final cell = size * 0.13;
    final comb = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size * 0.006
      ..color = _gold.withValues(alpha: 0.07);
    final w = math.sqrt(3) * cell;
    for (int row = -1; row * cell * 1.5 < size + cell; ++row) {
      for (int col = -1; col * w < size + w; ++col) {
        final x = col * w + (row.isOdd ? w / 2 : 0);
        canvas.drawPath(_hexagon(Offset(x, row * cell * 1.5), cell), comb);
      }
    }
    canvas.restore();
  }
  if (layer == _Layer.background) return;

  final r = size * 0.36 * scale; // hive cell radius
  final cell = _hexagon(c, r);

  if (mono) {
    // Themed icons: one color, the system tints it. Cell ring plus the eye
    // with the pupil cut out.
    final white = Paint()..color = Colors.white;
    canvas.drawPath(
      cell,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.14
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.white,
    );
    canvas.drawPath(Path.combine(PathOperation.difference, _eye(c, r), _pupil(c, r)), white);
    return;
  }

  // Glow behind the cell.
  canvas.drawPath(
    cell,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.22
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.12)
      ..color = _amber.withValues(alpha: 0.55),
  );
  // Cell interior, slightly lit.
  canvas.drawPath(cell, Paint()..shader = ui.Gradient.radial(c, r, [const Color(0xFF2A1A0C), const Color(0xFF0A0705)], [0, 1]));
  // The gold ring.
  canvas.drawPath(
    cell,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.12
      ..strokeJoin = StrokeJoin.round
      ..shader = ui.Gradient.linear(c - Offset(0, r), c + Offset(0, r), [const Color(0xFFFFE9A6), _gold, _amber], [0, 0.45, 1]),
  );

  // The eye: hot center fading to deep red, with its own glow.
  final eye = _eye(c, r);
  canvas.drawPath(
    eye,
    Paint()
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.10)
      ..color = const Color(0xFFFF5A1F).withValues(alpha: 0.7),
  );
  canvas.drawPath(
    eye,
    Paint()
      ..shader = ui.Gradient.radial(c, r * 0.62, [const Color(0xFFFFF1B0), const Color(0xFFFFB300), const Color(0xFFE53A12), const Color(0xFF6E0E06)], [0, 0.3, 0.7, 1]),
  );
  canvas.drawPath(
    eye,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.03
      ..color = const Color(0xFF3A0703),
  );
  // Slit pupil and a glint.
  canvas.drawPath(_pupil(c, r), Paint()..color = const Color(0xFF080302));
  canvas.drawCircle(c + Offset(-r * 0.16, -r * 0.13), r * 0.055, Paint()..color = Colors.white.withValues(alpha: 0.85));
}

Path _eye(Offset c, double r) {
  final w = r * 0.72, h = r * 0.56;
  return Path()
    ..moveTo(c.dx - w, c.dy)
    ..quadraticBezierTo(c.dx, c.dy - h, c.dx + w, c.dy)
    ..quadraticBezierTo(c.dx, c.dy + h, c.dx - w, c.dy)
    ..close();
}

Path _pupil(Offset c, double r) {
  final w = r * 0.11, h = r * 0.27;
  return Path()
    ..moveTo(c.dx, c.dy - h)
    ..quadraticBezierTo(c.dx + w, c.dy, c.dx, c.dy + h)
    ..quadraticBezierTo(c.dx - w, c.dy, c.dx, c.dy - h)
    ..close();
}

Future<void> _write(String path, int px, {_Layer layer = _Layer.full, double scale = 1, bool rounded = false}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  _paint(canvas, px.toDouble(), layer: layer, scale: scale, rounded: rounded);
  final image = await recorder.endRecording().toImage(px, px);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(png!.buffer.asUint8List());
}

void main() {
  test('write the app icons', () async {
    const res = 'android/app/src/main/res';
    const densities = {'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0};
    for (final MapEntry(key: d, value: f) in densities.entries) {
      await _write('$res/mipmap-$d/ic_launcher.png', (48 * f).round(), rounded: true);
      // Adaptive layers are 108 dp, of which the inner 66 dp are always shown.
      await _write('$res/mipmap-$d/ic_launcher_background.png', (108 * f).round(), layer: _Layer.background);
      await _write('$res/mipmap-$d/ic_launcher_foreground.png', (108 * f).round(), layer: _Layer.foreground, scale: 0.68);
      await _write('$res/mipmap-$d/ic_launcher_monochrome.png', (108 * f).round(), layer: _Layer.monochrome, scale: 0.68);
    }
    await _write('web/favicon.png', 32);
    await _write('web/icons/Icon-192.png', 192, rounded: true);
    await _write('web/icons/Icon-512.png', 512, rounded: true);
    // Maskable: full bleed, emblem inside the central 80% circle.
    await _write('web/icons/Icon-maskable-192.png', 192, scale: 0.8);
    await _write('web/icons/Icon-maskable-512.png', 512, scale: 0.8);
    await _write('linux/runner/resources/brood.png', 256, rounded: true);
    await _write('build/icon_preview_1024.png', 1024, rounded: true);
  });
}
