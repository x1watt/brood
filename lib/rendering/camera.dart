// lib/rendering/camera.dart
//
// Minimal pan-only camera: a world-pixel offset subtracted from each
// sprite's map position to get a screen position. Zoom/clamping/following
// are later refinements (Phase 6).

class Camera {
  double x;
  double y;

  Camera({this.x = 0, this.y = 0});

  void pan(double dx, double dy) {
    x += dx;
    y += dy;
  }
}
