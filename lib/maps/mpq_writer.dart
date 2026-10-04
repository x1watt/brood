// lib/maps/mpq_writer.dart
//
// Writes a map archive (.scm/.scx is an MPQ holding staredit\scenario.chk).
// Files are stored in 4096-byte sectors without compression but flagged as
// compressed with every sector raw, which is the form both OpenBW and the
// original game read; the hash and block tables are encrypted as usual.
// (The same writer as tool/make_island_map.py.)

import 'dart:convert';
import 'dart:typed_data';

const int _sector = 4096;
const int _mask = 0xFFFFFFFF;

final Uint32List _crypt = () {
  final t = Uint32List(0x500);
  int seed = 0x00100001;
  for (int i = 0; i < 0x100; ++i) {
    int j = i;
    for (int k = 0; k < 5; ++k) {
      seed = (seed * 125 + 3) % 0x2AAAAB;
      final a = (seed & 0xFFFF) << 16;
      seed = (seed * 125 + 3) % 0x2AAAAB;
      t[j] = (a | (seed & 0xFFFF)) & _mask;
      j += 0x100;
    }
  }
  return t;
}();

int mpqHash(String s, int kind) {
  int seed1 = 0x7FED7FED, seed2 = 0xEEEEEEEE;
  for (final ch in latin1.encode(s.toUpperCase())) {
    seed1 = (_crypt[(kind << 8) + ch] ^ ((seed1 + seed2) & _mask)) & _mask;
    seed2 = (ch + seed1 + seed2 + ((seed2 << 5) & _mask) + 3) & _mask;
  }
  return seed1;
}

void _encrypt(Uint32List words, int key) {
  int seed = 0xEEEEEEEE;
  for (int i = 0; i < words.length; ++i) {
    final v = words[i];
    seed = (seed + _crypt[0x400 + (key & 0xFF)]) & _mask;
    words[i] = (v ^ ((key + seed) & _mask)) & _mask;
    key = ((((~key & _mask) << 0x15) & _mask) + 0x11111111 & _mask | (key >> 0x0B)) & _mask;
    seed = (v + seed + ((seed << 5) & _mask) + 3) & _mask;
  }
}

/// An MPQ archive holding [files] (name, as the game asks for it, to
/// content). A file whose size is a multiple of the sector size can't be
/// stored this way; the caller pads it (a .chk takes an empty section).
Uint8List writeMpq(Map<String, Uint8List> files) {
  const headerSize = 32;
  final names = files.keys.toList();
  final data = BytesBuilder(copy: false);
  final blocks = <List<int>>[];
  for (final name in names) {
    final content = files[name]!;
    if (content.isNotEmpty && content.length % _sector == 0) {
      throw ArgumentError('$name: its size is a multiple of $_sector');
    }
    final n = (content.length + _sector - 1) ~/ _sector;
    final offsets = Uint32List(n + 1);
    offsets[0] = 4 * (n + 1);
    for (int k = 0; k < n; ++k) {
      final end = (k + 1) * _sector < content.length ? (k + 1) * _sector : content.length;
      offsets[k + 1] = offsets[k] + end - k * _sector;
    }
    final start = headerSize + data.length;
    data.add(offsets.buffer.asUint8List());
    data.add(content);
    blocks.add([start, offsets[n], content.length, 0x80000000 | 0x200]);
  }
  int hashSize = 16;
  while (hashSize < 2 * names.length) {
    hashSize *= 2;
  }
  final hash = Uint32List(hashSize * 4)..fillRange(0, hashSize * 4, _mask);
  for (int b = 0; b < names.length; ++b) {
    int i = mpqHash(names[b], 0) % hashSize;
    while (hash[i * 4 + 3] != _mask) {
      i = (i + 1) % hashSize;
    }
    hash[i * 4] = mpqHash(names[b], 1);
    hash[i * 4 + 1] = mpqHash(names[b], 2);
    hash[i * 4 + 2] = 0; // locale 0, platform 0
    hash[i * 4 + 3] = b;
  }
  final block = Uint32List(blocks.length * 4);
  for (int b = 0; b < blocks.length; ++b) {
    block.setRange(b * 4, b * 4 + 4, blocks[b]);
  }
  _encrypt(hash, mpqHash('(hash table)', 3));
  _encrypt(block, mpqHash('(block table)', 3));

  final hashOffset = headerSize + data.length;
  final blockOffset = hashOffset + hash.lengthInBytes;
  final total = blockOffset + block.lengthInBytes;
  final header = ByteData(headerSize);
  header.setUint32(0, 0x1A51504D, Endian.little); // "MPQ\x1a"
  header.setUint32(4, headerSize, Endian.little);
  header.setUint32(8, total, Endian.little);
  header.setUint16(12, 0, Endian.little); // format version
  header.setUint16(14, 3, Endian.little); // sectors of 512 << 3
  header.setUint32(16, hashOffset, Endian.little);
  header.setUint32(20, blockOffset, Endian.little);
  header.setUint32(24, hashSize, Endian.little);
  header.setUint32(28, blocks.length, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(header.buffer.asUint8List())
        ..add(data.toBytes())
        ..add(hash.buffer.asUint8List())
        ..add(block.buffer.asUint8List()))
      .toBytes();
}

/// A map archive with this scenario data (and a listfile, as editors write).
Uint8List writeMapArchive(Uint8List chk) {
  var scenario = chk;
  if (scenario.length % _sector == 0) {
    // An empty section the game skips, so the size is no longer a multiple.
    scenario = Uint8List.fromList([...scenario, 0x42, 0x52, 0x44, 0x20, 0, 0, 0, 0]); // "BRD "
  }
  var list = Uint8List.fromList(latin1.encode('staredit\\scenario.chk\r\n'));
  return writeMpq({'staredit\\scenario.chk': scenario, '(listfile)': list});
}
