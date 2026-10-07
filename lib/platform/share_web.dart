import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Whether [shareText] opens a share sheet here (phones' browsers do).
bool get canShare => web.window.navigator.has('share');

Future<void> openUrl(String url) async => web.window.open(url, '_blank');

/// Opens the browser's share sheet with [text]. Returns false where there
/// is none, or the player closed it.
Future<bool> shareText(String text) async {
  if (!canShare) return false;
  try {
    await web.window.navigator.share(web.ShareData(text: text)).toDart;
    return true;
  } catch (_) {
    return false;
  }
}
