import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;

Future<Uint8List> deflate(Uint8List data) => compute((Uint8List d) => Uint8List.fromList(ZLibCodec(level: 6).encode(d)), data);

Future<Uint8List> inflate(Uint8List data) => compute((Uint8List d) => Uint8List.fromList(ZLibCodec().decode(d)), data);
