// lib/engine/bw_engine_io.dart
//
// Dart-friendly wrapper over the generated FFI bindings (bw_bridge_gen.dart)
// for dart:ffi platforms: Linux desktop today, Android later (same bindings,
// a different compiled .so). Not used on Flutter web — see bw_engine_web.dart
// (Phase 4b) and the bw_engine.dart facade that picks between them.

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bw_bridge_gen.dart';
import 'sprite_info.dart';

class BwBridgeException implements Exception {
  final String message;
  BwBridgeException(this.message);
  @override
  String toString() => 'BwBridgeException: $message';
}

class BwEngine {
  final BwBridgeBindings _bindings;
  final ffi.Pointer<bw_bridge_t> _handle;
  bool _disposed = false;

  BwEngine._(this._bindings, this._handle);

  /// Opens libbwbridge.so from [libraryPath] (an explicit path — this is not
  /// yet wired into the Linux Flutter bundle's normal library search path,
  /// see engine/README.md) and creates a new bridge instance.
  factory BwEngine.open({String? libraryPath}) {
    final path = libraryPath ?? _defaultLibraryPath();
    final dylib = ffi.DynamicLibrary.open(path);
    final bindings = BwBridgeBindings(dylib);

    final abi = bindings.bw_bridge_abi_version();
    if (abi != BW_BRIDGE_ABI_VERSION) {
      throw BwBridgeException(
        'bridge ABI mismatch: bindings expect $BW_BRIDGE_ABI_VERSION, library reports $abi. '
        'Re-run `dart run ffigen --config ffigen.yaml` after rebuilding the bridge.',
      );
    }

    final handle = bindings.bw_bridge_create();
    if (handle == ffi.nullptr) {
      throw BwBridgeException('bw_bridge_create returned null');
    }
    return BwEngine._(bindings, handle);
  }

  static String _defaultLibraryPath() {
    // Development default: the bridge's own CMake build output, built via
    // `cd engine/bridge && mkdir -p build && cd build && cmake .. && make`.
    // Not yet bundled with the Flutter app itself (Phase 3a follow-up).
    final here = Directory.current.path;
    return '$here/engine/bridge/build/libbwbridge.so';
  }

  void _check(bw_status status, String what) {
    if (status != bw_status.BW_OK) {
      throw BwBridgeException('$what failed: $status');
    }
  }

  void loadAssets(String dataDir) {
    final dataDirPtr = dataDir.toNativeUtf8();
    try {
      _check(_bindings.bw_bridge_load_assets(_handle, dataDirPtr.cast()), 'loadAssets');
    } finally {
      calloc.free(dataDirPtr);
    }
  }

  void newMeleeGame(String mapFile, {int playerSlot = 0, int race = 1}) {
    final mapFilePtr = mapFile.toNativeUtf8();
    try {
      _check(
        _bindings.bw_bridge_new_melee_game(_handle, mapFilePtr.cast(), playerSlot, race),
        'newMeleeGame',
      );
    } finally {
      calloc.free(mapFilePtr);
    }
  }

  void step(int frames) {
    _check(_bindings.bw_bridge_step(_handle, frames), 'step');
  }

  int get currentFrame => _bindings.bw_bridge_current_frame(_handle);
  int unitCount(int playerSlot) => _bindings.bw_bridge_unit_count(_handle, playerSlot);
  int minerals(int playerSlot) => _bindings.bw_bridge_minerals(_handle, playerSlot);
  int gas(int playerSlot) => _bindings.bw_bridge_gas(_handle, playerSlot);
  int get tilesetIndex => _bindings.bw_bridge_get_tileset_index(_handle);

  List<SpriteInfo> getVisibleSprites({int maxCount = 8192}) {
    final buf = calloc<bw_sprite_info>(maxCount);
    try {
      final n = _bindings.bw_bridge_get_visible_sprites(_handle, buf, maxCount);
      if (n < 0) throw BwBridgeException('getVisibleSprites failed');
      return List<SpriteInfo>.generate(n, (i) {
        final s = buf[i];
        return SpriteInfo(
          x: s.x,
          y: s.y,
          imageTypeId: s.image_type_id,
          frameIndex: s.frame_index,
          flipped: s.flipped != 0,
          owner: s.owner,
          elevationLevel: s.elevation_level,
          modifier: s.modifier,
        );
      });
    } finally {
      calloc.free(buf);
    }
  }

  /// 256 RGBA8888 entries (1024 bytes), the current tileset's palette.
  Uint8List getPalette() {
    final buf = calloc<ffi.Uint8>(1024);
    try {
      _check(_bindings.bw_bridge_get_palette(_handle, buf, 1024), 'getPalette');
      return Uint8List.fromList(buf.asTypedList(1024));
    } finally {
      calloc.free(buf);
    }
  }

  /// 16 players x 8 shades (128 bytes). playerColors[owner * 8 + i] is the
  /// palette index a decoded pixel index (8+i) should be remapped to for
  /// that owner.
  Uint8List getPlayerColors() {
    final buf = calloc<ffi.Uint8>(128);
    try {
      _check(_bindings.bw_bridge_get_player_colors(_handle, buf, 128), 'getPlayerColors');
      return Uint8List.fromList(buf.asTypedList(128));
    } finally {
      calloc.free(buf);
    }
  }

  (int width, int height) getImageFrameSize(int imageTypeId, int frameIndex) {
    final wPtr = calloc<ffi.Int>();
    final hPtr = calloc<ffi.Int>();
    try {
      _check(
        _bindings.bw_bridge_get_image_frame_size(_handle, imageTypeId, frameIndex, wPtr, hPtr),
        'getImageFrameSize',
      );
      return (wPtr.value, hPtr.value);
    } finally {
      calloc.free(wPtr);
      calloc.free(hPtr);
    }
  }

  /// width*height palette-index bytes (0-255; index 0 is transparent).
  /// Caller applies the palette (and, for indices 8-15, the player-color
  /// remap for the sprite's owner) — see sprite_atlas.dart.
  Uint8List decodeImageFrame(int imageTypeId, int frameIndex, bool flipped) {
    final (width, height) = getImageFrameSize(imageTypeId, frameIndex);
    final size = width * height;
    final buf = calloc<ffi.Uint8>(size);
    try {
      _check(
        _bindings.bw_bridge_decode_image_frame(_handle, imageTypeId, frameIndex, flipped ? 1 : 0, buf, size),
        'decodeImageFrame',
      );
      return Uint8List.fromList(buf.asTypedList(size));
    } finally {
      calloc.free(buf);
    }
  }

  void dispose() {
    if (_disposed) return;
    _bindings.bw_bridge_destroy(_handle);
    _disposed = true;
  }
}
