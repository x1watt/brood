// Plain-Dart mirrors of the bridge's structs (engine/bridge/include/bw_bridge.h),
// so nothing outside lib/engine touches dart:ffi types.

class DrawItem {
  static const int kindImage = 0;
  static const int kindSelectionCircle = 1;

  static const int modShadow = 10;
  static const int modGlow = 9;

  final int kind;
  final int x; // top-left of the frame, map pixels (already offset by the engine)
  final int y;
  final int imageTypeId;
  final int frameIndex;
  final bool flipped;
  final int colorIndex;
  final int owner;
  final int modifier;
  final int colorShift;
  final int unitId;
  final int hpPermille;
  final int shieldPermille;

  const DrawItem({
    required this.kind,
    required this.x,
    required this.y,
    required this.imageTypeId,
    required this.frameIndex,
    required this.flipped,
    required this.colorIndex,
    required this.owner,
    required this.modifier,
    required this.colorShift,
    required this.unitId,
    required this.hpPermille,
    required this.shieldPermille,
  });
}

class UnitInfo {
  static const int flagBuilding = 1;
  static const int flagResource = 2;
  static const int flagWorker = 4;
  static const int flagCompleted = 8;
  static const int flagFlyer = 16;
  static const int flagCanMove = 32;

  final int unitId;
  final int typeId;
  final int owner;
  final int x;
  final int y;
  final int flags;
  final int hp;
  final int maxHp;
  final int shields;
  final int maxShields;
  final int energy;
  final int resources;
  final int width;
  final int height;
  final List<int> queue;
  final int progressPermille;

  const UnitInfo({
    required this.unitId,
    required this.typeId,
    required this.owner,
    required this.x,
    required this.y,
    required this.flags,
    required this.hp,
    required this.maxHp,
    required this.shields,
    required this.maxShields,
    required this.energy,
    required this.resources,
    required this.width,
    required this.height,
    required this.queue,
    required this.progressPermille,
  });

  bool get isBuilding => flags & flagBuilding != 0;
  bool get isResource => flags & flagResource != 0;
  bool get isWorker => flags & flagWorker != 0;
  bool get isCompleted => flags & flagCompleted != 0;
  bool get isFlyer => flags & flagFlyer != 0;
  bool get canMove => flags & flagCanMove != 0;
}

class UnitTypeInfo {
  final int typeId;
  final int mineralCost;
  final int gasCost;
  final int supplyRaw;
  final int buildTime;
  final int placementWidth;
  final int placementHeight;
  final bool isBuilding;
  final bool isAddon;
  final int race;
  final String name;
  final int readySound;
  final int whatFirst, whatLast;
  final int pissedFirst, pissedLast;
  final int yesFirst, yesLast;

  const UnitTypeInfo({
    required this.typeId,
    required this.mineralCost,
    required this.gasCost,
    required this.supplyRaw,
    required this.buildTime,
    required this.placementWidth,
    required this.placementHeight,
    required this.isBuilding,
    required this.isAddon,
    required this.race,
    required this.name,
    required this.readySound,
    required this.whatFirst,
    required this.whatLast,
    required this.pissedFirst,
    required this.pissedLast,
    required this.yesFirst,
    required this.yesLast,
  });

  double get supply => supplyRaw / 2.0;

  /// Name without the race prefix ("Terran Supply Depot" -> "Supply Depot").
  String get shortName {
    for (final prefix in const ['Terran ', 'Protoss ', 'Zerg ']) {
      if (name.startsWith(prefix)) return name.substring(prefix.length);
    }
    return name;
  }
}

/// Orders accepted by BwEngine.order (BW_ORDER_* in bw_bridge.h; the
/// index is the wire value).
enum UnitOrder { smart, move, attack, stop, hold, patrol, returnCargo, repair }

/// Control group actions (BW_GROUP_* in bw_bridge.h).
enum GroupAction { assign, recall, add }

class SoundEvent {
  final int soundId;
  final bool hasPosition;
  final int x;
  final int y;
  final int unitTypeId;
  const SoundEvent(this.soundId, this.hasPosition, this.x, this.y, this.unitTypeId);
}

class SoundInfo {
  final int priority;
  final int flags;
  final int minVolume;
  final String filename;
  const SoundInfo(this.priority, this.flags, this.minVolume, this.filename);
}
