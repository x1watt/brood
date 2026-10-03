// lib/ui/window_control.dart
//
// Fullscreen through the Linux runner's "brood/window" channel
// (linux/runner/my_application.cc).

import 'package:flutter/services.dart';

class WindowControl {
  static const _channel = MethodChannel('brood/window');

  static Future<bool> toggleFullscreen() async {
    try {
      return await _channel.invokeMethod<bool>('setFullscreen') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> setFullscreen(bool on) async {
    try {
      return await _channel.invokeMethod<bool>('setFullscreen', on) ?? false;
    } on MissingPluginException {
      return false;
    }
  }
}
