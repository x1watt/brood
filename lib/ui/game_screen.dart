// lib/ui/game_screen.dart
//
// The in-game screen: top bar, world view, minimap, selection panel and
// command card, plus the game menu (pause, save, load, exit) and the victory or
// defeat screen.

import 'dart:async';
import 'dart:ui' show AppExitResponse, FramePhase, FrameTiming, PointerDeviceKind;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../game/game_controller.dart';
import '../net/multiplayer.dart';
import '../platform/env.dart';
import '../game/game_data.dart';
import '../game/game_setup.dart';
import '../game/play_stats.dart';
import '../game/saved_games.dart';
import '../game/settings.dart';
import 'alliance_panel.dart';
import 'autoplay_panel.dart';
import 'game_viewport.dart';
import 'hud.dart';
import 'minimap_view.dart';
import 'saved_games_list.dart';
import 'score_screen.dart';
import 'start_screen.dart';
import 'window_control.dart';

class GameScreen extends StatefulWidget {
  final GameLaunch launch;
  final PlayStats stats;
  final Settings settings;
  const GameScreen({super.key, required this.launch, required this.stats, required this.settings});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with SingleTickerProviderStateMixin {
  final GameController _c = GameController();
  final FocusNode _focus = FocusNode();
  late final Ticker _ticker;
  late final AppLifecycleListener _lifecycle;
  bool _fullscreen = false;
  bool _menuOpen = false;
  bool _alliancesOpen = false;
  bool _allianceShown = false; // still on screen while sliding away
  bool _autoplayOpen = false;
  bool _outcomeShown = false;
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
    widget.stats.addPlayed(widget.launch.mapKey, frames * GameController.frameMicros ~/ 1000000);
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
        await _autosave(force: true);
        _flushPlayTime();
        return AppExitResponse.exit;
      },
    );
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    // Phones have no environment: --dart-define=BROOD_PERF_LOG=true there.
    if (env('BROOD_PERF_LOG') == '1' || const bool.fromEnvironment('BROOD_PERF_LOG')) {
      // For measuring: print the overlay's numbers every 5 s.
      _perfLogTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        final t = List<FrameTiming>.of(_timings);
        if (t.length < 2) return;
        final span = t.last.timestampInMicroseconds(FramePhase.vsyncStart) - t.first.timestampInMicroseconds(FramePhase.vsyncStart);
        double avg(Iterable<int> v) => v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length / 1000;
        int worst(Iterable<int> v) => v.isEmpty ? 0 : v.reduce((a, b) => a > b ? a : b);
        debugPrint(
          'perf fps=${((t.length - 1) * 1e6 / span).toStringAsFixed(1)} '
          'tick=${avg(_c.tickMicros).toStringAsFixed(2)}ms(worst ${(worst(_c.tickMicros) / 1000).toStringAsFixed(1)}) '
          'build=${avg(t.map((f) => f.buildDuration.inMicroseconds)).toStringAsFixed(2)}ms '
          'raster=${avg(t.map((f) => f.rasterDuration.inMicroseconds)).toStringAsFixed(2)}ms '
          'frame=${avg(t.map((f) => f.totalSpan.inMicroseconds)).toStringAsFixed(2)}ms(worst ${(worst(t.map((f) => f.totalSpan.inMicroseconds)) / 1000).toStringAsFixed(1)})',
        );
      });
    }
    _c.hud.addListener(_onHud);
    _c.repaint.addListener(_panelAwayFromEdge);
    _c.start(dataDir: gameDataDir, launch: widget.launch).then((_) {
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
        if (widget.launch.saved == null) widget.stats.gameStarted(widget.launch.mapKey);
        _countedFrames = _c.frame;
        _statsTimer = Timer.periodic(const Duration(seconds: 30), (_) => _flushPlayTime());
        // A loaded game's starting point is already saved.
        if (widget.launch.saved != null) _lastSavedFrame = _c.frame;
        if (MediaQuery.sizeOf(context).shortestSide < 500) {
          _c.showMessageQuiet('Two fingers move the map. Drag from your units to give an order, or hold a spot.', ms: 9000);
        }
        _autosaveTimer = Timer.periodic(const Duration(seconds: 10), (_) => _autosave());
      }
      setState(() {});
    });
  }

  // The result screen appears once, when the engine reports it.
  void _onHud() {
    if (!mounted) return;
    _followServerPause();
    if (_c.outcome != null && !_outcomeShown) setState(() => _outcomeShown = true);
    if (!_c.ready && _c.loadingSave) setState(() {});
  }

  @override
  void dispose() {
    _c.hud.removeListener(_onHud);
    _c.repaint.removeListener(_panelAwayFromEdge);
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _perfLogTimer?.cancel();
    _statsTimer?.cancel();
    _autosaveTimer?.cancel();
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

  // --- game menu ---

  // In a multiplayer game the menu pauses everyone, and anyone's pause
  // opens it everywhere (family play: anyone may pause). While our own
  // request is on its way, the server's state isn't ours yet.
  bool _pauseRequested = false, _resumeRequested = false;

  void _openMenu() {
    if (!_c.ready || _outcomeVisible) return;
    _menuByServer = false;
    _c.setPaused(true);
    if (_c.mp != null) {
      _pauseRequested = true;
      _c.mp!.pause(true);
    }
    setState(() => _menuOpen = true);
  }

  void _closeMenu() {
    _c.setPaused(false);
    if (_c.mp != null) {
      _resumeRequested = true;
      _c.mp!.pause(false);
    }
    setState(() => _menuOpen = false);
    _focus.requestFocus();
  }

  bool _menuByServer = false; // opened by someone else's pause

  void _followServerPause() {
    final s = _c.mp;
    if (s == null && _menuByServer && _menuOpen) {
      // Disconnected while someone else had paused: play on.
      _menuByServer = false;
      setState(() => _menuOpen = false);
      return;
    }
    if (s == null || _outcomeVisible) return;
    if (s.paused) _pauseRequested = false;
    if (!s.paused) _resumeRequested = false;
    if (s.paused && !_menuOpen && !_resumeRequested) {
      _c.setPaused(true);
      _menuByServer = true;
      setState(() => _menuOpen = true);
    } else if (!s.paused && _menuOpen && !_pauseRequested) {
      _c.setPaused(false);
      setState(() => _menuOpen = false);
    }
  }

  bool get _outcomeVisible => _outcomeShown && _c.paused;

  bool get _panelLeft => widget.settings.alliancePanelLeft;

  // The panel can sit on either side, so it doesn't hide your base.
  void _togglePanelSide() {
    _setPanelLeft(!_panelLeft);
    _focus.requestFocus();
  }

  void _setPanelLeft(bool left) {
    widget.settings
      ..alliancePanelLeft = left
      ..save();
    setState(() {});
  }

  // While the panel is open, scrolling to the map's left or right edge (where
  // a base usually is) moves the panel to the other side, so it doesn't hide
  // what is there. It stays put until the other edge is reached.
  void _panelAwayFromEdge() {
    if (!_alliancesOpen || !mounted) return;
    final maxX = _c.mapSize.width - _c.viewport.width;
    if (maxX <= 0) return;
    if (_c.camX <= 0 && _panelLeft) {
      _setPanelLeft(false);
    } else if (_c.camX >= maxX && !_panelLeft) {
      _setPanelLeft(true);
    }
  }

  void _toggleAutoplay() {
    if (!_c.ready) return;
    setState(() => _autoplayOpen = !_autoplayOpen);
    _focus.requestFocus();
  }

  void _toggleAlliances() {
    if (!_c.ready) return;
    setState(() {
      _alliancesOpen = !_alliancesOpen;
      if (_alliancesOpen) _allianceShown = true;
    });
    _panelAwayFromEdge();
    _focus.requestFocus();
  }

  // --- saving: sessions of points in time (lib/game/saved_games.dart) ---

  // Auto-save spacing by game time: every minute in the first hour, every
  // ten minutes up to ten hours, then every hour.
  static const int _minuteFrames = 1000 * 60 ~/ 42; // frames per game minute
  int get _autosaveFrames {
    final minutes = _c.frame ~/ _minuteFrames;
    if (minutes < 60) return _minuteFrames;
    if (minutes < 600) return _minuteFrames * 10;
    return _minuteFrames * 60;
  }

  SaveSession? _session; // created with the first save of this stretch of play
  int _lastSavedFrame = -1;
  bool _saving = false;
  Timer? _autosaveTimer;

  String get _now {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}';
  }

  SaveSession _newSession(String name, {String origin = ''}) {
    final l = widget.launch;
    return SaveSession.create(name: name, mapFile: l.mapFile, mapKey: l.mapKey, mapName: l.mapName, setup: l.setup, origin: origin);
  }

  Future<void> _autosave({bool force = false}) async {
    if (!_c.ready || _saving || !widget.settings.autosave) return;
    if (!force && _c.frame - _lastSavedFrame < _autosaveFrames) return;
    if (_c.frame <= _lastSavedFrame + 24) return; // nothing new
    _saving = true;
    try {
      // A loaded game carries on in a new session, so the old timeline stays.
      _session ??= _newSession('${widget.launch.mapName} $_now', origin: widget.launch.continues);
      final data = _c.snapshot();
      await _session!.addPoint(data);
      _lastSavedFrame = data.frame;
    } catch (e) {
      debugPrint('autosave failed: $e');
    } finally {
      _saving = false;
    }
  }

  Future<void> _saveGame() async {
    final seconds = _c.frame * GameController.frameMicros ~/ 1000000;
    String two(int v) => v.toString().padLeft(2, '0');
    final suggested = '${widget.launch.mapName} ${seconds ~/ 60}:${two(seconds % 60)} ($_now)';
    final controller = TextEditingController(text: suggested)..selection = TextSelection(baseOffset: 0, extentOffset: suggested.length);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save game'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
                onSubmitted: (v) => Navigator.pop(ctx, v),
              ),
              const SizedBox(height: 12),
              const Text(
                'Saving starts a new session under this name; auto-saves carry on there. '
                'The earlier session keeps its own points in time.',
                style: TextStyle(fontSize: 12, color: Color(0xFF8C8C8C)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    final title = name.trim().isEmpty ? suggested : name.trim();
    try {
      final previous = _session;
      final session = _newSession(title, origin: previous != null ? previous.name : widget.launch.continues);
      final data = _c.snapshot();
      await session.addPoint(data, manual: true, name: title);
      _session = session;
      _lastSavedFrame = data.frame;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved. New session: $title'), duration: const Duration(seconds: 3)));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save the game: $e')));
    }
  }

  // Load game, from the menu: pick a saved game, then this one is saved
  // (when auto-save is on) and the picked one takes its place.
  Future<void> _loadGame() async {
    final size = MediaQuery.sizeOf(context);
    final picked = await showDialog<(SaveSession, SavePoint)>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Color(0xFF3A3A3A)),
        ),
        child: SizedBox(
          width: size.width < 932 ? size.width - 32 : 900,
          height: size.height * 0.85,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('Load game', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
                    ),
                    IconButton(tooltip: 'Close', onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
                  ],
                ),
              ),
              Expanded(child: SavedGamesList(onLoad: (session, point) => Navigator.pop(ctx, (session, point)))),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final (session, point) = picked;
    if (!GameFiles.instance.exists(session.mapFile)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('The map of this save is missing: ${session.mapFile}')));
      return;
    }
    final GameLaunch launch;
    try {
      launch = session.launch(point);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not read this save: $e')));
      return;
    }
    if (!widget.settings.autosave) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Load this game?'),
          content: const Text('Auto-save is off: progress in this game since your last save will be lost.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Load')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    await _autosave(force: true);
    _flushPlayTime();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => GameScreen(launch: launch, stats: widget.stats, settings: widget.settings)),
    );
  }

  Future<void> _exitToMenu({bool confirm = true}) async {
    final autosave = widget.settings.autosave;
    if (confirm && !autosave) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Exit to main menu?'),
          content: const Text('Auto-save is off: progress since your last save will be lost.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Exit')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    await _autosave(force: true);
    _flushPlayTime();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const StartScreen()));
  }

  Future<void> _quit() async {
    if (!widget.settings.autosave) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Quit Brood?'),
          content: const Text('Auto-save is off: progress since your last save will be lost.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Quit')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _autosave(force: true);
    _flushPlayTime();
    await WindowControl.quit();
  }

  void _setAutosave(bool on) {
    widget.settings
      ..autosave = on
      ..save();
    setState(() {});
  }

  void _keepWatching() {
    _c.continueAfterOutcome();
    setState(() {});
    _focus.requestFocus();
  }

  // --- keys ---

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
    final key = e.logicalKey;
    if (e is KeyDownEvent && key == LogicalKeyboardKey.f11) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }
    if (e is KeyDownEvent && key == LogicalKeyboardKey.f12) {
      setState(() => _showPerf = !_showPerf);
      return KeyEventResult.handled;
    }
    // The game menu: F10 or Esc opens it, either closes it.
    if (_menuOpen) {
      if (e is KeyDownEvent && (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.f10)) _closeMenu();
      return KeyEventResult.handled;
    }
    if (_outcomeVisible) return KeyEventResult.handled;
    if (e is KeyDownEvent && key == LogicalKeyboardKey.f10) {
      _openMenu();
      return KeyEventResult.handled;
    }
    if (e is KeyDownEvent && key == LogicalKeyboardKey.f9) {
      _toggleAlliances();
      return KeyEventResult.handled;
    }
    if (e is KeyDownEvent && key == LogicalKeyboardKey.f8) {
      _toggleAutoplay();
      return KeyEventResult.handled;
    }

    final arrow = _arrows[key];
    if (arrow != null) {
      if (e is KeyDownEvent) _c.setKeyScroll(arrow.$1, arrow.$2, true);
      if (e is KeyUpEvent) _c.setKeyScroll(arrow.$1, arrow.$2, false);
      return KeyEventResult.handled;
    }
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (!_c.ready) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;

    // Esc backs out of a command or build menu first, then opens the menu.
    if (key == LogicalKeyboardKey.escape) {
      if (!_c.escape()) _openMenu();
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

  // --- layout ---

  @override
  Widget build(BuildContext context) {
    if (_c.error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SelectableText('The game could not start:\n${_c.error}', style: const TextStyle(color: Color(0xFFFF6B5E))),
                const SizedBox(height: 16),
                FilledButton(onPressed: () => _exitToMenu(confirm: false), child: const Text('Back to main menu')),
              ],
            ),
          ),
        ),
      );
    }
    if (!_c.ready) {
      return Scaffold(
        body: Center(
          child: Text(_c.loadingSave ? 'Loading saved game...' : 'Loading map...', style: const TextStyle(color: Colors.white70)),
        ),
      );
    }

    final windowSize = MediaQuery.sizeOf(context);
    // Phones get the HUD as an overlay on a full-screen map.
    final compact = MediaQuery.sizeOf(context).shortestSide < 500;
    final topBar = ListenableBuilder(
      listenable: _c.hud,
      builder: (_, _) => TopBar(
        c: _c,
        compact: compact,
        fullscreen: _fullscreen,
        onMenu: _openMenu,
        onAlliances: _toggleAlliances,
        alliancesOpen: _alliancesOpen,
        onAutoplay: _toggleAutoplay,
        autoplayOpen: _autoplayOpen,
        onToggleFullscreen: _toggleFullscreen,
        onToggleMute: _toggleMute,
        onVolume: _setVolume,
        onVolumeDone: _volumeDone,
      ),
    );
    final panels = <Widget>[
      // Invitations wait at the top of the view until answered.
      Positioned(
        top: 0,
        left: _alliancesOpen && _panelLeft ? 440 : 0,
        right: _alliancesOpen && !_panelLeft ? 440 : 0,
        child: Center(
          child: ListenableBuilder(
            listenable: _c.hud,
            builder: (_, _) => InvitationCards(c: _c),
          ),
        ),
      ),
      AnimatedPositioned(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        top: 0,
        bottom: 0,
        left: _panelLeft ? (_alliancesOpen ? 0 : -450) : null,
        right: _panelLeft ? null : (_alliancesOpen ? 0 : -450),
        width: 440,
        onEnd: () {
          if (!_alliancesOpen) setState(() => _allianceShown = false);
        },
        // Built only while open or sliding, so a closed panel costs nothing.
        child: _alliancesOpen || _allianceShown
            ? ListenableBuilder(
                listenable: _c.hud,
                builder: (_, _) => AlliancePanel(c: _c, onClose: _toggleAlliances, dockedLeft: _panelLeft, onToggleSide: _togglePanelSide, blur: !compact),
              )
            : const SizedBox.shrink(),
      ),
      if (_autoplayOpen)
        Positioned(
          top: 6,
          right: compact ? 60 : 200,
          bottom: compact ? 6 : null,
          child: ListenableBuilder(
            listenable: _c.hud,
            builder: (_, _) => Align(
              alignment: Alignment.topRight,
              child: AutoplayPanel(
                c: _c,
                chosen: widget.settings.autoplayModes,
                onChoose: (m) {
                  widget.settings
                    ..autoplayModes = m
                    ..save();
                  setState(() {});
                },
                onClose: _toggleAutoplay,
              ),
            ),
          ),
        ),
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
    ];

    final Widget game;
    if (compact) {
      game = Stack(
        children: [
          Positioned.fill(child: GameViewport(controller: _c)),
          Positioned(top: 0, left: 0, right: 0, child: topBar),
          Positioned(
            left: 6,
            bottom: 6,
            width: 124,
            height: 124,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Colors.black,
                border: Border.all(color: const Color(0xFF2A2A2A)),
              ),
              child: MinimapView(controller: _c),
            ),
          ),
          Positioned(
            right: 6,
            bottom: 6,
            child: ListenableBuilder(
              listenable: _c.hud,
              builder: (_, _) => CommandCard(c: _c, compact: true),
            ),
          ),
          Positioned(
            left: 136,
            right: CommandCard.compactWidth + 12,
            bottom: 6,
            // Only as big as what's selected, so it hides little of the map.
            child: Align(
              alignment: Alignment.bottomLeft,
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 112),
                child: ListenableBuilder(
                  listenable: _c.hud,
                  builder: (_, _) => SelectionPanel(c: _c, compact: true),
                ),
              ),
            ),
          ),
          Positioned(
            top: 40,
            left: 140,
            right: 140,
            child: Center(
              child: ListenableBuilder(
                listenable: _c.hud,
                builder: (_, _) => HintToast(c: _c),
              ),
            ),
          ),
          Positioned(top: 32, left: 0, right: 0, bottom: 0, child: Stack(children: panels)),
        ],
      );
    } else {
      game = Column(
        children: [
          topBar,
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: GameViewport(controller: _c)),
                ...panels,
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
                    decoration: const BoxDecoration(
                      color: Colors.black,
                      border: Border(top: BorderSide(color: Color(0xFF2A2A2A))),
                    ),
                    child: MinimapView(controller: _c),
                  ),
                  Expanded(child: SelectionPanel(c: _c)),
                  SizedBox(width: 300, child: CommandCard(c: _c)),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return Scaffold(
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          children: [
            // Pointer tracked over the whole window so edge scrolling works
            // along every border, including over the panels.
            MouseRegion(
              onHover: (e) => _c.onWindowPointer(e.position, windowSize),
              onExit: (e) => _c.onWindowExit(e.position, windowSize),
              child: Listener(
                // Edge scrolling follows a mouse, never a finger.
                onPointerMove: (e) {
                  if (e.kind == PointerDeviceKind.mouse) _c.onWindowPointer(e.position, windowSize);
                },
                onPointerDown: (_) => _focus.requestFocus(),
                child: game,
              ),
            ),
            if (_c.mp case final mp?)
              ListenableBuilder(
                listenable: mp,
                builder: (_, _) => mp.advice == null ? const SizedBox.shrink() : _AdviceCard(advice: mp.advice!, onClose: mp.dismissAdvice),
              ),
            if (_menuOpen)
              _GameMenu(
                onResume: _closeMenu,
                onSave: _saveGame,
                onLoad: _loadGame,
                onExit: _exitToMenu,
                onQuit: _quit,
                autosave: widget.settings.autosave,
                onAutosave: _setAutosave,
                c: _c,
              ),
            if (_outcomeVisible) ListenableBuilder(listenable: _c.hud, builder: (_, _) => ScoreScreen(c: _c, onWatch: _keepWatching, onExit: () => _exitToMenu(confirm: false))),
          ],
        ),
      ),
    );
  }
}

/// Dims the game and offers the menu's choices; the game is paused while
/// it is open.
class _Overlay extends StatelessWidget {
  final Widget child;
  const _Overlay({required this.child});

  @override
  Widget build(BuildContext context) => Positioned.fill(
    // Opaque to the pointer: nothing reaches the game underneath.
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      onSecondaryTap: () {},
      child: MouseRegion(
        opaque: true,
        child: ColoredBox(
          color: const Color(0xB3000000),
          child: Center(
            // Phones in landscape are short: the menu scrolls.
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Container(
                width: 380,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.black,
                  border: Border.all(color: const Color(0xFF3A3A3A)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Advice from an assistant following this game (docs/agent_api.md),
/// until closed or the next advice.
class _AdviceCard extends StatelessWidget {
  final ({String from, String text}) advice;
  final VoidCallback onClose;
  const _AdviceCard({required this.advice, required this.onClose});

  @override
  Widget build(BuildContext context) => Positioned(
    top: 44,
    left: 0,
    right: 0,
    child: Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        decoration: BoxDecoration(
          color: const Color(0xE6101A12),
          border: Border.all(color: const Color(0xFF32D25A)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(padding: EdgeInsets.only(top: 2, right: 10), child: Icon(Icons.tips_and_updates_outlined, size: 18, color: Color(0xFF32D25A))),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(advice.from, style: const TextStyle(fontSize: 12, color: Color(0xFF32D25A), fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: SingleChildScrollView(child: Text(advice.text, style: const TextStyle(fontSize: 13, color: Color(0xFFE8E8E8)))),
                  ),
                ],
              ),
            ),
            IconButton(tooltip: 'Close', iconSize: 18, onPressed: onClose, icon: const Icon(Icons.close)),
          ],
        ),
      ),
    ),
  );
}

class _GameMenu extends StatelessWidget {
  final VoidCallback onResume;
  final VoidCallback onSave;
  final VoidCallback onLoad;
  final VoidCallback onExit;
  final VoidCallback onQuit;
  final bool autosave;
  final ValueChanged<bool> onAutosave;
  final GameController c;
  const _GameMenu({
    required this.onResume,
    required this.onSave,
    required this.onLoad,
    required this.onExit,
    required this.onQuit,
    required this.autosave,
    required this.onAutosave,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    const button = Size.fromHeight(44);
    // Scoreboard: highest points first.
    final players = [...c.players]
      ..sort((a, b) {
        int pts(GamePlayer p) => c.alliance.length == 8 ? c.alliance[p.slot].score : 0;
        return pts(b).compareTo(pts(a));
      });
    return _Overlay(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            c.mp != null && c.mp!.paused && c.mp!.pausedBy.isNotEmpty ? 'Paused by ${c.mp!.pausedBy}' : 'Game paused',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white),
          ),
          const SizedBox(height: 16),
          for (final p in players)
            Builder(
              builder: (_) {
                final rel = c.relation(p.slot);
                final out = c.alliance.length == 8 && !c.alliance[p.slot].active;
                final side = out
                    ? 'out'
                    : rel == Relation.own
                    ? ''
                    : rel == Relation.ally
                    ? 'ally'
                    : 'enemy';
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      PlayerSwatch(c.colorOf(p.slot), size: 10),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(c.nameOf(p.slot), style: TextStyle(color: p.slot == c.myPlayer || c.mp?.names[p.slot] != null ? Colors.white : const Color(0xFFBDBDBD))),
                      ),
                      Text(raceName(p.race), style: const TextStyle(color: Color(0xFF8C8C8C))),
                      SizedBox(
                        width: 64,
                        child: Text(
                          side,
                          maxLines: 1,
                          softWrap: false,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: side == 'ally'
                                ? const Color(0xFFFFE14D)
                                : side == 'out'
                                ? const Color(0xFF5E5E5E)
                                : const Color(0xFFFF6B5E),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 72,
                        child: Text(
                          formatPoints(c.alliance.length == 8 ? c.alliance[p.slot].score : 0),
                          textAlign: TextAlign.right,
                          style: const TextStyle(color: Color(0xFFFFD54F), fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()]),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: button),
            onPressed: onResume,
            child: const Text('Resume game'),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: button),
            onPressed: onSave,
            child: const Text('Save game'),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: button),
            onPressed: onLoad,
            child: const Text('Load game'),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: button),
            onPressed: onExit,
            child: const Text('Exit to main menu'),
          ),
          // A browser tab can't quit itself.
          if (!kIsWeb) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: button, foregroundColor: const Color(0xFFFF6B5E)),
              onPressed: onQuit,
              icon: const Icon(Icons.power_settings_new, size: 18),
              label: const Text('Quit Brood'),
            ),
          ],
          if (c.mp case final mp?) _assistants(mp),
          const SizedBox(height: 8),
          Row(
            children: [
              const Expanded(
                child: Text('Auto-save (every minute; every 10 after an hour)', style: TextStyle(fontSize: 13, color: Color(0xFFBDBDBD))),
              ),
              Switch(value: autosave, onChanged: onAutosave),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Esc or F10 opens and closes this menu.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Color(0xFF5E5E5E)),
          ),
        ],
      ),
    );
  }

  // Assistants following your game from outside (docs/agent_api.md) and
  // what they may do.
  Widget _assistants(MpSession mp) => ListenableBuilder(
    listenable: mp,
    builder: (_, _) => Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            mp.assistants.isEmpty ? 'Assistants: none connected' : 'Assistants: ${mp.assistants.join(', ')}',
            style: const TextStyle(fontSize: 13, color: Color(0xFFBDBDBD)),
          ),
          const SizedBox(height: 6),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 0, label: Text('Advise'), tooltip: 'They may only send you advice'),
              ButtonSegment(value: 1, label: Text('Auto-play'), tooltip: 'They may also steer your auto-play (attacks, targets, its numbers)'),
              ButtonSegment(value: 2, label: Text('Command'), tooltip: 'They may command all your units'),
            ],
            selected: {mp.allow},
            onSelectionChanged: (s) => mp.setAllow(s.first),
          ),
        ],
      ),
    ),
  );
}
