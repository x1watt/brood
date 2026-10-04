// lib/platform/compress.dart
//
// zlib compression for saved game states: dart:io's zlib (in a background
// isolate) on desktop and Android, the browser's CompressionStream on the
// web.

export 'compress_io.dart' if (dart.library.js_interop) 'compress_web.dart';
