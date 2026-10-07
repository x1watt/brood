// The home server in a background isolate, so serving pages, game files and
// multiplayer never takes time from the game's frames. The browser version
// it serves ships with the app: data/web next to the Linux executable, the
// APK's assets/web on Android (copied into the app's storage, since the
// server reads files).

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../game/play_stats.dart';
import '../platform/android_files.dart';
import '../platform/storage_io.dart';
import 'home_server.dart';

class LanHost {
  static const bool supported = true;
  static LanHost? _current;

  /// The server this app runs, if it does.
  static LanHost? get current => _current;

  final SendPort _commands;
  final Isolate _isolate;
  final int port;

  /// Addresses others at home open in their browser.
  final List<String> urls;

  LanHost._(this._commands, this._isolate, this.port, this.urls);

  /// Starts serving the browser version and the game files from [dataDir]
  /// on port 9191 (or the next free one). Throws with a message the player
  /// can read when it can't.
  static Future<LanHost> start({required String dataDir}) async {
    final running = _current;
    if (running != null) return running;
    final web = await _webDir();
    if (web == null) throw StateError('This build has no browser version to share.');
    final replies = ReceivePort();
    final stats = FileStorage.fileOf(PlayStats.key).path;
    final isolate = await Isolate.spawn(_serve, [replies.sendPort, web, dataDir, stats], debugName: 'home server');
    final reply = await replies.first as Map<String, Object?>;
    replies.close();
    if (reply['error'] case final String error) {
      isolate.kill();
      throw StateError(error);
    }
    return _current = LanHost._(reply['commands'] as SendPort, isolate, reply['port'] as int, (reply['urls'] as List).cast<String>());
  }

  Future<void> stop() async {
    if (identical(_current, this)) _current = null;
    final done = ReceivePort();
    _isolate.addOnExitListener(done.sendPort);
    _commands.send('stop');
    // It closes its connections and exits; if not, it goes anyway.
    await done.first.timeout(const Duration(seconds: 2), onTimeout: () => _isolate.kill(priority: Isolate.immediate));
    done.close();
  }

  static Future<String?> _webDir() async {
    if (Platform.isAndroid) return AndroidFiles.installWebFiles();
    final dir = '${File(Platform.resolvedExecutable).parent.path}/data/web';
    return File('$dir/index.html').existsSync() ? dir : null;
  }
}

Future<void> _serve(List<Object> args) async {
  final reply = args[0] as SendPort;
  final HomeServer server;
  try {
    server = await HomeServer.start(
      web: Directory(args[1] as String),
      data: Directory(args[2] as String),
      stats: File(args[3] as String),
      tries: 10,
    );
  } catch (e) {
    reply.send({'error': e is SocketException ? 'No free network port (${e.message}).' : '$e'});
    return;
  }
  final commands = ReceivePort();
  reply.send({'commands': commands.sendPort, 'port': server.port, 'urls': server.urls});
  await commands.firstWhere((m) => m == 'stop');
  commands.close();
  await server.close();
  Isolate.exit();
}
