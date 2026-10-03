// lib/ui/window_control.dart
//
// Fullscreen: through the Linux runner's "brood/window" channel
// (linux/runner/my_application.cc) on desktop, the browser's fullscreen API
// on the web.

import 'dart:ui' show AppExitType;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';

import 'web_fullscreen.dart';

class WindowControl {
  /// Leaves the app (desktop and Android; a browser tab can't).
  static Future<void> quit() async {
    if (kIsWeb) return;
    if (defaultTargetPlatform == TargetPlatform.android) {
      await SystemNavigator.pop();
    } else {
      await ServicesBinding.instance.exitApplication(AppExitType.required);
    }
  }

  static const _channel = MethodChannel('brood/window');

  static Future<bool> toggleFullscreen() async {
    if (kIsWeb) return webToggleFullscreen();
    try {
      return await _channel.invokeMethod<bool>('setFullscreen') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> setFullscreen(bool on) async {
    if (kIsWeb) return webSetFullscreen(on);
    try {
      return await _channel.invokeMethod<bool>('setFullscreen', on) ?? false;
    } on MissingPluginException {
      return false;
    }
  }
}
