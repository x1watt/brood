// lib/engine/bw_engine_io.dart
//
// Dart-friendly wrapper over the generated FFI bindings (bw_bridge_gen.dart)
// for dart:ffi platforms (Linux desktop now, Android later with a different
// .so). Per-frame queries reuse native buffers allocated once, so the game
// loop doesn't allocate native memory every tick.

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bw_bridge_gen.dart';
import 'models.dart';

class BwBridgeException implements Exception {
  final String message;
  BwBridgeException(this.message);
  @override
  String toString() => 'BwBridgeException: $message';
}

class BwEngine {
  static const int _maxDrawItems = 16384;
  static const int _maxUnits = 4096;

  final BwBridgeBindings _b;
  final ffi.Pointer<bw_bridge_t> _h;
  final ffi.Pointer<bw_draw_item> _drawBuf = calloc<bw_draw_item>(_maxDrawItems);
  final ffi.Pointer<bw_unit_info> _unitBuf = calloc<bw_unit_info>(_maxUnits);
  final ffi.Pointer<bw_unit_info> _oneUnit = calloc<bw_unit_info>();
  final ffi.Pointer<ffi.Int32> _idBuf = calloc<ffi.Int32>(256);
  final ffi.Pointer<ffi.Int> _int1 = calloc<ffi.Int>();
  final ffi.Pointer<ffi.Int> _int2 = calloc<ffi.Int>();
  final Map<int, UnitTypeInfo> _typeInfoCache = {};
  bool _disposed = false;

  BwEngine._(this._b, this._h);

  factory BwEngine.open({String? libraryPath}) {
    final dylib = ffi.DynamicLibrary.open(libraryPath ?? _defaultLibraryPath());
    final bindings = BwBridgeBindings(dylib);
    final abi = bindings.bw_bridge_abi_version();
    if (abi != BW_BRIDGE_ABI_VERSION) {
      throw BwBridgeException(
        'bridge ABI mismatch: bindings expect $BW_BRIDGE_ABI_VERSION, library reports $abi. '
        'Rebuild engine/bridge and re-run `dart run ffigen --config ffigen.yaml`.',
      );
    }
    final handle = bindings.bw_bridge_create();
    if (handle == ffi.nullptr) throw BwBridgeException('bw_bridge_create returned null');
    return BwEngine._(bindings, handle);
  }

  // Next to the executable when bundled (linux/CMakeLists.txt installs it
  // into the bundle's lib/), otherwise the bridge's own build output.
  static String _defaultLibraryPath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = '$exeDir/lib/libbwbridge.so';
    if (File(bundled).existsSync()) return bundled;
    return '${Directory.current.path}/engine/bridge/build/libbwbridge.so';
  }

  void _check(bw_status status, String what) {
    if (status != bw_status.BW_OK) throw BwBridgeException('$what failed: $status');
  }

  bool _ok(bw_status status) => status == bw_status.BW_OK;

  // --- lifecycle ---

  void loadAssets(String dataDir) {
    final p = dataDir.toNativeUtf8();
    try {
      _check(_b.bw_bridge_load_assets(_h, p.cast()), 'loadAssets($dataDir)');
    } finally {
      calloc.free(p);
    }
  }

  void newMeleeGame(String mapFile, {int playerSlot = 0, int race = 1}) {
    final p = mapFile.toNativeUtf8();
    try {
      _check(_b.bw_bridge_new_melee_game(_h, p.cast(), playerSlot, race), 'newMeleeGame($mapFile)');
    } finally {
      calloc.free(p);
    }
  }

  void step(int frames) => _check(_b.bw_bridge_step(_h, frames), 'step');

  // --- scalars ---

  int get currentFrame => _b.bw_bridge_current_frame(_h);
  int minerals(int player) => _b.bw_bridge_minerals(_h, player);
  int gas(int player) => _b.bw_bridge_gas(_h, player);

  (double used, double available) supply(int player, int race) {
    _check(_b.bw_bridge_supply(_h, player, race, _int1, _int2), 'supply');
    return (_int1.value / 2.0, _int2.value / 2.0);
  }

  // --- rendering ---

  List<DrawItem> getDrawList(int selectedOwner, int viewX, int viewY, int viewW, int viewH) {
    final n = _b.bw_bridge_get_draw_list(_h, selectedOwner, viewX, viewY, viewW, viewH, _drawBuf, _maxDrawItems);
    if (n < 0) throw BwBridgeException('getDrawList failed');
    return List<DrawItem>.generate(n, (i) {
      final d = _drawBuf[i];
      return DrawItem(
        kind: d.kind,
        x: d.x,
        y: d.y,
        imageTypeId: d.image_type_id,
        frameIndex: d.frame_index,
        flipped: d.flipped != 0,
        colorIndex: d.color_index,
        owner: d.owner,
        modifier: d.modifier,
        colorShift: d.color_shift,
        unitId: d.unit_id,
        hpPermille: d.hp_permille,
        shieldPermille: d.shield_permille,
      );
    }, growable: false);
  }

  Uint8List getPalette() {
    final buf = calloc<ffi.Uint8>(1024);
    try {
      _check(_b.bw_bridge_get_palette(_h, buf, 1024), 'getPalette');
      return Uint8List.fromList(buf.asTypedList(1024));
    } finally {
      calloc.free(buf);
    }
  }

  Uint8List getPlayerColors() {
    final buf = calloc<ffi.Uint8>(128);
    try {
      _check(_b.bw_bridge_get_player_colors(_h, buf, 128), 'getPlayerColors');
      return Uint8List.fromList(buf.asTypedList(128));
    } finally {
      calloc.free(buf);
    }
  }

  /// rows x 256 palette indices; see bw_bridge_get_light_table.
  (Uint8List table, int rows) getLightTable(int lightIndex) {
    _check(_b.bw_bridge_get_light_table(_h, lightIndex, ffi.nullptr, 0, _int1), 'getLightTable');
    final rows = _int1.value;
    final size = rows * 256;
    final buf = calloc<ffi.Uint8>(size == 0 ? 1 : size);
    try {
      _check(_b.bw_bridge_get_light_table(_h, lightIndex, buf, size, _int1), 'getLightTable');
      return (Uint8List.fromList(buf.asTypedList(size)), rows);
    } finally {
      calloc.free(buf);
    }
  }

  int getImageFrameCount(int imageTypeId) {
    _check(_b.bw_bridge_get_image_frame_count(_h, imageTypeId, _int1), 'getImageFrameCount');
    return _int1.value;
  }

  (int width, int height) getImageFrameSize(int imageTypeId, int frameIndex) {
    _check(_b.bw_bridge_get_image_frame_size(_h, imageTypeId, frameIndex, _int1, _int2), 'getImageFrameSize');
    return (_int1.value, _int2.value);
  }

  Uint8List decodeImageFrame(int imageTypeId, int frameIndex, bool flipped) {
    final (w, h) = getImageFrameSize(imageTypeId, frameIndex);
    final size = w * h;
    final buf = calloc<ffi.Uint8>(size == 0 ? 1 : size);
    try {
      _check(_b.bw_bridge_decode_image_frame(_h, imageTypeId, frameIndex, flipped ? 1 : 0, buf, size), 'decodeImageFrame');
      return Uint8List.fromList(buf.asTypedList(size));
    } finally {
      calloc.free(buf);
    }
  }

  // --- terrain ---

  (int widthTiles, int heightTiles) getMapTileSize() {
    _check(_b.bw_bridge_get_map_tile_size(_h, _int1, _int2), 'getMapTileSize');
    return (_int1.value, _int2.value);
  }

  Uint16List getTileGrid(int widthTiles, int heightTiles) {
    final n = widthTiles * heightTiles;
    final buf = calloc<ffi.Uint16>(n);
    try {
      _check(_b.bw_bridge_get_tile_grid(_h, buf, n), 'getTileGrid');
      return Uint16List.fromList(buf.asTypedList(n));
    } finally {
      calloc.free(buf);
    }
  }

  Uint8List decodeMegatile(int megatileIndex) {
    const size = 32 * 32;
    final buf = calloc<ffi.Uint8>(size);
    try {
      _check(_b.bw_bridge_decode_megatile(_h, megatileIndex, buf, size), 'decodeMegatile');
      return Uint8List.fromList(buf.asTypedList(size));
    } finally {
      calloc.free(buf);
    }
  }

  // --- units ---

  UnitInfo _readUnit(bw_unit_info u) {
    final count = u.queue_count.clamp(0, 5);
    return UnitInfo(
      unitId: u.unit_id,
      typeId: u.unit_type_id,
      owner: u.owner,
      x: u.x,
      y: u.y,
      flags: u.flags,
      hp: u.hp,
      maxHp: u.max_hp,
      shields: u.shields,
      maxShields: u.max_shields,
      energy: u.energy,
      resources: u.resources,
      width: u.width,
      height: u.height,
      queue: List<int>.generate(count, (i) => u.queue[i], growable: false),
      progressPermille: u.progress_permille,
    );
  }

  List<UnitInfo> getUnits() {
    final n = _b.bw_bridge_get_units(_h, _unitBuf, _maxUnits);
    if (n < 0) throw BwBridgeException('getUnits failed');
    return List<UnitInfo>.generate(n, (i) => _readUnit(_unitBuf[i]), growable: false);
  }

  UnitInfo? getUnit(int unitId) {
    if (!_ok(_b.bw_bridge_get_unit(_h, unitId, _oneUnit))) return null;
    return _readUnit(_oneUnit.ref);
  }

  int pickUnitAt(int x, int y) => _b.bw_bridge_pick_unit_at(_h, x, y);

  UnitTypeInfo unitType(int typeId) {
    return _typeInfoCache.putIfAbsent(typeId, () {
      final p = calloc<bw_unit_type_info>();
      try {
        _check(_b.bw_bridge_get_unit_type_info(_h, typeId, p), 'unitType($typeId)');
        final t = p.ref;
        final chars = <int>[];
        for (int i = 0; i < 48; ++i) {
          final c = t.name[i];
          if (c == 0) break;
          chars.add(c);
        }
        return UnitTypeInfo(
          typeId: typeId,
          mineralCost: t.mineral_cost,
          gasCost: t.gas_cost,
          supplyRaw: t.supply_required_raw,
          buildTime: t.build_time,
          placementWidth: t.placement_width,
          placementHeight: t.placement_height,
          isBuilding: t.is_building != 0,
          isAddon: t.is_addon != 0,
          race: t.race,
          name: String.fromCharCodes(chars),
        );
      } finally {
        calloc.free(p);
      }
    });
  }

  // --- selection and commands ---

  void selectUnits(int owner, List<int> unitIds) {
    final n = unitIds.length > 256 ? 256 : unitIds.length;
    for (int i = 0; i < n; ++i) {
      _idBuf[i] = unitIds[i];
    }
    _check(_b.bw_bridge_select_units(_h, owner, _idBuf, n), 'selectUnits');
  }

  List<int> getSelectedUnits(int owner) {
    final n = _b.bw_bridge_get_selected_units(_h, owner, _idBuf, 256);
    if (n < 0) return const [];
    return List<int>.generate(n, (i) => _idBuf[i], growable: false);
  }

  /// Returns false when the engine refused the order.
  bool order(int owner, UnitOrder order, int x, int y, {int targetUnitId = 0, bool queue = false}) {
    return _ok(_b.bw_bridge_order(_h, owner, order.index, x, y, targetUnitId, queue ? 1 : 0));
  }

  /// Unit types the single selected unit can build or train right now.
  List<int> getBuildable(int owner) {
    final n = _b.bw_bridge_get_buildable(_h, owner, _idBuf, 256);
    if (n < 0) return const [];
    return List<int>.generate(n, (i) => _idBuf[i], growable: false);
  }

  bool train(int owner, int unitTypeId) => _ok(_b.bw_bridge_train(_h, owner, unitTypeId));

  bool canPlace(int owner, int unitTypeId, int tileX, int tileY) =>
      _b.bw_bridge_can_place(_h, owner, unitTypeId, tileX, tileY) != 0;

  bool build(int owner, int unitTypeId, int tileX, int tileY) =>
      _ok(_b.bw_bridge_build(_h, owner, unitTypeId, tileX, tileY));

  bool cancelLast(int owner) => _ok(_b.bw_bridge_cancel_last(_h, owner));

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _b.bw_bridge_destroy(_h);
    calloc.free(_drawBuf);
    calloc.free(_unitBuf);
    calloc.free(_oneUnit);
    calloc.free(_idBuf);
    calloc.free(_int1);
    calloc.free(_int2);
  }
}
