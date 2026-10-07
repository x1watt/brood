import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// The multiplayer server of the page's own origin (tool/brood_server.dart).
Uri? defaultServer() {
  final base = Uri.base;
  if (base.scheme != 'http' && base.scheme != 'https') return null;
  return Uri(scheme: base.scheme == 'https' ? 'wss' : 'ws', host: base.host, port: base.port, path: '/ws');
}

/// Whether the page came from a home server (lib/net/home_server.dart),
/// which answers home.json.
Future<bool> fromHomeServer() async => await fetchFromHome('home.json') != null;

/// A text the page's home server answers at [path], or null.
Future<String?> fetchFromHome(String path) async {
  try {
    final r = await web.window.fetch(path.toJS).toDart;
    return r.ok ? (await r.text().toDart).toDart : null;
  } catch (_) {
    return null;
  }
}

class TextSocket {
  final web.WebSocket _ws;
  final _messages = StreamController<String>.broadcast();
  TextSocket._(this._ws) {
    _ws.onmessage = ((web.MessageEvent e) {
      final d = e.data;
      if (d != null && d.isA<JSString>()) _messages.add((d as JSString).toDart);
    }).toJS;
    _ws.onclose = ((web.Event _) {
      _messages.close();
    }).toJS;
  }

  static Future<TextSocket?> connect(Uri url) async {
    final ws = web.WebSocket(url.toString());
    final opened = Completer<bool>();
    ws.onopen = ((web.Event _) {
      if (!opened.isCompleted) opened.complete(true);
    }).toJS;
    ws.onerror = ((web.Event _) {
      if (!opened.isCompleted) opened.complete(false);
    }).toJS;
    final ok = await opened.future.timeout(const Duration(seconds: 3), onTimeout: () => false);
    if (!ok) {
      ws.close();
      return null;
    }
    return TextSocket._(ws);
  }

  Stream<String> get messages => _messages.stream;
  void send(String text) {
    if (_ws.readyState == web.WebSocket.OPEN) _ws.send(text.toJS);
  }

  void close() => _ws.close();
}
