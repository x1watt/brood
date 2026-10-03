// lib/engine/bw_engine.dart
//
// The engine API the game uses, on top of the raw bridge calls
// (bridge_raw.dart), the same code for every platform: dart:ffi on desktop
// and Android (bridge_raw_ffi.dart), WebAssembly in the browser
// (bridge_raw_web.dart). Structs are read from the engine's memory at the
// offsets in `_L` (checked against the C layout by test/engine_layout_test.dart).
// Per-frame queries reuse buffers allocated once.

import 'dart:convert';
import 'dart:typed_data';

import 'bridge_open.dart';
import 'bridge_raw.dart';
import 'models.dart';

class BwBridgeException implements Exception {
  final String message;
  BwBridgeException(this.message);
  @override
  String toString() => 'BwBridgeException: $message';
}

/// Byte offsets and sizes of the bridge's structs (bw_bridge.h). Every
/// field is a little-endian int32 unless noted.
abstract final class L {
  static const setupSize = 104, setupCount = 0, setupController = 4, setupRace = 36, setupTeam = 68, setupSeed = 100;

  static const drawSize = 52; // 13 fields in order: kind, x, y, image, frame, flipped, color, owner, modifier, shift, unit, hp, shield

  static const unitSize = 116;
  static const unitQueueCount = 56, unitQueue = 60, unitProgress = 80, unitMaxEnergy = 84, unitResearching = 88, unitUpgrading = 92;
  static const unitResearchProgress = 96, unitHasRally = 100, unitRallyX = 104, unitRallyY = 108, unitRallyUnit = 112;

  static const typeSize = 116, typeName = 40, typeNameLength = 48, typeReadySound = 88;

  static const techSize = 92, techName = 28, techNameLength = 64;
  static const upgradeSize = 92, upgradeName = 28, upgradeNameLength = 64;

  static const soundEventSize = 20;
  static const soundInfoSize = 92, soundInfoName = 12, soundInfoNameLength = 80;

  static const allianceSize = 112, alliancePoints = 88, allianceOwnPoints = 96, allianceKillScore = 104;
  static const allianceEventSize = 16;
}

class BwEngine {
  static const int _maxDrawItems = 16384;
  static const int _maxUnits = 4096;

  final BridgeRaw _r;
  final int _h;
  late final int _drawBuf = _r.malloc(_maxDrawItems * L.drawSize);
  late final int _unitBuf = _r.malloc(_maxUnits * L.unitSize);
  late final int _oneUnit = _r.malloc(L.unitSize);
  late final int _idBuf = _r.malloc(256 * 4);
  late final int _ints = _r.malloc(16); // out parameters
  late final int _soundBuf = _r.malloc(256 * L.soundEventSize);
  late final int _allianceBuf = _r.malloc(8 * L.allianceSize);
  late final int _allianceEvents = _r.malloc(64 * L.allianceEventSize);
  int _fogBuf = 0;
  int _fogCap = 0;
  final Map<int, UnitTypeInfo> _typeInfoCache = {};
  bool _disposed = false;

  BwEngine._(this._r, this._h);

  /// Opens the bridge for this platform and creates an engine instance.
  static Future<BwEngine> open() async {
    final raw = await openBridge();
    final abi = raw.bw_bridge_abi_version();
    if (abi != BW_BRIDGE_ABI_VERSION) {
      throw BwBridgeException('bridge ABI mismatch: Dart expects $BW_BRIDGE_ABI_VERSION, the engine reports $abi. '
          'Rebuild the engine and re-run tool/gen_bridge_raw.py.');
    }
    final handle = raw.bw_bridge_create();
    if (handle == 0) throw BwBridgeException('bw_bridge_create returned null');
    return BwEngine._(raw, handle);
  }

  // --- helpers ---

  static String _status(int s) => switch (s) {
    0 => 'ok',
    -1 => 'already loaded',
    -2 => 'not loaded',
    -3 => 'asset load failed',
    -4 => 'map load failed',
    -5 => 'no game',
    -6 => 'invalid argument',
    -7 => 'rejected',
    _ => 'error $s',
  };

  void _check(int status, String what) {
    if (status != 0) throw BwBridgeException('$what failed: ${_status(status)}');
  }

  bool _ok(int status) => status == 0;

  int _i32(int address) => _r.data(address, 4).getInt32(0, Endian.little);

  ByteData _d(int address, int length) => _r.data(address, length);

  T _withString<T>(String s, T Function(int p) f) {
    final bytes = utf8.encode(s);
    final p = _r.malloc(bytes.length + 1);
    try {
      _r.bytes(p, bytes.length + 1)
        ..setAll(0, bytes)
        ..[bytes.length] = 0;
      return f(p);
    } finally {
      _r.free(p);
    }
  }

  static String _cString(ByteData d, int offset, int max) {
    final chars = <int>[];
    for (int i = 0; i < max; ++i) {
      final c = d.getUint8(offset + i);
      if (c == 0) break;
      chars.add(c);
    }
    return String.fromCharCodes(chars);
  }

  Uint8List _copy(int address, int length) => Uint8List.fromList(_r.bytes(address, length));

  // --- lifecycle ---

  void loadAssets(String dataDir) => _withString(dataDir, (p) => _check(_r.bw_bridge_load_assets(_h, p), 'loadAssets($dataDir)'));

  void newMeleeGame(String mapFile, {int playerSlot = 0, int race = 1}) =>
      _withString(mapFile, (p) => _check(_r.bw_bridge_new_melee_game(_h, p, playerSlot, race), 'newMeleeGame($mapFile)'));

  /// Starts a game. [players]: exactly one human; races 0-2 (no random);
  /// equal non-zero teams are allied. Returns each player's slot (the player
  /// id for every other call), -1 for players the map has no start
  /// location for.
  List<int> newGame(String mapFile, List<({bool human, int race, int team})> players, int seed) {
    final s = _r.malloc(L.setupSize);
    final slots = _r.malloc(BW_MAX_PLAYERS * 4);
    try {
      final n = players.length.clamp(1, BW_MAX_PLAYERS);
      final d = _d(s, L.setupSize);
      d.setInt32(L.setupCount, n, Endian.little);
      for (int i = 0; i < n; ++i) {
        final pl = players[i];
        d.setInt32(L.setupController + i * 4, pl.human ? BW_PLAYER_HUMAN : BW_PLAYER_COMPUTER, Endian.little);
        d.setInt32(L.setupRace + i * 4, pl.race, Endian.little);
        d.setInt32(L.setupTeam + i * 4, pl.team, Endian.little);
      }
      d.setUint32(L.setupSeed, seed & 0xffffffff, Endian.little);
      _withString(mapFile, (p) => _check(_r.bw_bridge_new_game(_h, p, s, slots), 'newGame($mapFile)'));
      final out = _d(slots, n * 4);
      return List<int>.generate(n, (i) => out.getInt32(i * 4, Endian.little), growable: false);
    } finally {
      _r.free(s);
      _r.free(slots);
    }
  }

  void step(int frames) => _check(_r.bw_bridge_step(_h, frames), 'step');

  /// 0 playing, 1 dropped, 2 defeated, 3 or more victorious.
  int victoryState(int slot) => _r.bw_bridge_victory_state(_h, slot);

  /// Fog of war: draw list, unit list and picking as [slot] sees them
  /// (-1 shows everything).
  void setViewer(int slot) => _r.bw_bridge_set_viewer(_h, slot);

  /// One byte per tile: 0 unexplored, 1 explored, 2 in sight.
  Uint8List getFog(int slot, int tiles) {
    if (_fogCap < tiles) {
      if (_fogBuf != 0) _r.free(_fogBuf);
      _fogBuf = _r.malloc(tiles);
      _fogCap = tiles;
    }
    _check(_r.bw_bridge_get_fog(_h, slot, _fogBuf, tiles), 'getFog');
    return _copy(_fogBuf, tiles);
  }

  /// Every command given so far, for saving the game.
  List<int> commandLog() {
    final n = _r.bw_bridge_command_log(_h, 0, 0);
    if (n <= 0) return const [];
    final buf = _r.malloc(n * 4);
    try {
      if (_r.bw_bridge_command_log(_h, buf, n) != n) throw BwBridgeException('commandLog failed');
      final d = _d(buf, n * 4);
      return List<int>.generate(n, (i) => d.getInt32(i * 4, Endian.little), growable: false);
    } finally {
      _r.free(buf);
    }
  }

  /// Replays a saved command log up to [endFrame] (off the UI thread where
  /// the platform allows). Nothing else may use the engine until it ends.
  Future<void> replayCommands(List<int> log, int endFrame) async {
    final status = await _r.replayCommands(_h, Int32List.fromList(log), endFrame);
    if (status != 0) throw BwBridgeException('replayCommands failed: ${_status(status)}');
  }

  // --- scalars ---

  int get currentFrame => _r.bw_bridge_current_frame(_h);

  /// Show [owner]'s pylon psi fields in the draw list (-1 hides them).
  void showPsiFields(int owner) => _r.bw_bridge_show_psi_fields(_h, owner);
  int minerals(int player) => _r.bw_bridge_minerals(_h, player);
  int gas(int player) => _r.bw_bridge_gas(_h, player);

  (double used, double available) supply(int player, int race) {
    _check(_r.bw_bridge_supply(_h, player, race, _ints, _ints + 4), 'supply');
    final d = _d(_ints, 8);
    return (d.getInt32(0, Endian.little) / 2.0, d.getInt32(4, Endian.little) / 2.0);
  }

  // --- rendering ---

  List<DrawItem> getDrawList(int selectedOwner, int viewX, int viewY, int viewW, int viewH) {
    final n = _r.bw_bridge_get_draw_list(_h, selectedOwner, viewX, viewY, viewW, viewH, _drawBuf, _maxDrawItems);
    if (n < 0) throw BwBridgeException('getDrawList failed');
    final d = _d(_drawBuf, n * L.drawSize);
    return List<DrawItem>.generate(n, (i) {
      final o = i * L.drawSize;
      int f(int k) => d.getInt32(o + k * 4, Endian.little);
      return DrawItem(
        kind: f(0),
        x: f(1),
        y: f(2),
        imageTypeId: f(3),
        frameIndex: f(4),
        flipped: f(5) != 0,
        colorIndex: f(6),
        owner: f(7),
        modifier: f(8),
        colorShift: f(9),
        unitId: f(10),
        hpPermille: f(11),
        shieldPermille: f(12),
      );
    }, growable: false);
  }

  Uint8List getPalette() {
    final buf = _r.malloc(1024);
    try {
      _check(_r.bw_bridge_get_palette(_h, buf, 1024), 'getPalette');
      return _copy(buf, 1024);
    } finally {
      _r.free(buf);
    }
  }

  Uint8List getPlayerColors() {
    final buf = _r.malloc(128);
    try {
      _check(_r.bw_bridge_get_player_colors(_h, buf, 128), 'getPlayerColors');
      return _copy(buf, 128);
    } finally {
      _r.free(buf);
    }
  }

  /// rows x 256 palette indices; see bw_bridge_get_light_table.
  (Uint8List table, int rows) getLightTable(int lightIndex) {
    _check(_r.bw_bridge_get_light_table(_h, lightIndex, 0, 0, _ints), 'getLightTable');
    final rows = _i32(_ints);
    final size = rows * 256;
    final buf = _r.malloc(size == 0 ? 1 : size);
    try {
      _check(_r.bw_bridge_get_light_table(_h, lightIndex, buf, size, _ints), 'getLightTable');
      return (_copy(buf, size), rows);
    } finally {
      _r.free(buf);
    }
  }

  int getImageFrameCount(int imageTypeId) {
    _check(_r.bw_bridge_get_image_frame_count(_h, imageTypeId, _ints), 'getImageFrameCount');
    return _i32(_ints);
  }

  (int width, int height) getImageFrameSize(int imageTypeId, int frameIndex) {
    _check(_r.bw_bridge_get_image_frame_size(_h, imageTypeId, frameIndex, _ints, _ints + 4), 'getImageFrameSize');
    return (_i32(_ints), _i32(_ints + 4));
  }

  Uint8List decodeImageFrame(int imageTypeId, int frameIndex, bool flipped) {
    final (w, h) = getImageFrameSize(imageTypeId, frameIndex);
    final size = w * h;
    final buf = _r.malloc(size == 0 ? 1 : size);
    try {
      _check(_r.bw_bridge_decode_image_frame(_h, imageTypeId, frameIndex, flipped ? 1 : 0, buf, size), 'decodeImageFrame');
      return _copy(buf, size);
    } finally {
      _r.free(buf);
    }
  }

  // --- terrain ---

  (int widthTiles, int heightTiles) getMapTileSize() {
    _check(_r.bw_bridge_get_map_tile_size(_h, _ints, _ints + 4), 'getMapTileSize');
    return (_i32(_ints), _i32(_ints + 4));
  }

  Uint16List getTileGrid(int widthTiles, int heightTiles) {
    final n = widthTiles * heightTiles;
    final buf = _r.malloc(n * 2);
    try {
      _check(_r.bw_bridge_get_tile_grid(_h, buf, n), 'getTileGrid');
      final d = _d(buf, n * 2);
      return Uint16List.fromList(List<int>.generate(n, (i) => d.getUint16(i * 2, Endian.little)));
    } finally {
      _r.free(buf);
    }
  }

  Uint8List decodeMegatile(int megatileIndex) {
    const size = 32 * 32;
    final buf = _r.malloc(size);
    try {
      _check(_r.bw_bridge_decode_megatile(_h, megatileIndex, buf, size), 'decodeMegatile');
      return _copy(buf, size);
    } finally {
      _r.free(buf);
    }
  }

  // --- units ---

  static UnitInfo _readUnit(ByteData d, int o) {
    int f(int off) => d.getInt32(o + off, Endian.little);
    final count = f(L.unitQueueCount).clamp(0, 5);
    return UnitInfo(
      unitId: f(0),
      typeId: f(4),
      owner: f(8),
      x: f(12),
      y: f(16),
      flags: f(20),
      hp: f(24),
      maxHp: f(28),
      shields: f(32),
      maxShields: f(36),
      energy: f(40),
      resources: f(44),
      width: f(48),
      height: f(52),
      queue: List<int>.generate(count, (i) => f(L.unitQueue + i * 4), growable: false),
      progressPermille: f(L.unitProgress),
      maxEnergy: f(L.unitMaxEnergy),
      researchingTech: f(L.unitResearching),
      upgrading: f(L.unitUpgrading),
      researchProgressPermille: f(L.unitResearchProgress),
      hasRally: f(L.unitHasRally) != 0,
      rallyX: f(L.unitRallyX),
      rallyY: f(L.unitRallyY),
      rallyUnitId: f(L.unitRallyUnit),
    );
  }

  List<UnitInfo> getUnits() {
    final n = _r.bw_bridge_get_units(_h, _unitBuf, _maxUnits);
    if (n < 0) throw BwBridgeException('getUnits failed');
    final d = _d(_unitBuf, n * L.unitSize);
    return List<UnitInfo>.generate(n, (i) => _readUnit(d, i * L.unitSize), growable: false);
  }

  UnitInfo? getUnit(int unitId) {
    if (!_ok(_r.bw_bridge_get_unit(_h, unitId, _oneUnit))) return null;
    return _readUnit(_d(_oneUnit, L.unitSize), 0);
  }

  int pickUnitAt(int x, int y) => _r.bw_bridge_pick_unit_at(_h, x, y);

  UnitTypeInfo unitType(int typeId) {
    return _typeInfoCache.putIfAbsent(typeId, () {
      final p = _r.malloc(L.typeSize);
      try {
        _check(_r.bw_bridge_get_unit_type_info(_h, typeId, p), 'unitType($typeId)');
        final d = _d(p, L.typeSize);
        int f(int off) => d.getInt32(off, Endian.little);
        return UnitTypeInfo(
          typeId: typeId,
          mineralCost: f(0),
          gasCost: f(4),
          supplyRaw: f(8),
          buildTime: f(12),
          placementWidth: f(16),
          placementHeight: f(20),
          isBuilding: f(24) != 0,
          isAddon: f(28) != 0,
          race: f(32),
          requiresPower: f(36) != 0,
          name: _cString(d, L.typeName, L.typeNameLength),
          readySound: f(L.typeReadySound),
          whatFirst: f(L.typeReadySound + 4),
          whatLast: f(L.typeReadySound + 8),
          pissedFirst: f(L.typeReadySound + 12),
          pissedLast: f(L.typeReadySound + 16),
          yesFirst: f(L.typeReadySound + 20),
          yesLast: f(L.typeReadySound + 24),
        );
      } finally {
        _r.free(p);
      }
    });
  }

  // --- selection and commands ---

  void selectUnits(int owner, List<int> unitIds) {
    final n = unitIds.length > 256 ? 256 : unitIds.length;
    final d = _d(_idBuf, 256 * 4);
    for (int i = 0; i < n; ++i) {
      d.setInt32(i * 4, unitIds[i], Endian.little);
    }
    _check(_r.bw_bridge_select_units(_h, owner, _idBuf, n), 'selectUnits');
  }

  List<int> _ids(int n) {
    if (n <= 0) return const [];
    final d = _d(_idBuf, n * 4);
    return List<int>.generate(n, (i) => d.getInt32(i * 4, Endian.little), growable: false);
  }

  List<int> getSelectedUnits(int owner) => _ids(_r.bw_bridge_get_selected_units(_h, owner, _idBuf, 256));

  /// Returns false when the engine refused the order.
  bool order(int owner, UnitOrder order, int x, int y, {int targetUnitId = 0, bool queue = false}) =>
      _ok(_r.bw_bridge_order(_h, owner, order.index, x, y, targetUnitId, queue ? 1 : 0));

  /// Unit types the single selected unit can build or train right now.
  List<int> getBuildable(int owner) => _ids(_r.bw_bridge_get_buildable(_h, owner, _idBuf, 256));

  bool train(int owner, int unitTypeId) => _ok(_r.bw_bridge_train(_h, owner, unitTypeId));

  bool canPlace(int owner, int unitTypeId, int tileX, int tileY) => _r.bw_bridge_can_place(_h, owner, unitTypeId, tileX, tileY) != 0;

  bool build(int owner, int unitTypeId, int tileX, int tileY) => _ok(_r.bw_bridge_build(_h, owner, unitTypeId, tileX, tileY));

  bool cancelLast(int owner) => _ok(_r.bw_bridge_cancel_last(_h, owner));

  bool cancelQueueSlot(int owner, int slot) => _ok(_r.bw_bridge_cancel_queue_slot(_h, owner, slot));

  // --- research, upgrades, abilities ---

  TechInfo? techInfo(int owner, int techId) {
    final p = _r.malloc(L.techSize);
    try {
      if (!_ok(_r.bw_bridge_get_tech_info(_h, owner, techId, p))) return null;
      final d = _d(p, L.techSize);
      int f(int i) => d.getInt32(i * 4, Endian.little);
      return TechInfo(techId, f(0), f(1), f(2), f(3), f(4), f(5), f(6) != 0, _cString(d, L.techName, L.techNameLength));
    } finally {
      _r.free(p);
    }
  }

  UpgradeInfo? upgradeInfo(int owner, int upgradeId) {
    final p = _r.malloc(L.upgradeSize);
    try {
      if (!_ok(_r.bw_bridge_get_upgrade_info(_h, owner, upgradeId, p))) return null;
      final d = _d(p, L.upgradeSize);
      int f(int i) => d.getInt32(i * 4, Endian.little);
      return UpgradeInfo(upgradeId, f(0), f(1), f(2), f(3), f(4), f(5), f(6), _cString(d, L.upgradeName, L.upgradeNameLength));
    } finally {
      _r.free(p);
    }
  }

  List<int> getResearchable(int owner) => _ids(_r.bw_bridge_get_researchable(_h, owner, _idBuf, 256));
  List<int> getUpgradable(int owner) => _ids(_r.bw_bridge_get_upgradable(_h, owner, _idBuf, 256));

  bool research(int owner, int techId) => _ok(_r.bw_bridge_research(_h, owner, techId));
  bool upgrade(int owner, int upgradeId) => _ok(_r.bw_bridge_upgrade(_h, owner, upgradeId));
  bool canUseTech(int owner, int techId) => _r.bw_bridge_can_use_tech(_h, owner, techId) != 0;

  bool cast(int owner, int techId, int x, int y, {int targetUnitId = 0, bool queue = false}) =>
      _ok(_r.bw_bridge_cast(_h, owner, techId, x, y, targetUnitId, queue ? 1 : 0));

  bool ability(int owner, Ability a) => _ok(_r.bw_bridge_action(_h, owner, a.index));

  bool setRally(int owner, int x, int y, {int targetUnitId = 0}) => _ok(_r.bw_bridge_set_rally(_h, owner, x, y, targetUnitId));

  // --- alliances ---

  List<AlliancePlayer> alliances() {
    if (_r.bw_bridge_alliances(_h, _allianceBuf, 8) != 8) return const [];
    final d = _d(_allianceBuf, 8 * L.allianceSize);
    return List<AlliancePlayer>.generate(8, (i) {
      final o = i * L.allianceSize;
      int f(int k) => d.getInt32(o + k * 4, Endian.little);
      // Two halves: the web's JavaScript numbers have no 64-bit reads.
      int g(int off) => d.getUint32(o + off, Endian.little) + d.getInt32(o + off + 4, Endian.little) * 0x100000000;
      return AlliancePlayer(
        slot: i,
        playing: f(0) != 0,
        active: f(1) != 0,
        group: f(2),
        open: f(3) != 0,
        invitedBy: f(4),
        color: f(5),
        race: f(6),
        mineralsMined: f(7),
        gasMined: f(8),
        productionScore: f(9),
        unitsKilled: f(10),
        buildingsRazed: f(11),
        unitsLost: f(12),
        lord: f(13),
        surrenderFrom: f(14),
        fighting: f(15),
        name: f(16),
        armyValue: f(17),
        workers: f(18),
        mineralRate: f(19),
        gasRate: f(20),
        points: g(L.alliancePoints),
        ownPoints: g(L.allianceOwnPoints),
        killScore: g(L.allianceKillScore),
      );
    }, growable: false);
  }

  bool setAllianceOpen(int slot, bool open) => _ok(_r.bw_bridge_alliance_set_open(_h, slot, open ? 1 : 0));
  bool allianceInvite(int from, int to) => _ok(_r.bw_bridge_alliance_invite(_h, from, to));
  bool allianceRespond(int slot, int from, bool accept) => _ok(_r.bw_bridge_alliance_respond(_h, slot, from, accept ? 1 : 0));
  bool allianceLeave(int slot) => _ok(_r.bw_bridge_alliance_leave(_h, slot));
  bool offerSurrender(int from, int to) => _ok(_r.bw_bridge_alliance_surrender(_h, from, to));
  bool answerSurrender(int slot, int from, bool accept) => _ok(_r.bw_bridge_alliance_answer_surrender(_h, slot, from, accept ? 1 : 0));

  List<AllianceEvent> pollAllianceEvents() {
    final n = _r.bw_bridge_poll_alliance_events(_h, _allianceEvents, 64);
    if (n <= 0) return const [];
    final d = _d(_allianceEvents, n * L.allianceEventSize);
    return List<AllianceEvent>.generate(n, (i) {
      final o = i * L.allianceEventSize;
      int f(int k) => d.getInt32(o + k * 4, Endian.little);
      final kind = f(1) >= 0 && f(1) < AllianceEventKind.values.length ? AllianceEventKind.values[f(1)] : AllianceEventKind.none;
      return AllianceEvent(f(0), kind, f(2), f(3));
    }, growable: false);
  }

  // --- auto-play ---

  /// [modes]: AutoplayMode bits (0 turns auto-play off).
  bool setAutoplay(int slot, int modes) => _ok(_r.bw_bridge_set_autoplay(_h, slot, modes));
  int autoplay(int slot) => _r.bw_bridge_get_autoplay(_h, slot);

  // --- arbitrary UI graphics ---

  int grpLoad(String path) => _withString(path, (p) => _r.bw_bridge_grp_load(_h, p));

  int grpFrameCount(int handle) => _r.bw_bridge_grp_frame_count(_h, handle);

  (int, int, Uint8List)? grpFrame(int handle, int frame) {
    if (!_ok(_r.bw_bridge_grp_frame_size(_h, handle, frame, _ints, _ints + 4))) return null;
    final w = _i32(_ints), h = _i32(_ints + 4);
    final size = w * h;
    final buf = _r.malloc(size == 0 ? 1 : size);
    try {
      if (!_ok(_r.bw_bridge_grp_decode(_h, handle, frame, buf, size))) return null;
      return (w, h, _copy(buf, size));
    } finally {
      _r.free(buf);
    }
  }

  (int, int, Uint8List)? loadPcx(String path) {
    return _withString(path, (p) {
      if (!_ok(_r.bw_bridge_load_pcx(_h, p, 0, 0, _ints, _ints + 4))) return null;
      final w = _i32(_ints), h = _i32(_ints + 4);
      final buf = _r.malloc(w * h);
      try {
        if (!_ok(_r.bw_bridge_load_pcx(_h, p, buf, w * h, _ints, _ints + 4))) return null;
        return (w, h, _copy(buf, w * h));
      } finally {
        _r.free(buf);
      }
    });
  }

  bool controlGroup(int owner, int group, GroupAction action) => _ok(_r.bw_bridge_control_group(_h, owner, group, action.index));

  // --- feedback visuals ---

  int get cursorMarkerImage => _r.bw_bridge_cursor_marker_image();

  /// (image type, top-left x, top-left y) of [unitId]'s selection circle.
  (int, int, int)? selectionCircle(int unitId) {
    if (!_ok(_r.bw_bridge_get_selection_circle(_h, unitId, _ints, _ints + 4, _ints + 8))) return null;
    return (_i32(_ints), _i32(_ints + 4), _i32(_ints + 8));
  }

  // --- sound ---

  int get soundCount => _r.bw_bridge_sound_count(_h);

  SoundInfo? soundInfo(int soundId) {
    final p = _r.malloc(L.soundInfoSize);
    try {
      if (!_ok(_r.bw_bridge_get_sound_info(_h, soundId, p))) return null;
      final d = _d(p, L.soundInfoSize);
      int f(int i) => d.getInt32(i * 4, Endian.little);
      return SoundInfo(f(0), f(1), f(2), _cString(d, L.soundInfoName, L.soundInfoNameLength));
    } finally {
      _r.free(p);
    }
  }

  /// The sound's WAV file bytes, or null if it has none.
  Uint8List? loadSound(int soundId) {
    if (!_ok(_r.bw_bridge_load_sound(_h, soundId, 0, 0, _ints))) return null;
    final len = _i32(_ints);
    if (len <= 0) return null;
    final buf = _r.malloc(len);
    try {
      if (!_ok(_r.bw_bridge_load_sound(_h, soundId, buf, len, _ints))) return null;
      return _copy(buf, len);
    } finally {
      _r.free(buf);
    }
  }

  List<SoundEvent> pollSounds() {
    final n = _r.bw_bridge_poll_sounds(_h, _soundBuf, 256);
    if (n <= 0) return const [];
    final d = _d(_soundBuf, n * L.soundEventSize);
    return List<SoundEvent>.generate(n, (i) {
      final o = i * L.soundEventSize;
      int f(int k) => d.getInt32(o + k * 4, Endian.little);
      return SoundEvent(f(0), f(1) != 0, f(2), f(3), f(4));
    }, growable: false);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _r.bw_bridge_destroy(_h);
    for (final p in [_drawBuf, _unitBuf, _oneUnit, _idBuf, _ints, _soundBuf, _allianceBuf, _allianceEvents]) {
      _r.free(p);
    }
    if (_fogBuf != 0) _r.free(_fogBuf);
  }
}
