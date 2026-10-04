// The blend worker on desktop and Android: a long-lived isolate.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../engine/bw_engine.dart';
import 'blend_worker.dart';
import 'terrain_blend.dart';

BlendWorker createBlendWorker(Uint8List? Function(String) readChk) => _IsolateWorker();

class _IsolateWorker implements BlendWorker {
  final Future<SendPort> _port;

  _IsolateWorker() : _port = _start();

  static Future<SendPort> _start() async {
    final ready = ReceivePort();
    await Isolate.spawn(_main, ready.sendPort);
    final port = await ready.first as SendPort;
    return port;
  }

  Future<Object?> _ask(List<Object?> message) async {
    final reply = ReceivePort();
    (await _port).send([...message, reply.sendPort]);
    final r = await reply.first;
    if (r is List && r.isNotEmpty && r.first == 'error') throw StateError(r[1] as String);
    return r;
  }

  @override
  Future<int> learn(int tileset, List<String> mapFiles, String exclude, Uint16List current, int w, int h) async =>
      await _ask(['learn', tileset, mapFiles, exclude, current, w, h]) as int;

  @override
  Future<BlendResult> blend(Int32List grid, int pw, int h, Map<int, Set<int>> forced, Set<int> keep) async {
    final r = await _ask([
      'blend',
      grid,
      pw,
      h,
      {for (final e in forced.entries) e.key: e.value.toList()},
      keep.toList(),
    ]) as List;
    return BlendResult(Map<int, int>.from(r[0] as Map), r[1] as int);
  }

  @override
  void dispose() {
    _port.then((p) => p.send(['stop']));
  }

  static void _main(SendPort ready) async {
    final inbox = ReceivePort();
    ready.send(inbox.sendPort);
    BwEngine? engine;
    var model = BlendModel();
    await for (final m in inbox) {
      final msg = m as List;
      if (msg.first == 'stop') break;
      final reply = msg.last as SendPort;
      try {
        switch (msg.first) {
          case 'learn':
            engine ??= await BwEngine.open();
            final e = engine;
            model = BlendModel();
            reply.send(await learnFrom(model, msg[1] as int, (msg[2] as List).cast<String>(), msg[3] as String, msg[4] as Uint16List,
                msg[5] as int, msg[6] as int, (f) => e.readMapFile(f, r'staredit\scenario.chk')));
          case 'blend':
            final forced = {for (final e in (msg[4] as Map).entries) e.key as int: Set<int>.of((e.value as List).cast<int>())};
            final r = model.blend(msg[1] as Int32List, msg[2] as int, msg[3] as int, forced, keep: Set<int>.of((msg[5] as List).cast<int>()));
            reply.send([r.changed, r.failed]);
        }
      } catch (e) {
        reply.send(['error', '$e']);
      }
    }
    inbox.close();
    engine?.dispose();
  }
}
