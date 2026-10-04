import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<Uint8List> _through(Uint8List data, web.ReadableWritablePair stream) async {
  final source = web.Blob([data.toJS].toJS).stream().pipeThrough(stream);
  final buffer = await web.Response(source).arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}

Future<Uint8List> deflate(Uint8List data) => _through(data, web.CompressionStream('deflate') as web.ReadableWritablePair);

Future<Uint8List> inflate(Uint8List data) => _through(data, web.DecompressionStream('deflate') as web.ReadableWritablePair);
