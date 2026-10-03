// lib/platform/android_files.dart
//
// The "brood/files" channel of the Android app (MainActivity.kt): the app's
// folders, and importing the player's game folder through Android's folder
// picker.

import 'package:flutter/services.dart';

class AndroidFiles {
  static const _channel = MethodChannel('brood/files');

  static String? filesDir; // private app storage (settings, saves)
  static String? externalDir; // app storage reachable over USB (game files)

  static Future<void> load() async {
    if (filesDir != null) return;
    final dirs = await _channel.invokeMapMethod<String, String>('getDirs');
    filesDir = dirs?['files'];
    externalDir = dirs?['external'];
  }

  /// Returns an error message, or null when the files were copied.
  static Future<String?> pickGameFolder(void Function(int done, int total) progress) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'progress') {
        final args = (call.arguments as List).cast<int>();
        progress(args[0], args[1]);
      }
    });
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('pickGameFolder');
      return r?['error'] as String?;
    } on PlatformException catch (e) {
      return e.message ?? 'The folder could not be imported.';
    } finally {
      _channel.setMethodCallHandler(null);
    }
  }
}
