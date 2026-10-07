// lib/platform/share.dart
//
// Opening a link in the browser and handing text to the system's share
// sheet (Android's, or the browser's where it has one). Desktop has no
// share sheet: callers copy the text instead.

export 'share_io.dart' if (dart.library.js_interop) 'share_web.dart';
