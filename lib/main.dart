import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse, FramePhase, FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'game/game_controller.dart';
import 'game/play_stats.dart';
import 'game/settings.dart';
import 'ui/game_viewport.dart';
import 'ui/hud.dart';
import 'ui/minimap_view.dart';

void main() {
  runApp(const BroodApp());
}

class BroodApp extends StatelessWidget {
  const BroodApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Brood',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const StartScreen(),
    );
  }
}

String get _dataDir {
  final home = Platform.environment['HOME'] ?? '';
  return Platform.environment['BROOD_DATA'] ?? '$home/box/media/games/BROOD';
}

/// Fullscreen through the Linux runner's "brood/window" channel
/// (linux/runner/my_application.cc).
class WindowControl {
  static const _channel = MethodChannel('brood/window');

  static Future<bool> toggleFullscreen() async {
    try {
      return await _channel.invokeMethod<bool>('setFullscreen') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> setFullscreen(bool on) async {
    try {
      return await _channel.invokeMethod<bool>('setFullscreen', on) ?? false;
    } on MissingPluginException {
      return false;
    }
  }
}

class StartScreen extends StatefulWidget {
  const StartScreen({super.key});

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  static const _races = ['Zerg', 'Terran', 'Protoss'];
  int _race = 1;
  List<File> _maps = const [];
  File? _map;
  final PlayStats _stats = PlayStats.load();
  final Settings _settings = Settings.load();

  static String mapKey(File f) => f.path.startsWith(_dataDir) ? f.path.substring(_dataDir.length + 1) : f.path;

  int _seconds(File f) => _stats.maps[mapKey(f)]?.seconds ?? 0;

  @override
  void initState() {
    super.initState();
    final dir = Directory('$_dataDir/maps');
    final maps = dir.existsSync()
        ? dir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.scm') || f.path.toLowerCase().endsWith('.scx'))
              .where((f) => !f.path.contains('/save/') && !f.path.contains('/campaign/') && !f.path.contains('/scenario/'))
              .toList()
        : <File>[];
    // Most played first (by total time), then the rest alphabetically.
    maps.sort((a, b) {
      final t = _seconds(b).compareTo(_seconds(a));
      return t != 0 ? t : _name(a).compareTo(_name(b));
    });
    _maps = maps;
    _map = (_seconds(maps.firstOrNull ?? File('')) > 0 ? maps.first : null) ??
        maps.where((m) => _name(m) == '(4)Lost Temple').firstOrNull ??
        maps.firstOrNull;
  }

  static String _name(File f) => f.uri.pathSegments.last.replaceAll(RegExp(r'\.sc[mx]$', caseSensitive: false), '');

  void _start() {
    final map = _map;
    if (map == null) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => GameScreen(mapFile: map.path, mapKey: mapKey(map), race: _race, stats: _stats, settings: _settings)),
    );
  }

  Widget _sectionHeader(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
    child: Text(text, style: const TextStyle(fontSize: 12, color: Colors.white54, fontWeight: FontWeight.w600)),
  );

  Widget _mapTile(File m) {
    final st = _stats.maps[mapKey(m)];
    final played = st != null && st.seconds > 0;
    return ListTile(
      dense: true,
      selected: m == _map,
      title: Text(_name(m)),
      subtitle: Text(
        m.parent.path.replaceFirst('$_dataDir/maps', 'maps'),
        style: const TextStyle(fontSize: 11, color: Colors.white38),
      ),
      trailing: played
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(PlayStats.formatDuration(st.seconds), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                Text(
                  '${st.games} ${st.games == 1 ? 'game' : 'games'}${st.lastPlayed != null ? ' · ${_ago(st.lastPlayed!)}' : ''}',
                  style: const TextStyle(fontSize: 11, color: Colors.white38),
                ),
              ],
            )
          : null,
      onTap: () => setState(() => _map = m),
      onLongPress: _start,
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0E11),
      body: Center(
        child: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Brood', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('Game data: $_dataDir', style: const TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 24),
              const Text('Race'),
              const SizedBox(height: 8),
              SegmentedButton<int>(
                segments: [for (int i = 0; i < 3; ++i) ButtonSegment(value: i, label: Text(_races[i]))],
                selected: {_race},
                onSelectionChanged: (s) => setState(() => _race = s.first),
              ),
              const SizedBox(height: 20),
              const Text('Map'),
              const SizedBox(height: 8),
              SizedBox(
                height: 300,
                child: _maps.isEmpty
                    ? const Center(child: Text('No maps found in the game data folder.', style: TextStyle(color: Colors.redAccent)))
                    : Container(
                        decoration: BoxDecoration(border: Border.all(color: const Color(0xFF2E3A44))),
                        child: ListView(
                          children: [
                            if (_maps.any((m) => _seconds(m) > 0)) _sectionHeader('Most played'),
                            for (final m in _maps.where((m) => _seconds(m) > 0)) _mapTile(m),
                            if (_maps.any((m) => _seconds(m) > 0)) _sectionHeader('All maps'),
                            for (final m in _maps.where((m) => _seconds(m) == 0)) _mapTile(m),
                          ],
                        ),
                      ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _map == null ? null : _start,
                child: Text(_map == null ? 'Start game' : 'Start game on ${_name(_map!)} as ${_races[_race]}'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class GameScreen extends StatefulWidget {
  final String mapFile;
  final String mapKey;
  final int race;
  final PlayStats stats;
  final Settings settings;
  const GameScreen({
    super.key,
    required this.mapFile,
    required this.mapKey,
    required this.race,
    required this.stats,
    required this.settings,
  });

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with SingleTickerProviderStateMixin {
  final GameController _c = GameController();
  final FocusNode _focus = FocusNode();
  late final Ticker _ticker;
  late final AppLifecycleListener _lifecycle;
  bool _fullscreen = false;
  Timer? _statsTimer;
  int _countedFrames = 0;
  bool _showPerf = false;
  final List<FrameTiming> _timings = [];
  Timer? _perfLogTimer;

  void _onTimings(List<FrameTiming> t) {
    _timings.addAll(t);
    if (_timings.length > 120) _timings.removeRange(0, _timings.length - 120);
  }

  // Play time is game time (frames at the original's 42 ms each), saved
  // every 30 s, when leaving the game and when the window closes.
  void _flushPlayTime() {
    final frames = _c.frame - _countedFrames;
    if (frames <= 0) return;
    _countedFrames = _c.frame;
    widget.stats.addPlayed(widget.mapKey, frames * GameController.frameMicros ~/ 1000000);
  }

  @override
  void initState() {
    super.initState();
    // Simulation pacing follows the display's vsync, not a Timer.
    _ticker = createTicker(_c.tick)..start();
    _lifecycle = AppLifecycleListener(
      onInactive: _c.stopAllScrolling,
      onHide: _c.stopAllScrolling,
      onExitRequested: () async {
        _flushPlayTime();
        return AppExitResponse.exit;
      },
    );
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    if (Platform.environment['BROOD_PERF_LOG'] == '1') {
      // For measuring: print the overlay's numbers every 5 s.
      _perfLogTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        final t = List<FrameTiming>.of(_timings);
        if (t.length < 2) return;
        final span = t.last.timestampInMicroseconds(FramePhase.vsyncStart) - t.first.timestampInMicroseconds(FramePhase.vsyncStart);
        double avg(Iterable<int> v) => v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length / 1000;
        int worst(Iterable<int> v) => v.isEmpty ? 0 : v.reduce((a, b) => a > b ? a : b);
        stderr.writeln('perf fps=${((t.length - 1) * 1e6 / span).toStringAsFixed(1)} '
            'tick=${avg(_c.tickMicros).toStringAsFixed(2)}ms(worst ${(worst(_c.tickMicros) / 1000).toStringAsFixed(1)}) '
            'build=${avg(t.map((f) => f.buildDuration.inMicroseconds)).toStringAsFixed(2)}ms '
            'raster=${avg(t.map((f) => f.rasterDuration.inMicroseconds)).toStringAsFixed(2)}ms '
            'frame=${avg(t.map((f) => f.totalSpan.inMicroseconds)).toStringAsFixed(2)}ms(worst ${(worst(t.map((f) => f.totalSpan.inMicroseconds)) / 1000).toStringAsFixed(1)})');
      });
    }
    _c.start(dataDir: _dataDir, mapFile: widget.mapFile, race: widget.race).then((_) {
      if (!mounted) return;
      final s = _c.sound;
      if (s != null) {
        s.volume = widget.settings.volume;
        if (widget.settings.muted) s.muted = true;
      }
      if (widget.settings.fullscreen) {
        WindowControl.setFullscreen(true).then((on) {
          if (mounted) setState(() => _fullscreen = on);
        });
      }
      if (_c.ready) {
        widget.stats.gameStarted(widget.mapKey);
        _countedFrames = _c.frame;
        _statsTimer = Timer.periodic(const Duration(seconds: 30), (_) => _flushPlayTime());
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _perfLogTimer?.cancel();
    _statsTimer?.cancel();
    _flushPlayTime();
    _lifecycle.dispose();
    _ticker.dispose();
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _toggleFullscreen() async {
    final on = await WindowControl.toggleFullscreen();
    widget.settings
      ..fullscreen = on
      ..save();
    if (mounted) setState(() => _fullscreen = on);
    _focus.requestFocus();
  }

  void _toggleMute() {
    final s = _c.sound;
    if (s == null) return;
    s.muted = !s.muted;
    widget.settings
      ..muted = s.muted
      ..save();
    _c.hud.fire();
  }

  void _setVolume(double v) {
    final s = _c.sound;
    if (s == null) return;
    s.volume = v;
    if (s.muted && v > 0) s.muted = false;
    _c.hud.fire();
  }

  void _volumeDone(double v) {
    widget.settings
      ..volume = v
      ..muted = _c.sound?.muted ?? false
      ..save();
    _focus.requestFocus();
  }

  static final _arrows = {
    LogicalKeyboardKey.arrowLeft: (-1, 0),
    LogicalKeyboardKey.arrowRight: (1, 0),
    LogicalKeyboardKey.arrowUp: (0, -1),
    LogicalKeyboardKey.arrowDown: (0, 1),
  };

  static final _digits = [
    LogicalKeyboardKey.digit0,
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final arrow = _arrows[e.logicalKey];
    if (arrow != null) {
      if (e is KeyDownEvent) _c.setKeyScroll(arrow.$1, arrow.$2, true);
      if (e is KeyUpEvent) _c.setKeyScroll(arrow.$1, arrow.$2, false);
      return KeyEventResult.handled;
    }
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.f11) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f12) {
      setState(() => _showPerf = !_showPerf);
      return KeyEventResult.handled;
    }
    if (!_c.ready) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;

    if (key == LogicalKeyboardKey.escape) {
      _c.escape();
      return KeyEventResult.handled;
    }
    final digit = _digits.indexOf(key);
    if (digit >= 0) {
      _c.controlGroup(digit, assign: kb.isControlPressed, add: kb.isShiftPressed && !kb.isControlPressed);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space) {
      final sel = _c.selectedUnits;
      if (sel.isNotEmpty) _c.centerOn(sel.first.x.toDouble(), sel.first.y.toDouble());
      return KeyEventResult.handled;
    }
    if (kb.isControlPressed || kb.isAltPressed || kb.isMetaPressed) return KeyEventResult.ignored;
    final label = key.keyLabel.toUpperCase();
    if (label.length == 1 && label.codeUnitAt(0) >= 65 && label.codeUnitAt(0) <= 90) {
      return _c.pressHotkey(label) ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (_c.error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText('Engine failed to start:\n${_c.error}', style: const TextStyle(color: Colors.redAccent)),
          ),
        ),
      );
    }
    if (!_c.ready) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: Text('Loading map...', style: TextStyle(color: Colors.white70))),
      );
    }

    final windowSize = MediaQuery.sizeOf(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        // Pointer tracked over the whole window so edge scrolling works along
        // every border, including over the panels.
        child: MouseRegion(
          onHover: (e) => _c.onWindowPointer(e.position, windowSize),
          onExit: (e) => _c.onWindowExit(e.position, windowSize),
          child: Listener(
            onPointerMove: (e) => _c.onWindowPointer(e.position, windowSize),
            onPointerDown: (_) => _focus.requestFocus(),
            child: Column(
              children: [
                ListenableBuilder(
                  listenable: _c.hud,
                  builder: (_, _) => TopBar(
                    c: _c,
                    fullscreen: _fullscreen,
                    onToggleFullscreen: _toggleFullscreen,
                    onToggleMute: _toggleMute,
                    onVolume: _setVolume,
                    onVolumeDone: _volumeDone,
                  ),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(child: GameViewport(controller: _c)),
                      if (_showPerf)
                        Positioned(
                          right: 8,
                          top: 8,
                          child: IgnorePointer(
                            child: ListenableBuilder(
                              listenable: _c.hud,
                              builder: (_, _) => PerfOverlay(c: _c, timings: _timings),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 200,
                  child: ListenableBuilder(
                    listenable: _c.hud,
                    builder: (_, _) => Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          width: 200,
                          padding: const EdgeInsets.all(4),
                          color: const Color(0xFF0B0E11),
                          child: MinimapView(controller: _c),
                        ),
                        Expanded(child: SelectionPanel(c: _c)),
                        SizedBox(width: 300, child: CommandCard(c: _c)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
