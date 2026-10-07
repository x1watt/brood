import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('brood/files'); // MainActivity.kt

/// Whether [shareText] opens a share sheet here.
bool get canShare => Platform.isAndroid;

Future<void> openUrl(String url) async {
  try {
    if (Platform.isAndroid) {
      await _channel.invokeMethod('openUrl', url);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [url], mode: ProcessStartMode.detached);
    }
  } catch (_) {
    // No browser to open it with.
  }
}

/// Opens the share sheet with [text]. Returns false where there is none.
Future<bool> shareText(String text) async {
  if (!Platform.isAndroid) return false;
  try {
    await _channel.invokeMethod('shareText', text);
    return true;
  } catch (_) {
    return false;
  }
}
