import 'dart:async';
import 'dart:io';

/// Desktop and phones: a server named by BROOD_SERVER (e.g.
/// ws://192.168.1.20:9191/ws), else none.
Uri? defaultServer() {
  final s = Platform.environment['BROOD_SERVER'];
  return s == null || s.isEmpty ? null : Uri.tryParse(s);
}

class TextSocket {
  final WebSocket _ws;
  final _messages = StreamController<String>.broadcast();
  TextSocket._(this._ws) {
    _ws.listen((d) {
      if (d is String) _messages.add(d);
    }, onDone: _messages.close, onError: (_) => _messages.close());
  }

  static Future<TextSocket?> connect(Uri url) async {
    try {
      return TextSocket._(await WebSocket.connect(url.toString()).timeout(const Duration(seconds: 3)));
    } catch (_) {
      return null;
    }
  }

  Stream<String> get messages => _messages.stream;
  void send(String text) => _ws.add(text);
  void close() => _ws.close();
}
