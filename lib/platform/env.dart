// lib/platform/env.dart
//
// Environment variables (desktop testing knobs such as BROOD_MUTE); the
// browser has none.

export 'env_io.dart' if (dart.library.js_interop) 'env_web.dart';
