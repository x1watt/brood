// lib/ui/start_screen.dart
//
// Before a game: pick a map (most played first, with a search box), set up the players (you
// plus computer opponents, their races and alliances), or load a saved
// game.
//
// Dressed like the original's menus with art from the player's own game
// files (lib/ui/menu_art.dart): the title screen once at startup, then the
// room of the race you pick behind the menu (the planet for Random), the
// menus' green, and their button sounds.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent;

import '../game/game_data.dart';
import '../game/game_setup.dart';
import '../game/play_stats.dart';
import '../game/saved_games.dart';
import '../game/settings.dart';
import 'game_screen.dart';
import 'menu_art.dart';
import 'window_control.dart';

const _line = Color(0xFF2A2A2A);
// The original menus' colors: green text and frames, yellow for what's
// highlighted.
const _scGreen = Color(0xFF32D25A);
const _scGreenDim = Color(0xFF1C7A36);
const _scYellow = Color(0xFFFCE45C);
const _panel = Color(0xC4000000);
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
  MenuArt? _art;
  // The title screen shows once per run, when the app starts.
  static bool _titleShown = false;
  bool _showTitle = false;
  Timer? _titleTimer;
  final _mapSearch = TextEditingController();
  final _saveSearch = TextEditingController();

  // Setup being edited: index 0 is you, the rest computer opponents.
  int _myRace = 1;
  List<int> _opponentRaces = [randomRace];
  AllianceMode _alliances = AllianceMode.freeForAll;

  int _seconds(GameMap m) => _stats.maps[m.key]?.seconds ?? 0;

  @override
  void initState() {
    super.initState();
    _art = MenuArt.current;
    if (_art == null) {
      MenuArt.load().then((art) {
        if (!mounted || art == null) return;
        setState(() {
          _art = art;
          _showTitle = !_titleShown && art.title != null;
        });
        if (_showTitle) _titleTimer = Timer(const Duration(seconds: 4), _hideTitle);
      });
    }
    final maps = GameMap.list();
    // Most played first (by total time), then the rest alphabetically.
    maps.sort((a, b) {
      final t = _seconds(b).compareTo(_seconds(a));
      return t != 0 ? t : a.name.compareTo(b.name);
    });
    _maps = maps;
    _map = (maps.isNotEmpty && _seconds(maps.first) > 0 ? maps.first : null) ?? maps.where((m) => m.name == '(4)Lost Temple').firstOrNull ?? maps.firstOrNull;
    _saves = SaveSession.list();
    _restoreLastSetup();
  }

  @override
  void dispose() {
    _titleTimer?.cancel();
    _mapSearch.dispose();
    _saveSearch.dispose();
    super.dispose();
  }

  /// Every word typed must appear somewhere in [text] (any case, any order).
  static bool _matches(String query, String text) {
    final t = text.toLowerCase();
    return query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).every(t.contains);
  }

  Widget _searchField(TextEditingController controller, String hint) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
    child: TextField(
      controller: controller,
      onChanged: (_) => setState(() {}),
      textInputAction: TextInputAction.search,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: const TextStyle(color: _faint),
        prefixIcon: const Icon(Icons.search, size: 18, color: _dim),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close, size: 16, color: _dim),
                onPressed: () => setState(controller.clear),
              ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: _line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: _line),
        ),
      ),
    ),
  );

  Widget _noMatch(String text) => Padding(
    padding: const EdgeInsets.all(16),
    child: Text(text, style: const TextStyle(color: _dim)),
  );

  void _restoreLastSetup() {
    final j = _settings.lastSetup;
    if (j == null) return;
    try {
      final s = GameSetup.fromJson(j);
      final me = s.players.firstWhere((p) => p.human);
      _myRace = me.race;
      _opponentRaces = [
        for (final p in s.players)
          if (!p.human) p.race,
      ];
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
      MaterialPageRoute(
        builder: (_) => GameScreen(launch: launch, stats: _stats, settings: _settings),
      ),
    );
  }

  // --- layout ---

  // A phone in landscape is short: less padding, and the setup list shows
  // its scrollbar so the options below the fold are found.
  bool get _short => MediaQuery.sizeOf(context).height < 500;

  void _hideTitle() {
    _titleTimer?.cancel();
    if (!_showTitle) return;
    _titleShown = true;
    setState(() => _showTitle = false);
    _art?.play('swishin', startAudio: true);
  }

  void _click() => _art?.play('mousedown2', startAudio: true);
  void _hover() => _art?.play('mouseover');

  // The race whose room is behind the menu.
  int get _shownRace => _loadTab ? -1 : _myRace;

  // Material widgets in the menus' green.
  ThemeData _menuTheme(BuildContext context) {
    final t = Theme.of(context);
    return t.copyWith(
      colorScheme: t.colorScheme.copyWith(
        primary: _scGreen,
        onPrimary: Colors.black,
        secondaryContainer: const Color(0xFF123A1E),
        onSecondaryContainer: _scYellow,
        outline: _scGreenDim,
      ),
      listTileTheme: t.listTileTheme.copyWith(selectedColor: _scYellow, selectedTileColor: const Color(0x3332D25A)),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          side: const WidgetStatePropertyAll(BorderSide(color: _scGreenDim)),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? _scYellow : (s.contains(WidgetState.disabled) ? _faint : _scGreen),
          ),
          backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? const Color(0xFF123A1E) : Colors.transparent),
        ),
      ),
      radioTheme: RadioThemeData(fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? _scYellow : _scGreen)),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? _faint : _scGreen),
          side: WidgetStateProperty.resolveWith((s) => BorderSide(color: s.contains(WidgetState.disabled) ? _line : _scGreenDim)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled)
                ? const Color(0xFF1A1A1A)
                : (s.contains(WidgetState.hovered) ? const Color(0xFF1F6B33) : const Color(0xFF15502A)),
          ),
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? _faint : _scYellow),
          side: WidgetStateProperty.resolveWith((s) => BorderSide(color: s.contains(WidgetState.disabled) ? _line : _scGreen, width: 1.5)),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w700, letterSpacing: 1.2)),
        ),
      ),
      textSelectionTheme: const TextSelectionThemeData(cursorColor: _scGreen),
      inputDecorationTheme: t.inputDecorationTheme.copyWith(
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: _scGreen),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final art = _art;
    final background = art?.backgroundFor(_shownRace);
    return Theme(
      data: _menuTheme(context),
      child: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            // The race's room, cross-fading when you pick another race.
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 600),
              // Every picture fills the screen, the old one fading under the new.
              layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
              child: background == null
                  ? const SizedBox.expand(key: ValueKey('none'))
                  : RawImage(key: ValueKey(_shownRace), image: background, fit: BoxFit.cover, filterQuality: FilterQuality.medium),
            ),
            // Darker toward the edges so the menu stays readable.
            const DecoratedBox(
              decoration: BoxDecoration(gradient: RadialGradient(radius: 1.1, colors: [Color(0x66000000), Color(0xDD000000)])),
            ),
            Center(
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
                          const _Logo(),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 7),
                              child: Text(
                                'Game data: ${GameFiles.instance.description}',
                                style: const TextStyle(color: _faint, fontSize: 12),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          if (!kIsWeb) ...[
                            IconButton(
                              tooltip: 'Quit Brood',
                              onPressed: () {
                                _click();
                                WindowControl.quit();
                              },
                              icon: const Icon(Icons.power_settings_new),
                            ),
                            const SizedBox(width: 8),
                          ],
                          MouseRegion(
                            onEnter: (_) => _hover(),
                            child: SegmentedButton<bool>(
                              showSelectedIcon: false,
                              segments: [
                                const ButtonSegment(value: false, label: Text('New game')),
                                ButtonSegment(value: true, label: Text('Load game (${_saves.length})'), enabled: _saves.isNotEmpty),
                              ],
                              selected: {_loadTab},
                              onSelectionChanged: (s) {
                                _click();
                                setState(() => _loadTab = s.first);
                              },
                            ),
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
            if (art?.title != null)
              IgnorePointer(
                ignoring: !_showTitle,
                child: AnimatedOpacity(
                  opacity: _showTitle ? 1 : 0,
                  duration: const Duration(milliseconds: 700),
                  child: _TitleScreen(image: art!.title!, onDone: _hideTitle),
                ),
              ),
          ],
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

  // A menu frame: dark glass with the green border of the original's dialogs.
  Widget _box({required Widget child}) => Container(
    decoration: BoxDecoration(
      color: _panel,
      border: Border.all(color: _scGreenDim, width: 1.5),
      borderRadius: BorderRadius.circular(6),
      boxShadow: const [BoxShadow(color: Color(0x5532D25A), blurRadius: 14)],
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(fontSize: 11, letterSpacing: 1.6, color: _scGreen, fontWeight: FontWeight.w700),
    ),
  );

  Widget _mapList() {
    if (_maps.isEmpty) {
      return _box(
        child: const Center(
          child: Text('No maps found in the game data folder.', style: TextStyle(color: Color(0xFFFF6B5E))),
        ),
      );
    }
    final query = _mapSearch.text;
    final shown = _maps.where((m) => _matches(query, '${m.name} ${m.folder}')).toList();
    final played = shown.where((m) => _seconds(m) > 0).toList();
    final rest = shown.where((m) => _seconds(m) == 0).toList();
    return _box(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _searchField(_mapSearch, 'Search ${_maps.length} maps'),
          Expanded(
            child: ListView(
              children: [
                if (shown.isEmpty) _noMatch('No map matches "$query".'),
                if (played.isNotEmpty) _heading('Most played'),
                for (final m in played) _mapTile(m),
                if (rest.isNotEmpty) _heading(played.isNotEmpty ? 'All maps' : 'Maps'),
                for (final m in rest) _mapTile(m),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _mapTile(GameMap m) {
    final st = _stats.maps[m.key];
    final played = st != null && st.seconds > 0;
    return MouseRegion(
      onEnter: (_) => _hover(),
      child: ListTile(
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
        onTap: () {
          _click();
          setState(() {
            _map = m;
            _setPlayerCount(_playerCount);
          });
        },
        onLongPress: () {
          setState(() => _map = m);
          _start();
        },
      ),
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
                    child: Text(
                      map?.name ?? 'None selected',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
                    ),
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
                          child: Text(
                            '$n',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white),
                          ),
                        ),
                        IconButton.outlined(
                          tooltip: 'More players',
                          onPressed: n < _maxPlayers ? () => _setPlayerCount(n + 1) : null,
                          icon: const Icon(Icons.add, size: 18),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'You and ${n - 1} computer ${n - 1 == 1 ? 'opponent' : 'opponents'} (this map allows $_maxPlayers)',
                            style: const TextStyle(color: _dim, fontSize: 12),
                          ),
                        ),
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
                      onSelectionChanged: (s) {
                        _click();
                        setState(() => _myRace = s.first);
                      },
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
            child: MouseRegion(
              onEnter: (_) => _hover(),
              child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                onPressed: map == null
                    ? null
                    : () {
                        _click();
                        _start();
                      },
                child: Text((map == null ? 'Start game' : 'Start game as ${raceName(_myRace)}').toUpperCase()),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Sessions grouped by map (most recent first), each with its points in
  // time: continue from the latest or pick an earlier one.
  Widget _savedGames() {
    if (_saves.isEmpty) {
      return _box(
        child: const Center(
          child: Text('No saved games yet.', style: TextStyle(color: _dim)),
        ),
      );
    }
    final query = _saveSearch.text;
    final byMap = <String, List<SaveSession>>{};
    for (final s in _saves) {
      if (!_matches(query, '${s.name} ${s.mapName} ${s.origin}')) continue;
      byMap.putIfAbsent(s.mapKey, () => []).add(s);
    }
    return _box(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _searchField(_saveSearch, 'Search ${_saves.length} saved games'),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 12),
              children: [
                if (byMap.isEmpty) _noMatch('No saved game matches "$query".'),
                for (final entry in byMap.entries) ...[_heading(entry.value.first.mapName), for (final s in entry.value) _sessionTile(s)],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sessionTile(SaveSession s) {
    final me = s.setup.players.where((p) => p.human).firstOrNull;
    final others = s.setup.players.where((p) => !p.human).map((p) => raceName(p.race)).join(', ');
    final latest = s.latest!;
    return Theme(
      data: _menuTheme(context).copyWith(dividerColor: Colors.transparent),
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
            IconButton(
              tooltip: 'Delete this session',
              icon: const Icon(Icons.delete_outline, color: _dim),
              onPressed: () => _delete(s),
            ),
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

/// The name, in the chrome-and-blue of the original's logo.
class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) => ShaderMask(
    shaderCallback: (r) => const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFFFFFFF), Color(0xFFB8C6D8), Color(0xFF5E7FA8), Color(0xFFD8E2F0)],
      stops: [0, 0.45, 0.55, 1],
    ).createShader(r),
    child: const Text(
      'BROOD',
      style: TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w900,
        letterSpacing: 6,
        color: Colors.white,
        shadows: [Shadow(color: Color(0xAA2050FF), blurRadius: 14)],
      ),
    ),
  );
}

/// The original's title screen, shown once when the app starts; a click or
/// a key goes on (and starts the sound in a browser).
class _TitleScreen extends StatelessWidget {
  final ui.Image image;
  final VoidCallback onDone;
  const _TitleScreen({required this.image, required this.onDone});

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (_, e) {
      if (e is KeyDownEvent) onDone();
      return KeyEventResult.handled;
    },
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onDone,
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            RawImage(image: image, fit: BoxFit.contain, filterQuality: FilterQuality.medium),
            const Align(
              alignment: Alignment(0, 0.95),
              child: Text('Click or press any key', style: TextStyle(color: Color(0x99FFFFFF), fontSize: 12, letterSpacing: 1.5)),
            ),
          ],
        ),
      ),
    ),
  );
}
