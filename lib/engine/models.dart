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
  static const int flagCloaked = 64;
  static const int flagBurrowed = 128;
  static const int flagStimmed = 256;

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
  final int maxEnergy;
  final int researchingTech; // -1 if none
  final int upgrading; // -1 if none
  final int researchProgressPermille;
  final bool hasRally;
  final int rallyX;
  final int rallyY;
  final int rallyUnitId;

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
    required this.maxEnergy,
    required this.researchingTech,
    required this.upgrading,
    required this.researchProgressPermille,
    required this.hasRally,
    required this.rallyX,
    required this.rallyY,
    required this.rallyUnitId,
  });

  bool get isCloaked => flags & flagCloaked != 0;
  bool get isBurrowed => flags & flagBurrowed != 0;
  bool get isBusyResearching => researchingTech >= 0 || upgrading >= 0;

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
  final bool requiresPower;
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
    required this.requiresPower,
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

class TechInfo {
  final int id;
  final int mineralCost;
  final int gasCost;
  final int researchTime;
  final int energyCost;
  final int icon;
  final int race;
  final bool researched;
  final String name;
  const TechInfo(this.id, this.mineralCost, this.gasCost, this.researchTime, this.energyCost, this.icon, this.race, this.researched, this.name);
}

class UpgradeInfo {
  final int id;
  final int mineralCost; // next level
  final int gasCost;
  final int time;
  final int icon;
  final int race;
  final int level;
  final int maxLevel;
  final String name;
  const UpgradeInfo(this.id, this.mineralCost, this.gasCost, this.time, this.icon, this.race, this.level, this.maxLevel, this.name);
}

/// Instant abilities (BW_ACT_* in bw_bridge.h; index is the wire value).
enum Ability { stim, siege, unsiege, cloak, decloak, burrow, unburrow, trainFighter, archonWarp, darkArchonMeld, unloadAll, cancelResearch, cancelUpgrade }

/// One player's alliance standing (bw_alliance_player).
class AlliancePlayer {
  final int slot;
  final bool playing;
  final bool active;
  final int group; // equal groups are allied
  final bool open;
  final int invitedBy; // bit mask of slots waiting for this player's answer
  final int color;
  final int race;
  final int mineralsMined;
  final int gasMined;
  final int points; // mining score: shared within an alliance
  final int ownPoints; // mined by this player's own workers
  final int productionScore; // Brood War's unit and building score
  final int killScore; // Brood War's destroy score of what it destroyed
  final int unitsKilled;
  final int buildingsRazed;
  final int unitsLost;
  final int lord; // -1, or whom this player surrendered to
  final int surrenderFrom; // bit mask of slots offering to surrender to this player
  final int fighting; // bit mask of slots it is clashing with right now
  final int name; // its alliance's name code, -1 when alone
  final int armyValue; // mineral + gas value of its combat units
  final int workers;
  final int mineralRate; // per minute
  final int gasRate; // per minute
  const AlliancePlayer({
    required this.slot,
    required this.playing,
    required this.active,
    required this.group,
    required this.open,
    required this.invitedBy,
    required this.color,
    required this.race,
    required this.mineralsMined,
    required this.gasMined,
    required this.points,
    required this.ownPoints,
    required this.productionScore,
    required this.killScore,
    required this.unitsKilled,
    required this.buildingsRazed,
    required this.unitsLost,
    this.lord = -1,
    this.surrenderFrom = 0,
    this.fighting = 0,
    this.name = -1,
    this.armyValue = 0,
    this.workers = 0,
    this.mineralRate = 0,
    this.gasRate = 0,
  });

  bool get isVassal => lord >= 0;
  bool fightingSlot(int slot) => fighting & (1 << slot) != 0;
  bool offersSurrender(int slot) => surrenderFrom & (1 << slot) != 0;

  /// Overall score: mining (shared with allies) + building + destroying.
  int get score => points + productionScore + killScore;

  bool invitedBySlot(int slot) => invitedBy & (1 << slot) != 0;
}

enum AllianceEventKind { none, invited, declined, formed, left, open, closed, surrenderOffer, surrendered, surrenderRefused, vassalMoved }

class AllianceEvent {
  final int frame;
  final AllianceEventKind kind;
  final int a;
  final int b;
  const AllianceEvent(this.frame, this.kind, this.a, this.b);
}

/// What auto-play takes care of (BW_AUTOPLAY_* bits).
enum AutoplayMode {
  resources(1),
  building(2),
  attacking(4),
  colonizing(8);

  final int bit;
  const AutoplayMode(this.bit);

  static const int all = 15;
}
