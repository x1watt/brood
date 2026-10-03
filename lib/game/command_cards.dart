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
};

const Set<int> larvaProducers = {zergHatchery, zergLair, zergHive};

/// Advisor voice lines, one per race in order zerg, terran, protoss (add the
/// race index 0-2).
const int soundNotEnoughMinerals = 147;
const int soundNotEnoughGas = 150;
const int soundNeedSupply = 153;
const int soundButton = 15;
const int soundErrorBuzz = 2;
