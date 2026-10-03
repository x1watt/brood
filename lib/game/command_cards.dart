// lib/game/command_cards.dart
//
// Command card layouts and hotkeys as in the original game. Workers have a
// basic (B) and an advanced (V) build menu; each entry's letter builds it
// from inside that menu (SCV: B then S = Supply Depot; Probe: B then C =
// Photon Cannon). Whether an entry is currently available still comes from
// the engine (OpenBW's unit_can_build), these tables only give order and
// hotkeys. Unit type ids are OpenBW's UnitTypes ordinals.

typedef CardEntry = (String hotkey, int typeId);

class WorkerMenus {
  final List<CardEntry> basic;
  final List<CardEntry> advanced;
  const WorkerMenus(this.basic, this.advanced);
}

const int terranScv = 7;
const int protossProbe = 64;
const int zergDrone = 41;
const int zergLarva = 35;
const int zergHatchery = 131;
const int zergLair = 132;
const int zergHive = 133;

const Map<int, WorkerMenus> workerMenus = {
  terranScv: WorkerMenus(
    [
      ('C', 106), // Command Center
      ('S', 109), // Supply Depot
      ('R', 110), // Refinery
      ('B', 111), // Barracks
      ('E', 122), // Engineering Bay
      ('T', 124), // Missile Turret
      ('A', 112), // Academy
      ('U', 125), // Bunker
    ],
    [
      ('F', 113), // Factory
      ('S', 114), // Starport
      ('I', 116), // Science Facility
      ('A', 123), // Armory
    ],
  ),
  protossProbe: WorkerMenus(
    [
      ('N', 154), // Nexus
      ('P', 156), // Pylon
      ('A', 157), // Assimilator
      ('G', 160), // Gateway
      ('F', 166), // Forge
      ('C', 162), // Photon Cannon
      ('Y', 164), // Cybernetics Core
      ('B', 172), // Shield Battery
    ],
    [
      ('R', 155), // Robotics Facility
      ('S', 167), // Stargate
      ('C', 163), // Citadel of Adun
      ('B', 171), // Robotics Support Bay
      ('F', 169), // Fleet Beacon
      ('T', 165), // Templar Archives
      ('O', 159), // Observatory
      ('A', 170), // Arbiter Tribunal
    ],
  ),
  zergDrone: WorkerMenus(
    [
      ('H', 131), // Hatchery
      ('C', 143), // Creep Colony
      ('E', 149), // Extractor
      ('S', 142), // Spawning Pool
      ('V', 139), // Evolution Chamber
      ('D', 135), // Hydralisk Den
    ],
    [
      ('S', 141), // Spire
      ('Q', 138), // Queen's Nest
      ('N', 134), // Nydus Canal
      ('U', 140), // Ultralisk Cavern
      ('D', 136), // Defiler Mound
    ],
  ),
};

/// What buildings (and larvae / morphing units) produce, in card order.
const Map<int, List<CardEntry>> productionMenus = {
  106: [('S', 7), ('C', 107), ('N', 108)], // Command Center: SCV, Comsat, Nuclear Silo
  111: [('M', 0), ('F', 32), ('G', 1), ('C', 34)], // Barracks: Marine, Firebat, Ghost, Medic
  113: [('V', 2), ('T', 5), ('G', 3), ('C', 120)], // Factory: Vulture, Siege Tank, Goliath, Machine Shop
  114: [('W', 8), ('D', 11), ('V', 9), ('B', 12), ('Y', 58), ('C', 115)], // Starport
  116: [('C', 117), ('P', 118)], // Science Facility: Covert Ops, Physics Lab
  154: [('P', 64)], // Nexus: Probe
  160: [('Z', 65), ('D', 66), ('T', 67), ('K', 61)], // Gateway
  155: [('S', 69), ('V', 83), ('O', 84)], // Robotics Facility
  167: [('S', 70), ('C', 72), ('A', 71), ('O', 60)], // Stargate
  zergLarva: [('D', 41), ('Z', 37), ('O', 42), ('H', 38), ('M', 43), ('S', 47), ('Q', 45), ('U', 39), ('F', 46)],
  zergHatchery: [('L', 132)], // Lair
  zergLair: [('H', 133)], // Hive
  143: [('U', 146), ('S', 144)], // Creep Colony: Sunken, Spore
  141: [('G', 137)], // Spire: Greater Spire
  43: [('G', 44), ('D', 62)], // Mutalisk: Guardian, Devourer
  38: [('L', 103)], // Hydralisk: Lurker
};

const Set<int> larvaProducers = {zergHatchery, zergLair, zergHive};

// --- Abilities ----------------------------------------------------------------

enum Targeting { instant, position, unit }

/// One ability button. [tech] is OpenBW's TechTypes ordinal (-1 for none);
/// instant abilities name their bridge action, targeted ones are cast with
/// the tech's own casting order.
class AbilityEntry {
  final String hotkey;
  final int tech;
  final Targeting targeting;
  final String instant; // 'stim', 'siege', 'unsiege', 'cloak', 'burrow', 'fighter', 'archon', 'darkArchon', 'unload'
  final String label; // used when the button isn't a tech (or to override)
  final int icon; // cmdicons frame override, -1 to use the tech's icon
  const AbilityEntry(this.hotkey, this.tech, this.targeting, {this.instant = '', this.label = '', this.icon = -1});
}

const _burrow = AbilityEntry('U', 11, Targeting.instant, instant: 'burrow');
const _unload = AbilityEntry('U', -1, Targeting.instant, instant: 'unload', label: 'Unload All', icon: 283);

/// Abilities per unit type, with the original hotkeys.
const Map<int, List<AbilityEntry>> unitAbilities = {
  0: [AbilityEntry('T', 0, Targeting.instant, instant: 'stim')], // Marine: Stim Packs
  32: [AbilityEntry('T', 0, Targeting.instant, instant: 'stim')], // Firebat
  1: [AbilityEntry('C', 10, Targeting.instant, instant: 'cloak'), AbilityEntry('L', 1, Targeting.unit)], // Ghost
  34: [AbilityEntry('R', 24, Targeting.unit), AbilityEntry('O', 30, Targeting.unit)], // Medic
  2: [AbilityEntry('I', 3, Targeting.position)], // Vulture: Spider Mines
  5: [AbilityEntry('O', 5, Targeting.instant, instant: 'siege', label: 'Siege Mode')], // Siege Tank (tank mode)
  30: [AbilityEntry('O', 5, Targeting.instant, instant: 'unsiege', label: 'Tank Mode')], // Siege Tank (siege mode)
  8: [AbilityEntry('C', 9, Targeting.instant, instant: 'cloak')], // Wraith
  9: [AbilityEntry('D', 6, Targeting.unit), AbilityEntry('E', 2, Targeting.position), AbilityEntry('I', 7, Targeting.unit)], // Science Vessel
  12: [AbilityEntry('Y', 8, Targeting.unit)], // Battlecruiser
  107: [AbilityEntry('S', 4, Targeting.position)], // Comsat Station: Scanner Sweep
  11: [_unload], // Dropship
  67: [AbilityEntry('T', 19, Targeting.position), AbilityEntry('L', 20, Targeting.unit), AbilityEntry('R', 23, Targeting.instant, instant: 'archon')], // High Templar
  61: [AbilityEntry('R', 28, Targeting.instant, instant: 'darkArchon')], // Dark Templar
  63: [AbilityEntry('F', 29, Targeting.unit), AbilityEntry('M', 27, Targeting.unit), AbilityEntry('E', 31, Targeting.position)], // Dark Archon
  71: [AbilityEntry('R', 21, Targeting.position), AbilityEntry('T', 22, Targeting.position)], // Arbiter
  60: [AbilityEntry('D', 25, Targeting.position)], // Corsair
  72: [AbilityEntry('I', -1, Targeting.instant, instant: 'fighter', label: 'Build Interceptor', icon: 73)], // Carrier
  83: [AbilityEntry('R', -1, Targeting.instant, instant: 'fighter', label: 'Build Scarab', icon: 85)], // Reaver
  69: [_unload], // Shuttle
  42: [_unload], // Overlord
  41: [_burrow], // Drone
  37: [_burrow], // Zergling
  38: [_burrow], // Hydralisk
  103: [_burrow], // Lurker
  45: [AbilityEntry('P', 18, Targeting.unit), AbilityEntry('E', 17, Targeting.position), AbilityEntry('B', 13, Targeting.unit), AbilityEntry('I', 12, Targeting.unit)], // Queen
  46: [AbilityEntry('W', 14, Targeting.position), AbilityEntry('G', 15, Targeting.position), AbilityEntry('C', 16, Targeting.unit), _burrow], // Defiler
};

// --- Research and upgrades ----------------------------------------------------

/// (hotkey, id, isTech): research (TechTypes) or upgrade (UpgradeTypes) per
/// building, with the original hotkeys.
typedef ResearchEntry = (String hotkey, int id, bool isTech);

const Map<int, List<ResearchEntry>> researchMenus = {
  112: [('U', 16, false), ('T', 0, true), ('R', 24, true), ('O', 30, true), ('C', 51, false)], // Academy
  122: [('W', 7, false), ('A', 0, false)], // Engineering Bay
  123: [('V', 8, false), ('P', 1, false), ('S', 9, false), ('H', 2, false)], // Armory
  120: [('S', 5, true), ('I', 17, false), ('M', 3, true), ('C', 54, false)], // Machine Shop
  115: [('C', 9, true), ('A', 22, false)], // Control Tower
  117: [('L', 1, true), ('C', 10, true), ('O', 20, false), ('M', 21, false)], // Covert Ops
  118: [('Y', 8, true), ('C', 23, false)], // Physics Lab
  116: [('E', 2, true), ('I', 7, true), ('T', 19, false)], // Science Facility
  166: [('W', 13, false), ('A', 5, false), ('S', 15, false)], // Forge
  164: [('W', 14, false), ('A', 6, false), ('S', 33, false)], // Cybernetics Core
  163: [('L', 34, false)], // Citadel of Adun
  165: [('T', 19, true), ('H', 20, true), ('K', 40, false), ('M', 27, true), ('E', 31, true), ('A', 49, false)], // Templar Archives
  171: [('S', 35, false), ('C', 36, false), ('G', 37, false)], // Robotics Support Bay
  159: [('S', 38, false), ('G', 39, false)], // Observatory
  169: [('A', 41, false), ('G', 42, false), ('C', 43, false), ('D', 25, true), ('J', 47, false)], // Fleet Beacon
  170: [('R', 21, true), ('S', 22, true), ('K', 44, false)], // Arbiter Tribunal
  131: [('B', 11, true), ('O', 24, false), ('A', 25, false), ('P', 26, false)], // Hatchery
  132: [('B', 11, true), ('O', 24, false), ('A', 25, false), ('P', 26, false)], // Lair
  133: [('B', 11, true), ('O', 24, false), ('A', 25, false), ('P', 26, false)], // Hive
  142: [('M', 27, false), ('A', 28, false)], // Spawning Pool
  139: [('M', 10, false), ('A', 11, false), ('C', 3, false)], // Evolution Chamber
  135: [('A', 29, false), ('G', 30, false), ('L', 32, true)], // Hydralisk Den
  141: [('A', 12, false), ('C', 4, false)], // Spire
  137: [('A', 12, false), ('C', 4, false)], // Greater Spire
  138: [('E', 17, true), ('B', 13, true), ('G', 31, false)], // Queen's Nest
  136: [('P', 15, true), ('C', 16, true), ('M', 32, false)], // Defiler Mound
  140: [('A', 53, false), ('C', 52, false)], // Ultralisk Cavern
};

/// Buildings that produce units get a "Set Rally Point" (R) button.
bool hasRally(int typeId) => larvaProducers.contains(typeId) || const {106, 111, 113, 114, 154, 160, 155, 167}.contains(typeId);

/// Icons for the worker build-menu buttons (cmdicons frames). Terran has its
/// own; for the others a representative building of that tier.
const Map<int, (int basic, int advanced)> buildMenuIcons = {
  terranScv: (234, 235),
  protossProbe: (156, 167), // Pylon, Stargate
  zergDrone: (131, 141), // Hatchery, Spire
};

/// Advisor voice lines, one per race in order zerg, terran, protoss (add the
/// race index 0-2).
const int soundNotEnoughMinerals = 147;
const int soundNotEnoughGas = 150;
const int soundNeedSupply = 153;
const int soundNotEnoughEnergy = 156;
const int soundButton = 15;
const int soundErrorBuzz = 2;
