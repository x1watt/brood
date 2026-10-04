// lib/net/ws.dart
//
// A WebSocket carrying text messages: the browser's on the web, dart:io's
// elsewhere.

export 'ws_io.dart' if (dart.library.js_interop) 'ws_web.dart';
