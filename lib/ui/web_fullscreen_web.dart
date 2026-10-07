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

/// A tab can't close itself: the page goes blank instead.
void webLeave() => web.window.location.replace('about:blank');

/// Goes full screen on the page's first click or key press (a browser allows
/// it only then).
void webFullscreenOnFirstInput() {
  late final JSFunction listener;
  listener = ((web.Event _) {
    web.document.removeEventListener('pointerup', listener);
    web.document.removeEventListener('keydown', listener);
    webSetFullscreen(true);
  }).toJS;
  web.document.addEventListener('pointerup', listener);
  web.document.addEventListener('keydown', listener);
}
