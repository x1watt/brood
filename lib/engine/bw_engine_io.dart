// lib/engine/bw_engine_io.dart
//
// Dart-friendly wrapper over the generated FFI bindings (bw_bridge_gen.dart)
// for dart:ffi platforms (Linux desktop now, Android later with a different
// .so). Per-frame queries reuse native buffers allocated once, so the game
// loop doesn't allocate native memory every tick.

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
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
  final String _libraryPath;
  final ffi.Pointer<bw_draw_item> _drawBuf = calloc<bw_draw_item>(_maxDrawItems);
  final ffi.Pointer<bw_unit_info> _unitBuf = calloc<bw_unit_info>(_maxUnits);
  final ffi.Pointer<bw_unit_info> _oneUnit = calloc<bw_unit_info>();
  final ffi.Pointer<ffi.Int32> _idBuf = calloc<ffi.Int32>(256);
  final ffi.Pointer<ffi.Int> _int1 = calloc<ffi.Int>();
  final ffi.Pointer<ffi.Int> _int2 = calloc<ffi.Int>();
  final ffi.Pointer<ffi.Int> _int3 = calloc<ffi.Int>();
  final ffi.Pointer<bw_sound_event> _soundBuf = calloc<bw_sound_event>(256);
  final Map<int, UnitTypeInfo> _typeInfoCache = {};
  bool _disposed = false;

  BwEngine._(this._b, this._h, this._libraryPath);

  factory BwEngine.open({String? libraryPath}) {
    final path = libraryPath ?? _defaultLibraryPath();
    final dylib = ffi.DynamicLibrary.open(path);
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
    return BwEngine._(bindings, handle, path);
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

  /// Starts a game. [players]: exactly one human; races 0-2 (no random);
  /// equal non-zero teams are allied. Returns each player's slot (the player
  /// id for every other call), -1 for players the map has no start
  /// location for.
  List<int> newGame(String mapFile, List<({bool human, int race, int team})> players, int seed) {
    final p = mapFile.toNativeUtf8();
    final s = calloc<bw_game_setup>();
    final slots = calloc<ffi.Int32>(BW_MAX_PLAYERS);
    try {
      final n = players.length.clamp(1, BW_MAX_PLAYERS);
      s.ref.player_count = n;
      for (int i = 0; i < n; ++i) {
        final pl = players[i];
        s.ref.controller[i] = pl.human ? BW_PLAYER_HUMAN : BW_PLAYER_COMPUTER;
        s.ref.race[i] = pl.race;
        s.ref.team[i] = pl.team;
      }
      s.ref.seed = seed;
      _check(_b.bw_bridge_new_game(_h, p.cast(), s, slots), 'newGame($mapFile)');
      return List<int>.generate(n, (i) => slots[i], growable: false);
    } finally {
      calloc.free(p);
      calloc.free(s);
      calloc.free(slots);
    }
  }

  void step(int frames) => _check(_b.bw_bridge_step(_h, frames), 'step');

  /// 0 playing, 1 dropped, 2 defeated, 3 or more victorious.
  int victoryState(int slot) => _b.bw_bridge_victory_state(_h, slot);

  /// Fog of war: draw list, unit list and picking as [slot] sees them
  /// (-1 shows everything).
  void setViewer(int slot) => _b.bw_bridge_set_viewer(_h, slot);

  ffi.Pointer<ffi.Uint8>? _fogBuf;
  int _fogCap = 0;

  /// One byte per tile: 0 unexplored, 1 explored, 2 in sight.
  Uint8List getFog(int slot, int tiles) {
    if (_fogCap < tiles) {
      if (_fogBuf != null) calloc.free(_fogBuf!);
      _fogBuf = calloc<ffi.Uint8>(tiles);
      _fogCap = tiles;
    }
    _check(_b.bw_bridge_get_fog(_h, slot, _fogBuf!, tiles), 'getFog');
    return Uint8List.fromList(_fogBuf!.asTypedList(tiles));
  }

  /// Every command given so far, for saving the game.
  List<int> commandLog() {
    final n = _b.bw_bridge_command_log(_h, ffi.nullptr, 0);
    if (n <= 0) return const [];
    final buf = calloc<ffi.Int32>(n);
    try {
      if (_b.bw_bridge_command_log(_h, buf, n) != n) throw BwBridgeException('commandLog failed');
      return List<int>.of(buf.asTypedList(n), growable: false);
    } finally {
      calloc.free(buf);
    }
  }

  /// Replays a saved command log up to [endFrame] on a background isolate
  /// (it simulates the whole game so far). Nothing else may use the engine
  /// until it completes.
  Future<void> replayCommands(List<int> log, int endFrame) async {
    final path = _libraryPath;
    final address = _h.address;
    final data = Int32List.fromList(log);
    final status = await Isolate.run(() => _replay(path, address, data, endFrame));
    if (status != bw_status.BW_OK.value) throw BwBridgeException('replayCommands failed: $status');
  }

  static int _replay(String path, int address, Int32List log, int endFrame) {
    final b = BwBridgeBindings(ffi.DynamicLibrary.open(path));
    final buf = calloc<ffi.Int32>(log.isEmpty ? 1 : log.length);
    try {
      buf.asTypedList(log.length).setAll(0, log);
      return b.bw_bridge_replay_commands(ffi.Pointer<bw_bridge_t>.fromAddress(address), buf, log.length, endFrame).value;
    } finally {
      calloc.free(buf);
    }
  }

  // --- scalars ---

  int get currentFrame => _b.bw_bridge_current_frame(_h);

  /// Show [owner]'s pylon psi fields in the draw list (-1 hides them).
  void showPsiFields(int owner) => _b.bw_bridge_show_psi_fields(_h, owner);
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
      maxEnergy: u.max_energy,
      researchingTech: u.researching_tech,
      upgrading: u.upgrading,
      researchProgressPermille: u.research_progress_permille,
      hasRally: u.has_rally != 0,
      rallyX: u.rally_x,
      rallyY: u.rally_y,
      rallyUnitId: u.rally_unit_id,
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
          requiresPower: t.requires_power != 0,
          readySound: t.ready_sound,
          whatFirst: t.what_first,
          whatLast: t.what_last,
          pissedFirst: t.pissed_first,
          pissedLast: t.pissed_last,
          yesFirst: t.yes_first,
          yesLast: t.yes_last,
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

  bool cancelQueueSlot(int owner, int slot) => _ok(_b.bw_bridge_cancel_queue_slot(_h, owner, slot));

  // --- research, upgrades, abilities ---

  static String _cString(ffi.Array<ffi.Char> a, int max) {
    final chars = <int>[];
    for (int i = 0; i < max; ++i) {
      final c = a[i];
      if (c == 0) break;
      chars.add(c);
    }
    return String.fromCharCodes(chars);
  }

  TechInfo? techInfo(int owner, int techId) {
    final p = calloc<bw_tech_info>();
    try {
      if (!_ok(_b.bw_bridge_get_tech_info(_h, owner, techId, p))) return null;
      final t = p.ref;
      return TechInfo(techId, t.mineral_cost, t.gas_cost, t.research_time, t.energy_cost, t.icon, t.race, t.researched != 0, _cString(t.name, 64));
    } finally {
      calloc.free(p);
    }
  }

  UpgradeInfo? upgradeInfo(int owner, int upgradeId) {
    final p = calloc<bw_upgrade_info>();
    try {
      if (!_ok(_b.bw_bridge_get_upgrade_info(_h, owner, upgradeId, p))) return null;
      final t = p.ref;
      return UpgradeInfo(upgradeId, t.mineral_cost, t.gas_cost, t.time, t.icon, t.race, t.level, t.max_level, _cString(t.name, 64));
    } finally {
      calloc.free(p);
    }
  }

  List<int> getResearchable(int owner) {
    final n = _b.bw_bridge_get_researchable(_h, owner, _idBuf, 256);
    return n <= 0 ? const [] : List<int>.generate(n, (i) => _idBuf[i], growable: false);
  }

  List<int> getUpgradable(int owner) {
    final n = _b.bw_bridge_get_upgradable(_h, owner, _idBuf, 256);
    return n <= 0 ? const [] : List<int>.generate(n, (i) => _idBuf[i], growable: false);
  }

  bool research(int owner, int techId) => _ok(_b.bw_bridge_research(_h, owner, techId));
  bool upgrade(int owner, int upgradeId) => _ok(_b.bw_bridge_upgrade(_h, owner, upgradeId));
  bool canUseTech(int owner, int techId) => _b.bw_bridge_can_use_tech(_h, owner, techId) != 0;

  bool cast(int owner, int techId, int x, int y, {int targetUnitId = 0, bool queue = false}) =>
      _ok(_b.bw_bridge_cast(_h, owner, techId, x, y, targetUnitId, queue ? 1 : 0));

  bool ability(int owner, Ability a) => _ok(_b.bw_bridge_action(_h, owner, a.index));

  bool setRally(int owner, int x, int y, {int targetUnitId = 0}) => _ok(_b.bw_bridge_set_rally(_h, owner, x, y, targetUnitId));

  // --- alliances ---

  final ffi.Pointer<bw_alliance_player> _allianceBuf = calloc<bw_alliance_player>(8);
  final ffi.Pointer<bw_alliance_event> _allianceEvents = calloc<bw_alliance_event>(64);

  List<AlliancePlayer> alliances() {
    if (_b.bw_bridge_alliances(_h, _allianceBuf, 8) != 8) return const [];
    return List<AlliancePlayer>.generate(8, (i) {
      final a = _allianceBuf[i];
      return AlliancePlayer(
        slot: i,
        playing: a.playing != 0,
        active: a.active != 0,
        group: a.group,
        open: a.open != 0,
        invitedBy: a.invited_by,
        color: a.color,
        race: a.race,
        mineralsMined: a.minerals_mined,
        gasMined: a.gas_mined,
        points: a.points,
        ownPoints: a.own_points,
        productionScore: a.production_score,
        killScore: a.kill_score,
        unitsKilled: a.units_killed,
        buildingsRazed: a.buildings_razed,
        unitsLost: a.units_lost,
        lord: a.lord,
        surrenderFrom: a.surrender_from,
        fighting: a.fighting,
        name: a.name,
        armyValue: a.army_value,
        workers: a.workers,
        mineralRate: a.mineral_rate,
        gasRate: a.gas_rate,
      );
    }, growable: false);
  }

  bool setAllianceOpen(int slot, bool open) => _ok(_b.bw_bridge_alliance_set_open(_h, slot, open ? 1 : 0));
  bool allianceInvite(int from, int to) => _ok(_b.bw_bridge_alliance_invite(_h, from, to));
  bool allianceRespond(int slot, int from, bool accept) => _ok(_b.bw_bridge_alliance_respond(_h, slot, from, accept ? 1 : 0));
  bool allianceLeave(int slot) => _ok(_b.bw_bridge_alliance_leave(_h, slot));
  bool offerSurrender(int from, int to) => _ok(_b.bw_bridge_alliance_surrender(_h, from, to));
  bool answerSurrender(int slot, int from, bool accept) => _ok(_b.bw_bridge_alliance_answer_surrender(_h, slot, from, accept ? 1 : 0));

  List<AllianceEvent> pollAllianceEvents() {
    final n = _b.bw_bridge_poll_alliance_events(_h, _allianceEvents, 64);
    if (n <= 0) return const [];
    return List<AllianceEvent>.generate(n, (i) {
      final e = _allianceEvents[i];
      final kind = e.kind >= 0 && e.kind < AllianceEventKind.values.length ? AllianceEventKind.values[e.kind] : AllianceEventKind.none;
      return AllianceEvent(e.frame, kind, e.a, e.b);
    }, growable: false);
  }

  // --- auto-play ---

  /// [modes]: AutoplayMode bits (0 turns auto-play off).
  bool setAutoplay(int slot, int modes) => _ok(_b.bw_bridge_set_autoplay(_h, slot, modes));
  int autoplay(int slot) => _b.bw_bridge_get_autoplay(_h, slot);

  // --- arbitrary UI graphics ---

  int grpLoad(String path) {
    final p = path.toNativeUtf8();
    try {
      return _b.bw_bridge_grp_load(_h, p.cast());
    } finally {
      calloc.free(p);
    }
  }

  int grpFrameCount(int handle) => _b.bw_bridge_grp_frame_count(_h, handle);

  (int, int, Uint8List)? grpFrame(int handle, int frame) {
    if (!_ok(_b.bw_bridge_grp_frame_size(_h, handle, frame, _int1, _int2))) return null;
    final w = _int1.value, h = _int2.value;
    final size = w * h;
    final buf = calloc<ffi.Uint8>(size == 0 ? 1 : size);
    try {
      if (!_ok(_b.bw_bridge_grp_decode(_h, handle, frame, buf, size))) return null;
      return (w, h, Uint8List.fromList(buf.asTypedList(size)));
    } finally {
      calloc.free(buf);
    }
  }

  (int, int, Uint8List)? loadPcx(String path) {
    final p = path.toNativeUtf8();
    try {
      if (!_ok(_b.bw_bridge_load_pcx(_h, p.cast(), ffi.nullptr, 0, _int1, _int2))) return null;
      final w = _int1.value, h = _int2.value;
      final buf = calloc<ffi.Uint8>(w * h);
      try {
        if (!_ok(_b.bw_bridge_load_pcx(_h, p.cast(), buf, w * h, _int1, _int2))) return null;
        return (w, h, Uint8List.fromList(buf.asTypedList(w * h)));
      } finally {
        calloc.free(buf);
      }
    } finally {
      calloc.free(p);
    }
  }

  bool controlGroup(int owner, int group, GroupAction action) =>
      _ok(_b.bw_bridge_control_group(_h, owner, group, action.index));

  // --- feedback visuals ---

  int get cursorMarkerImage => _b.bw_bridge_cursor_marker_image();

  /// (image type, top-left x, top-left y) of [unitId]'s selection circle.
  (int, int, int)? selectionCircle(int unitId) {
    if (!_ok(_b.bw_bridge_get_selection_circle(_h, unitId, _int1, _int2, _int3))) return null;
    return (_int1.value, _int2.value, _int3.value);
  }

  // --- sound ---

  int get soundCount => _b.bw_bridge_sound_count(_h);

  SoundInfo? soundInfo(int soundId) {
    final p = calloc<bw_sound_info>();
    try {
      if (!_ok(_b.bw_bridge_get_sound_info(_h, soundId, p))) return null;
      final chars = <int>[];
      for (int i = 0; i < 80; ++i) {
        final c = p.ref.filename[i];
        if (c == 0) break;
        chars.add(c);
      }
      return SoundInfo(p.ref.priority, p.ref.flags, p.ref.min_volume, String.fromCharCodes(chars));
    } finally {
      calloc.free(p);
    }
  }

  /// The sound's WAV file bytes, or null if it has none.
  Uint8List? loadSound(int soundId) {
    if (!_ok(_b.bw_bridge_load_sound(_h, soundId, ffi.nullptr, 0, _int1))) return null;
    final len = _int1.value;
    if (len <= 0) return null;
    final buf = calloc<ffi.Uint8>(len);
    try {
      if (!_ok(_b.bw_bridge_load_sound(_h, soundId, buf, len, _int1))) return null;
      return Uint8List.fromList(buf.asTypedList(len));
    } finally {
      calloc.free(buf);
    }
  }

  List<SoundEvent> pollSounds() {
    final n = _b.bw_bridge_poll_sounds(_h, _soundBuf, 256);
    if (n <= 0) return const [];
    return List<SoundEvent>.generate(n, (i) {
      final e = _soundBuf[i];
      return SoundEvent(e.sound_id, e.has_position != 0, e.x, e.y, e.unit_type_id);
    }, growable: false);
  }

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
    calloc.free(_int3);
    calloc.free(_soundBuf);
    if (_fogBuf != null) calloc.free(_fogBuf!);
    calloc.free(_allianceBuf);
    calloc.free(_allianceEvents);
  }
}
