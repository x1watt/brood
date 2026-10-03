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

  /// (used, available), both already divided down to normal display units.
  (double used, double available) supply(int playerSlot, int race) {
    final usedPtr = calloc<ffi.Int>();
    final availPtr = calloc<ffi.Int>();
    try {
      _check(_bindings.bw_bridge_supply(_handle, playerSlot, race, usedPtr, availPtr), 'supply');
      return (usedPtr.value / 2.0, availPtr.value / 2.0);
    } finally {
      calloc.free(usedPtr);
      calloc.free(availPtr);
    }
  }

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
          unitId: s.unit_id,
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

  int getImageFrameCount(int imageTypeId) {
    final countPtr = calloc<ffi.Int>();
    try {
      _check(_bindings.bw_bridge_get_image_frame_count(_handle, imageTypeId, countPtr), 'getImageFrameCount');
      return countPtr.value;
    } finally {
      calloc.free(countPtr);
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

  (int widthTiles, int heightTiles) getMapTileSize() {
    final wPtr = calloc<ffi.Int>();
    final hPtr = calloc<ffi.Int>();
    try {
      _check(_bindings.bw_bridge_get_map_tile_size(_handle, wPtr, hPtr), 'getMapTileSize');
      return (wPtr.value, hPtr.value);
    } finally {
      calloc.free(wPtr);
      calloc.free(hPtr);
    }
  }

  /// Row-major megatile index per tile position (widthTiles * heightTiles
  /// entries); pass each value to decodeMegatile.
  Uint16List getTileGrid(int widthTiles, int heightTiles) {
    final n = widthTiles * heightTiles;
    final buf = calloc<ffi.Uint16>(n);
    try {
      _check(_bindings.bw_bridge_get_tile_grid(_handle, buf, n), 'getTileGrid');
      return Uint16List.fromList(buf.asTypedList(n));
    } finally {
      calloc.free(buf);
    }
  }

  /// 32*32 = 1024 palette-index bytes for one megatile (no player-color
  /// remap — terrain isn't owned by a player).
  Uint8List decodeMegatile(int megatileIndex) {
    const size = 32 * 32;
    final buf = calloc<ffi.Uint8>(size);
    try {
      _check(_bindings.bw_bridge_decode_megatile(_handle, megatileIndex, buf, size), 'decodeMegatile');
      return Uint8List.fromList(buf.asTypedList(size));
    } finally {
      calloc.free(buf);
    }
  }

  /// Finds a unit whose sprite covers map position (x, y), or 0 if none.
  int pickUnitAt(int x, int y) => _bindings.bw_bridge_pick_unit_at(_handle, x, y);

  /// Replaces the player's selection (not a shift-add).
  void selectUnits(int owner, List<int> unitIds) {
    if (unitIds.isEmpty) {
      _check(_bindings.bw_bridge_select_units(_handle, owner, ffi.nullptr, 0), 'selectUnits');
      return;
    }
    final buf = calloc<ffi.Int32>(unitIds.length);
    try {
      for (int i = 0; i != unitIds.length; ++i) {
        buf[i] = unitIds[i];
      }
      _check(_bindings.bw_bridge_select_units(_handle, owner, buf, unitIds.length), 'selectUnits');
    } finally {
      calloc.free(buf);
    }
  }

  List<int> getSelectedUnits(int owner, {int maxCount = 12}) {
    final buf = calloc<ffi.Int32>(maxCount);
    try {
      final n = _bindings.bw_bridge_get_selected_units(_handle, owner, buf, maxCount);
      if (n < 0) throw BwBridgeException('getSelectedUnits failed');
      return List<int>.generate(n, (i) => buf[i]);
    } finally {
      calloc.free(buf);
    }
  }

  void orderMove(int owner, int x, int y, {bool queue = false}) {
    _check(_bindings.bw_bridge_order_move(_handle, owner, x, y, queue ? 1 : 0), 'orderMove');
  }

  /// "Smart click": attack/gather/follow/move, resolved by the engine based
  /// on what's at (x, y) — see bw_bridge.h.
  void orderRightClick(int owner, int x, int y, {int targetUnitId = 0, bool queue = false}) {
    _check(
      _bindings.bw_bridge_order_right_click(_handle, owner, x, y, targetUnitId, queue ? 1 : 0),
      'orderRightClick',
    );
  }

  void orderStop(int owner, {bool queue = false}) {
    _check(_bindings.bw_bridge_order_stop(_handle, owner, queue ? 1 : 0), 'orderStop');
  }

  void train(int owner, int unitTypeId) {
    _check(_bindings.bw_bridge_train(_handle, owner, unitTypeId), 'train');
  }

  void dispose() {
    if (_disposed) return;
    _bindings.bw_bridge_destroy(_handle);
    _disposed = true;
  }
}
