// lib/net/lan_host.dart
//
// Sharing the game on the network from the desktop or Android app: the home
// server (lib/net/home_server.dart) in an isolate of its own. The browser
// can't serve, so there it is never available.

export 'lan_host_io.dart' if (dart.library.js_interop) 'lan_host_web.dart';
