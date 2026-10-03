// lib/engine/bridge_open.dart
//
// Opens the platform's bridge: the native library through dart:ffi, or the
// WebAssembly module in the browser.

export 'bridge_open_io.dart' if (dart.library.js_interop) 'bridge_open_web.dart';
