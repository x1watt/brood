// tool/brood_server.dart
//
// The home server (lib/net/home_server.dart) on its own: run it on one
// computer and open http://<that computer's address>:9191 on any computer,
// tablet or browser tab at home.
//
//   dart run tool/brood_server.dart [--port 9191] [--web build/web] [--data <game folder>]
//                                   [--stats <play_stats.json>]
//
// --stats defaults to the desktop app's own ($XDG_DATA_HOME/brood), so pages
// list the maps played most on this computer first.

import 'dart:io';

import 'package:brood/net/home_server.dart';

export 'package:brood/net/home_server.dart';

void main(List<String> args) async {
  String arg(String name, String fallback) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
  }

  final home = Platform.environment['HOME'] ?? '.';
  final port = int.parse(arg('port', '9191'));
  final webDir = Directory(arg('web', 'build/web'));
  final dataDir = Directory(arg('data', Platform.environment['BROOD_DATA'] ?? '$home/box/media/games/BROOD'));
  // (Agents and the desktop app need no pages.)
  if (!webDir.existsSync()) stderr.writeln('No ${webDir.path}: no browser version to serve (tool/build_web.sh builds it).');
  final xdg = Platform.environment['XDG_DATA_HOME'];
  final stats = File(arg('stats', '${xdg != null && xdg.isNotEmpty ? xdg : '$home/.local/share'}/brood/play_stats.json'));
  final server = await HomeServer.start(web: webDir, data: dataDir, stats: stats, port: port);
  stdout.writeln('Brood server on port $port. Open one of these:');
  stdout.writeln('  http://127.0.0.1:$port/');
  for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in i.addresses) {
      stdout.writeln('  http://${a.address}:$port/   (${i.name})');
    }
  }
  stdout.writeln(server.files.list.isEmpty
      ? 'No game files in ${dataDir.path}: pages will ask for the game folder.'
      : 'Game files from ${dataDir.path} (${server.files.list.length} files).');
}
