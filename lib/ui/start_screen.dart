// lib/ui/start_screen.dart
//
// Before a game: pick a map (most played first), set up the players (you
// plus computer opponents, their races and alliances), or load a saved
// game.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../game/game_data.dart';
import '../game/game_setup.dart';
import '../game/play_stats.dart';
import '../game/saved_games.dart';
import '../game/settings.dart';
import 'game_screen.dart';
import 'window_control.dart';

const _line = Color(0xFF2A2A2A);
const _dim = Color(0xFF8C8C8C);
const _faint = Color(0xFF5E5E5E);

class StartScreen extends StatefulWidget {
  const StartScreen({super.key});

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  final PlayStats _stats = PlayStats.load();
  final Settings _settings = Settings.load();
  List<GameMap> _maps = const [];
  GameMap? _map;
  List<SaveSession> _saves = const [];
  bool _loadTab = false;

  // Setup being edited: index 0 is you, the rest computer opponents.
  int _myRace = 1;
  List<int> _opponentRaces = [randomRace];
  AllianceMode _alliances = AllianceMode.freeForAll;

  int _seconds(GameMap m) => _stats.maps[m.key]?.seconds ?? 0;

  @override
  void initState() {
    super.initState();
    final maps = GameMap.list();
    // Most played first (by total time), then the rest alphabetically.
    maps.sort((a, b) {
      final t = _seconds(b).compareTo(_seconds(a));
      return t != 0 ? t : a.name.compareTo(b.name);
    });
    _maps = maps;
    _map = (maps.isNotEmpty && _seconds(maps.first) > 0 ? maps.first : null) ??
        maps.where((m) => m.name == '(4)Lost Temple').firstOrNull ??
        maps.firstOrNull;
    _saves = SaveSession.list();
    _restoreLastSetup();
  }

  void _restoreLastSetup() {
    final j = _settings.lastSetup;
    if (j == null) return;
    try {
      final s = GameSetup.fromJson(j);
      final me = s.players.firstWhere((p) => p.human);
      _myRace = me.race;
      _opponentRaces = [for (final p in s.players) if (!p.human) p.race];
      if (_opponentRaces.isEmpty) _opponentRaces = [randomRace];
      _alliances = s.alliances;
    } catch (_) {
      // Ignore a setup from an older version.
    }
  }

  int get _maxPlayers => _map?.maxPlayers ?? 8;
  int get _playerCount => (_opponentRaces.length + 1).clamp(2, _maxPlayers);

  void _setPlayerCount(int n) {
    n = n.clamp(2, _maxPlayers);
    setState(() {
      final races = [..._opponentRaces];
      while (races.length < n - 1) {
        races.add(randomRace);
      }
      _opponentRaces = races.sublist(0, n - 1);
    });
  }

  GameSetup _setup() => GameSetup(
    players: [
      PlayerSetup(human: true, race: _myRace),
      for (final r in _opponentRaces.take(_playerCount - 1)) PlayerSetup(human: false, race: r),
    ],
    alliances: _alliances,
    seed: GameSetup.newSeed(),
  );

  void _start() {
    final map = _map;
    if (map == null) return;
    final setup = _setup();
    _settings
      ..lastSetup = setup.toJson()
      ..save();
    _open(GameLaunch(mapFile: map.path, mapKey: map.key, mapName: map.name, setup: setup.resolved()));
  }

  void _open(GameLaunch launch) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => GameScreen(launch: launch, stats: _stats, settings: _settings)),
    );
  }

  // --- layout ---

  // A phone in landscape is short: less padding, and the setup list shows
  // its scrollbar so the options below the fold are found.
  bool get _short => MediaQuery.sizeOf(context).height < 500;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040, maxHeight: 760),
          child: Padding(
            padding: EdgeInsets.all(_short ? 12 : 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text('Brood', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: Colors.white)),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 7),
                        child: Text('Game data: ${GameFiles.instance.description}', style: const TextStyle(color: _faint, fontSize: 12), overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    if (!kIsWeb) ...[
                      IconButton(
                        tooltip: 'Quit Brood',
                        onPressed: WindowControl.quit,
                        icon: const Icon(Icons.power_settings_new, color: _dim),
                      ),
                      const SizedBox(width: 8),
                    ],
                    SegmentedButton<bool>(
                      showSelectedIcon: false,
                      segments: [
                        const ButtonSegment(value: false, label: Text('New game')),
                        ButtonSegment(value: true, label: Text('Load game (${_saves.length})'), enabled: _saves.isNotEmpty),
                      ],
                      selected: {_loadTab},
                      onSelectionChanged: (s) => setState(() => _loadTab = s.first),
                    ),
                  ],
                ),
                SizedBox(height: _short ? 10 : 20),
                Expanded(child: _loadTab ? _savedGames() : _newGame()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _newGame() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _mapList()),
        const SizedBox(width: 20),
        SizedBox(width: 400, child: _setupPanel()),
      ],
    );
  }

  Widget _box({required Widget child}) => Container(
    decoration: BoxDecoration(border: Border.all(color: _line), borderRadius: BorderRadius.circular(6)),
    clipBehavior: Clip.antiAlias,
    child: child,
  );

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
    child: Text(text.toUpperCase(), style: const TextStyle(fontSize: 11, letterSpacing: 1.2, color: _dim, fontWeight: FontWeight.w600)),
  );

  Widget _mapList() {
    if (_maps.isEmpty) {
      return _box(child: const Center(child: Text('No maps found in the game data folder.', style: TextStyle(color: Color(0xFFFF6B5E)))));
    }
    final played = _maps.where((m) => _seconds(m) > 0).toList();
    final rest = _maps.where((m) => _seconds(m) == 0).toList();
    return _box(
      child: ListView(
        children: [
          if (played.isNotEmpty) _heading('Most played'),
          for (final m in played) _mapTile(m),
          _heading(played.isNotEmpty ? 'All maps' : 'Maps'),
          for (final m in rest) _mapTile(m),
        ],
      ),
    );
  }

  Widget _mapTile(GameMap m) {
    final st = _stats.maps[m.key];
    final played = st != null && st.seconds > 0;
    return ListTile(
      dense: true,
      selected: m == _map,
      title: Text(m.name),
      subtitle: Text('${m.folder}  ·  up to ${m.maxPlayers} players', style: const TextStyle(fontSize: 11, color: _faint)),
      trailing: played
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(PlayStats.formatDuration(st.seconds), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                Text(
                  '${st.games} ${st.games == 1 ? 'game' : 'games'}${st.lastPlayed != null ? ' · ${_ago(st.lastPlayed!)}' : ''}',
                  style: const TextStyle(fontSize: 11, color: _faint),
                ),
              ],
            )
          : null,
      onTap: () => setState(() {
        _map = m;
        _setPlayerCount(_playerCount);
      }),
      onLongPress: () {
        setState(() => _map = m);
        _start();
      },
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  static const _raceChoices = [0, 1, 2, randomRace];

  Widget _setupPanel() {
    final map = _map;
    final n = _playerCount;
    return _box(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Scrollbar(
              thumbVisibility: _short,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  _heading('Map'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(map?.name ?? 'None selected', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)),
                  ),
                  _heading('Players'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        IconButton.outlined(
                          tooltip: 'Fewer players',
                          onPressed: n > 2 ? () => _setPlayerCount(n - 1) : null,
                          icon: const Icon(Icons.remove, size: 18),
                        ),
                        SizedBox(
                          width: 48,
                          child: Text('$n', textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white)),
                        ),
                        IconButton.outlined(
                          tooltip: 'More players',
                          onPressed: n < _maxPlayers ? () => _setPlayerCount(n + 1) : null,
                          icon: const Icon(Icons.add, size: 18),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Text('You and ${n - 1} computer ${n - 1 == 1 ? 'opponent' : 'opponents'} (this map allows $_maxPlayers)', style: const TextStyle(color: _dim, fontSize: 12))),
                      ],
                    ),
                  ),
                  _heading('Alliances'),
                  RadioGroup<AllianceMode>(
                    groupValue: _alliances,
                    onChanged: (v) => setState(() => _alliances = v!),
                    child: Column(
                      children: [
                        for (final mode in AllianceMode.values)
                          RadioListTile<AllianceMode>(
                            dense: true,
                            value: mode,
                            title: Text(mode.label),
                            subtitle: Text(mode.description, style: const TextStyle(fontSize: 11, color: _faint)),
                          ),
                      ],
                    ),
                  ),
                  _heading('Your race'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SegmentedButton<int>(
                      showSelectedIcon: false,
                      segments: [for (final r in _raceChoices) ButtonSegment(value: r, label: Text(raceName(r)))],
                      selected: {_myRace},
                      onSelectionChanged: (s) => setState(() => _myRace = s.first),
                    ),
                  ),
                  _heading('Opponents'),
                  for (int i = 0; i < n - 1; ++i)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                      child: Row(
                        children: [
                          const Icon(Icons.smart_toy_outlined, size: 18, color: _dim),
                          const SizedBox(width: 10),
                          Expanded(child: Text('Computer ${i + 1}')),
                          DropdownButton<int>(
                            value: _opponentRaces[i],
                            underline: const SizedBox.shrink(),
                            style: const TextStyle(fontSize: 14, color: Color(0xFFE8E8E8)),
                            items: [for (final r in _raceChoices) DropdownMenuItem(value: r, child: Text(raceName(r)))],
                            onChanged: (r) => setState(() => _opponentRaces = [..._opponentRaces]..[i] = r!),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(_short ? 8 : 16),
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
              onPressed: map == null ? null : _start,
              child: Text(map == null ? 'Start game' : 'Start game as ${raceName(_myRace)}'),
            ),
          ),
        ],
      ),
    );
  }

  // Sessions grouped by map (most recent first), each with its points in
  // time: continue from the latest or pick an earlier one.
  Widget _savedGames() {
    if (_saves.isEmpty) return _box(child: const Center(child: Text('No saved games yet.', style: TextStyle(color: _dim))));
    final byMap = <String, List<SaveSession>>{};
    for (final s in _saves) {
      byMap.putIfAbsent(s.mapKey, () => []).add(s);
    }
    return _box(
      child: ListView(
        padding: const EdgeInsets.only(bottom: 12),
        children: [
          for (final entry in byMap.entries) ...[
            _heading(entry.value.first.mapName),
            for (final s in entry.value) _sessionTile(s),
          ],
        ],
      ),
    );
  }

  Widget _sessionTile(SaveSession s) {
    final me = s.setup.players.where((p) => p.human).firstOrNull;
    final others = s.setup.players.where((p) => !p.human).map((p) => raceName(p.race)).join(', ');
    final latest = s.latest!;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
        childrenPadding: const EdgeInsets.fromLTRB(32, 0, 12, 8),
        title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          [
            'you as ${raceName(me?.race ?? 1)} vs $others',
            s.setup.alliances.label,
            '${s.points.length} ${s.points.length == 1 ? 'point' : 'points'} up to ${latest.gameTime}',
            'saved ${_ago(s.lastSaved)}',
            if (s.origin.isNotEmpty) 'from ${s.origin}',
          ].join('  ·  '),
          style: const TextStyle(fontSize: 12, color: _faint),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(tooltip: 'Delete this session', icon: const Icon(Icons.delete_outline, color: _dim), onPressed: () => _delete(s)),
            const SizedBox(width: 4),
            FilledButton(onPressed: () => _load(s, latest), child: Text('Continue at ${latest.gameTime}')),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, color: _dim),
          ],
        ),
        children: [
          for (final p in s.points.reversed)
            ListTile(
              dense: true,
              leading: Icon(p.manual ? Icons.bookmark : Icons.history, size: 18, color: p.manual ? Colors.white : _dim),
              title: Text(p.manual ? '${p.gameTime}  ${p.name}' : '${p.gameTime}  auto-save'),
              subtitle: Text('saved ${_ago(p.saved)}', style: const TextStyle(fontSize: 11, color: _faint)),
              trailing: OutlinedButton(onPressed: () => _load(s, p), child: const Text('Load')),
              onTap: () => _load(s, p),
            ),
        ],
      ),
    );
  }

  void _load(SaveSession s, SavePoint p) {
    if (!GameFiles.instance.exists(s.mapFile)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('The map of this save is missing: ${s.mapFile}')));
      return;
    }
    try {
      _open(s.launch(p));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not read this save: $e')));
    }
  }

  Future<void> _delete(SaveSession s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this session?'),
        content: Text('"${s.name}" and its ${s.points.length} points in time will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    s.delete();
    setState(() {
      _saves = SaveSession.list();
      if (_saves.isEmpty) _loadTab = false;
    });
  }
}
