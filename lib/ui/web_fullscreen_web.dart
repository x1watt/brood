import 'dart:js_interop';

import 'package:web/web.dart' as web;

bool get _isFullscreen => web.document.fullscreenElement != null;

Future<bool> webSetFullscreen(bool on) async {
  try {
    if (on && !_isFullscreen) await web.document.documentElement!.requestFullscreen().toDart;
    if (!on && _isFullscreen) await web.document.exitFullscreen().toDart;
  } catch (_) {
    // Browsers only allow it right after a click or key press.
  }
  return _isFullscreen;
}

Future<bool> webToggleFullscreen() => webSetFullscreen(!_isFullscreen);
