import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'game/game_controller.dart';
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
    maps.sort((a, b) => _name(a).compareTo(_name(b)));
    _maps = maps;
    _map = maps.where((m) => _name(m) == '(4)Lost Temple').firstOrNull ?? maps.firstOrNull;
  }

  static String _name(File f) => f.uri.pathSegments.last.replaceAll(RegExp(r'\.sc[mx]$', caseSensitive: false), '');

  void _start() {
    final map = _map;
    if (map == null) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => GameScreen(mapFile: map.path, race: _race)),
    );
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
                            for (final m in _maps)
                              ListTile(
                                dense: true,
                                selected: m == _map,
                                title: Text(_name(m)),
                                subtitle: Text(
                                  m.parent.path.replaceFirst('$_dataDir/maps', 'maps'),
                                  style: const TextStyle(fontSize: 11, color: Colors.white38),
                                ),
                                onTap: () => setState(() => _map = m),
                                onLongPress: _start,
                              ),
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
  final int race;
  const GameScreen({super.key, required this.mapFile, required this.race});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with SingleTickerProviderStateMixin {
  final GameController _c = GameController();
  final FocusNode _focus = FocusNode();
  late final Ticker _ticker;
  late final AppLifecycleListener _lifecycle;
  bool _fullscreen = false;

  @override
  void initState() {
    super.initState();
    // Simulation pacing follows the display's vsync, not a Timer.
    _ticker = createTicker(_c.tick)..start();
    _lifecycle = AppLifecycleListener(onInactive: _c.stopAllScrolling, onHide: _c.stopAllScrolling);
    _c.start(dataDir: _dataDir, mapFile: widget.mapFile, race: widget.race).then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _ticker.dispose();
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _toggleFullscreen() async {
    final on = await WindowControl.toggleFullscreen();
    if (mounted) setState(() => _fullscreen = on);
    _focus.requestFocus();
  }

  void _toggleMute() {
    final s = _c.sound;
    if (s == null) return;
    s.muted = !s.muted;
    _c.hud.fire();
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
                  ),
                ),
                Expanded(child: GameViewport(controller: _c)),
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
