// lib/game/alliance_names.dart
//
// Alliance names: two English words, chosen by the bridge as a code
// (first * 64 + second) when an alliance forms, so every player sees the
// same name and saved games keep it.

const List<String> _first = [
  'Iron', 'Crimson', 'Silent', 'Golden', 'Shadow', 'Burning', 'Frozen', 'Hollow',
  'Storm', 'Ashen', 'Silver', 'Black', 'Scarlet', 'Wandering', 'Broken', 'Rising',
  'Thunder', 'Night', 'Stone', 'Emerald', 'Fallen', 'Eternal', 'Savage', 'Distant',
  'Obsidian', 'Radiant', 'Wild', 'Bitter', 'Hidden', 'Northern', 'Southern', 'Twin',
  'Ancient', 'Copper', 'Velvet', 'Restless', 'Sunken', 'Blazing', 'Ghost', 'Steel',
  'Amber', 'Cobalt', 'Grim', 'Lone', 'Molten', 'Pale', 'Royal', 'Rusted',
  'Sacred', 'Sable', 'Swift', 'Tidal', 'Venom', 'Winter', 'Void', 'Brazen',
  'Cinder', 'Dusk', 'Echoing', 'Feral', 'Glass', 'Hungry', 'Ivory', 'Jade',
];

const List<String> _second = [
  'Serpents', 'Dawn', 'Wolves', 'Legion', 'Covenant', 'Tide', 'Ravens', 'Spears',
  'Pact', 'Horizon', 'Hammers', 'Vanguard', 'Fangs', 'Crown', 'Embers', 'Sentinels',
  'Hounds', 'Blades', 'Storm', 'Circle', 'Wardens', 'Talons', 'Banner', 'Accord',
  'Shields', 'Hydras', 'Comets', 'Reapers', 'Thorns', 'Lions', 'Oath', 'Brotherhood',
  'Vipers', 'Titans', 'Phantoms', 'Monarchs', 'Hornets', 'Rangers', 'Scorpions', 'Dragons',
  'Keepers', 'Order', 'Swarm', 'Echo', 'Furies', 'Giants', 'Herald', 'Kings',
  'Lanterns', 'Marauders', 'Nomads', 'Owls', 'Pilgrims', 'Queens', 'Raiders', 'Signal',
  'Tempest', 'Union', 'Vigil', 'Watch', 'Wraiths', 'Zealots', 'Anvils', 'Bastion',
];

String allianceName(int code) {
  if (code < 0) return '';
  return '${_first[(code ~/ 64) % _first.length]} ${_second[code % 64 % _second.length]}';
}
