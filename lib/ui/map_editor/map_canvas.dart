// lib/ui/map_editor/map_canvas.dart
//
// The map editor's view of the map: terrain from the megatile atlas (one
// drawRawAtlas per page for the visible tiles), start locations and
// resources, and the current tool's preview. Mouse: the left button uses the
// tool, the middle or right button drags the map, the wheel zooms. Touch:
// one finger uses the tool, two move and zoom the map.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../maps/chk.dart';
import '../../maps/map_document.dart';
import '../../rendering/megatile_atlas.dart';

/// The eight player colors (red, blue, teal, purple, orange, brown, white,
/// yellow), as start locations show them.
const List<Color> editorPlayerColors = [
  Color(0xFFF40404),
  Color(0xFF0C48CC),
  Color(0xFF2CB494),
  Color(0xFF88409C),
  Color(0xFFF88C14),
  Color(0xFF703014),
  Color(0xFFCCE0D0),
  Color(0xFFFCFC38),
];

class EditorCamera extends ChangeNotifier {
  double x = 0, y = 0; // map pixel at the view's top-left
  double zoom = 0.5;
  Size view = Size.zero;

  static const double minZoom = 0.05, maxZoom = 2;

  Offset toMap(Offset local) => Offset(x + local.dx / zoom, y + local.dy / zoom);

  void panBy(Offset localDelta) {
    x -= localDelta.dx / zoom;
    y -= localDelta.dy / zoom;
    notifyListeners();
  }

  void zoomAt(Offset local, double factor) {
    final before = toMap(local);
    zoom = (zoom * factor).clamp(minZoom, maxZoom);
    x = before.dx - local.dx / zoom;
    y = before.dy - local.dy / zoom;
    notifyListeners();
  }

  void centerOn(Offset mapPos) {
    x = mapPos.dx - view.width / 2 / zoom;
    y = mapPos.dy - view.height / 2 / zoom;
    notifyListeners();
  }

  void fit(Size mapPx) {
    if (view.isEmpty) return;
    zoom = math.min(view.width / mapPx.width, view.height / mapPx.height).clamp(minZoom, maxZoom);
    centerOn(Offset(mapPx.width / 2, mapPx.height / 2));
  }
}

/// What the canvas draws on top of the map for the current tool.
class CanvasOverlay {
  final Set<int> strokeCells; // pair cells painted in the current stroke
  final Color strokeColor;
  final Rect? ghost; // map pixels: where a unit would go, or the brush
  final bool ghostOk;
  final ChkUnit? selected;
  final bool grid;
  const CanvasOverlay({this.strokeCells = const {}, this.strokeColor = Colors.blue, this.ghost, this.ghostOk = true, this.selected, this.grid = false});
}

/// A unit picture: image and the offset of its center.
class UnitSprite {
  final ui.Image image;
  const UnitSprite(this.image);
}

class MapCanvas extends StatefulWidget {
  final MapDocument doc;
  final MegatileAtlas atlas;
  final EditorCamera camera;
  final Map<int, UnitSprite> sprites; // by unit type
  final CanvasOverlay Function() overlay;
  final void Function(Offset mapPos) onDown;
  final void Function(Offset mapPos) onMove;
  final VoidCallback onUp;
  final void Function(Offset? mapPos) onHover;

  const MapCanvas({
    super.key,
    required this.doc,
    required this.atlas,
    required this.camera,
    required this.sprites,
    required this.overlay,
    required this.onDown,
    required this.onMove,
    required this.onUp,
    required this.onHover,
  });

  @override
  State<MapCanvas> createState() => _MapCanvasState();
}

class _MapCanvasState extends State<MapCanvas> {
  final Map<int, Offset> _touches = {};
  int? _toolPointer;
  int? _panPointer; // mouse middle/right drag
  double? _pinchStart;
  double _zoomStart = 1;

  bool get _twoFingers => _touches.length >= 2;

  void _down(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.touch) {
      _touches[e.pointer] = e.localPosition;
      if (_twoFingers) {
        // A second finger: the first one's stroke ends, the map moves.
        if (_toolPointer != null) {
          _toolPointer = null;
          widget.onUp();
        }
        _pinchStart = null;
        return;
      }
    } else if (e.buttons & (kMiddleMouseButton | kSecondaryMouseButton) != 0) {
      _panPointer = e.pointer;
      return;
    }
    if (e.buttons & kPrimaryButton != 0 || e.kind == PointerDeviceKind.touch) {
      _toolPointer = e.pointer;
      widget.onDown(widget.camera.toMap(e.localPosition));
    }
  }

  void _move(PointerMoveEvent e) {
    if (e.kind == PointerDeviceKind.touch && _touches.containsKey(e.pointer)) {
      final before = _centroid();
      _touches[e.pointer] = e.localPosition;
      if (_twoFingers) {
        final pts = _touches.values.take(2).toList();
        final dist = (pts[0] - pts[1]).distance;
        if (_pinchStart == null) {
          _pinchStart = dist;
          _zoomStart = widget.camera.zoom;
        }
        final c = _centroid();
        widget.camera.panBy(c - before);
        if (_pinchStart! > 10) widget.camera.zoomAt(c, (_zoomStart * dist / _pinchStart!) / widget.camera.zoom);
        return;
      }
    }
    if (e.pointer == _panPointer) {
      widget.camera.panBy(e.delta);
      return;
    }
    if (e.pointer == _toolPointer) widget.onMove(widget.camera.toMap(e.localPosition));
  }

  Offset _centroid() {
    if (_touches.isEmpty) return Offset.zero;
    final pts = _touches.values.take(2);
    return pts.reduce((a, b) => a + b) / pts.length.toDouble();
  }

  void _up(PointerEvent e) {
    _touches.remove(e.pointer);
    if (_touches.length < 2) _pinchStart = null;
    if (e.pointer == _panPointer) _panPointer = null;
    if (e.pointer == _toolPointer) {
      _toolPointer = null;
      widget.onUp();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final first = widget.camera.view.isEmpty;
        widget.camera.view = box.biggest;
        if (first) widget.camera.fit(Size(widget.doc.width * 32.0, widget.doc.height * 32.0));
        return MouseRegion(
          onHover: (e) => widget.onHover(widget.camera.toMap(e.localPosition)),
          onExit: (_) => widget.onHover(null),
          child: Listener(
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: _up,
            onPointerSignal: (s) {
              if (s is PointerScrollEvent) widget.camera.zoomAt(s.localPosition, s.scrollDelta.dy > 0 ? 1 / 1.15 : 1.15);
            },
            child: ClipRect(
              child: CustomPaint(
                size: box.biggest,
                painter: _MapPainter(widget.doc, widget.atlas, widget.camera, widget.sprites, widget.overlay),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MapPainter extends CustomPainter {
  final MapDocument doc;
  final MegatileAtlas atlas;
  final EditorCamera cam;
  final Map<int, UnitSprite> sprites;
  final CanvasOverlay Function() overlay;

  _MapPainter(this.doc, this.atlas, this.cam, this.sprites, this.overlay) : super(repaint: Listenable.merge([doc, cam]));

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF050505));
    canvas.save();
    canvas.scale(cam.zoom);
    canvas.translate(-cam.x, -cam.y);
    final x0 = math.max(0, (cam.x / 32).floor()), y0 = math.max(0, (cam.y / 32).floor());
    final x1 = math.min(doc.width, ((cam.x + size.width / cam.zoom) / 32).ceil());
    final y1 = math.min(doc.height, ((cam.y + size.height / cam.zoom) / 32).ceil());

    // Terrain: per atlas page, the visible tiles' transforms and sources.
    final perPage = <int, (List<double>, List<double>)>{};
    for (int ty = y0; ty < y1; ++ty) {
      for (int tx = x0; tx < x1; ++tx) {
        final m = doc.tileset.megatile(doc.tileAt(tx, ty));
        if (!atlas.has(m)) continue;
        final (page, src) = atlas.source(m);
        final lists = perPage.putIfAbsent(page, () => (<double>[], <double>[]));
        lists.$1.addAll([32 / 31, 0, tx * 32.0, ty * 32.0]);
        // Half a pixel in, so filtering never samples the next slot.
        lists.$2.addAll([src.left + 0.5, src.top + 0.5, src.right - 0.5, src.bottom - 0.5]);
      }
    }
    final paint = Paint()..filterQuality = cam.zoom < 1 ? FilterQuality.low : FilterQuality.none;
    perPage.forEach((page, lists) {
      final image = page < atlas.pages.length ? atlas.pages[page] : null;
      if (image == null) return;
      canvas.drawRawAtlas(image, Float32List.fromList(lists.$1), Float32List.fromList(lists.$2), null, null, null, paint);
    });

    final o = overlay();
    if (o.grid && cam.zoom >= 0.25) {
      final line = Paint()
        ..color = const Color(0x30FFFFFF)
        ..strokeWidth = 1 / cam.zoom;
      for (int tx = x0; tx <= x1; tx += 2) {
        canvas.drawLine(Offset(tx * 32.0, y0 * 32.0), Offset(tx * 32.0, y1 * 32.0), line);
      }
      for (int ty = y0; ty <= y1; ++ty) {
        canvas.drawLine(Offset(x0 * 32.0, ty * 32.0), Offset(x1 * 32.0, ty * 32.0), line);
      }
    }

    // The stroke being painted.
    if (o.strokeCells.isNotEmpty) {
      final fill = Paint()..color = o.strokeColor.withValues(alpha: 0.55);
      final pw = doc.width ~/ 2;
      for (final c in o.strokeCells) {
        canvas.drawRect(Rect.fromLTWH((c % pw) * 64.0, (c ~/ pw) * 32.0, 64, 32), fill);
      }
    }

    // Units: resources, then start locations on top.
    for (final u in doc.units) {
      if (!u.isResource) continue;
      _unit(canvas, u, o.selected == u);
    }
    for (final u in doc.units) {
      if (!u.isStart || u.owner >= 8) continue;
      _unit(canvas, u, o.selected == u);
    }

    if (o.ghost != null) {
      final r = o.ghost!;
      canvas.drawRect(r, Paint()..color = (o.ghostOk ? const Color(0x5532D25A) : const Color(0x55FF3B30)));
      canvas.drawRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 / cam.zoom
          ..color = o.ghostOk ? const Color(0xFF32D25A) : const Color(0xFFFF3B30),
      );
    }
    canvas.restore();
  }

  void _unit(Canvas canvas, ChkUnit u, bool selected) {
    final (fw, fh) = MapDocument.footprint(u.type);
    final box = Rect.fromCenter(center: Offset(u.x.toDouble(), u.y.toDouble()), width: fw * 32.0, height: fh * 32.0);
    final sprite = sprites[u.type];
    if (sprite != null) {
      final img = sprite.image;
      canvas.drawImage(img, Offset(u.x - img.width / 2, u.y - img.height / 2), Paint());
    }
    if (u.isStart) {
      final color = editorPlayerColors[u.owner];
      canvas.drawRect(box, Paint()..color = color.withValues(alpha: 0.25));
      canvas.drawRect(
        box,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(2, 2 / cam.zoom)
          ..color = color,
      );
      _label(canvas, 'P${u.owner + 1}', box.center, color, 28);
    } else if (cam.zoom >= 0.35) {
      _label(canvas, '${u.resources}', box.bottomCenter + const Offset(0, 7), u.isGeyser ? const Color(0xFF7CFC8C) : const Color(0xFF8CD8FF), 11);
    }
    if (selected) {
      canvas.drawRect(
        box.inflate(3),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(2, 2.5 / cam.zoom)
          ..color = const Color(0xFFFCE45C),
      );
    }
  }

  void _label(Canvas canvas, String text, Offset center, Color color, double size) {
    final scale = math.max(1.0, 1 / cam.zoom / 2);
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size * scale,
          fontWeight: FontWeight.w800,
          shadows: const [Shadow(blurRadius: 3, color: Colors.black), Shadow(blurRadius: 1, color: Colors.black)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_MapPainter old) => true;
}
