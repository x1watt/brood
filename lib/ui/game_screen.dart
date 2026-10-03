// lib/ui/game_screen.dart
//
// The in-game screen: top bar, world view, minimap, selection panel and
// command card, plus the game menu (pause, save, exit) and the victory or
// defeat screen.

import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse, FramePhase, FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../game/game_controller.dart';
import '../game/game_data.dart';
import '../game/game_setup.dart';
import '../game/play_stats.dart';
import '../game/settings.dart';
import 'alliance_panel.dart';
import 'game_viewport.dart';
import 'hud.dart';
import 'minimap_view.dart';
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
        stderr.writeln(
          'perf fps=${((t.length - 1) * 1e6 / span).toStringAsFixed(1)} '
          'tick=${avg(_c.tickMicros).toStringAsFixed(2)}ms(worst ${(worst(_c.tickMicros) / 1000).toStringAsFixed(1)}) '
          'build=${avg(t.map((f) => f.buildDuration.inMicroseconds)).toStringAsFixed(2)}ms '
          'raster=${avg(t.map((f) => f.rasterDuration.inMicroseconds)).toStringAsFixed(2)}ms '
          'frame=${avg(t.map((f) => f.totalSpan.inMicroseconds)).toStringAsFixed(2)}ms(worst ${(worst(t.map((f) => f.totalSpan.inMicroseconds)) / 1000).toStringAsFixed(1)})',
        );
      });
    }
    _c.hud.addListener(_onHud);
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
      }
      setState(() {});
    });
  }

  // The result screen appears once, when the engine reports it.
  void _onHud() {
    if (!mounted) return;
    if (_c.outcome != null && !_outcomeShown) setState(() => _outcomeShown = true);
    if (!_c.ready && _c.loadingSave) setState(() {});
  }

  @override
  void dispose() {
    _c.hud.removeListener(_onHud);
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

  // --- game menu ---

  void _openMenu() {
    if (!_c.ready || _outcomeVisible) return;
    _c.setPaused(true);
    setState(() => _menuOpen = true);
  }

  void _closeMenu() {
    _c.setPaused(false);
    setState(() => _menuOpen = false);
    _focus.requestFocus();
  }

  bool get _outcomeVisible => _outcomeShown && _c.paused;

  void _toggleAlliances() {
    if (!_c.ready) return;
    setState(() => _alliancesOpen = !_alliancesOpen);
    _focus.requestFocus();
  }

  Future<void> _saveGame() async {
    final seconds = _c.frame * GameController.frameMicros ~/ 1000000;
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final suggested =
        '${widget.launch.mapName} ${seconds ~/ 60}:${two(seconds % 60)} (${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)})';
    final controller = TextEditingController(text: suggested)..selection = TextSelection(baseOffset: 0, extentOffset: suggested.length);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save game'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: (v) => Navigator.pop(ctx, v),
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
    try {
      _c.saveGame(name.trim().isEmpty ? suggested : name.trim());
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Game saved.'), duration: Duration(seconds: 2)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save the game: $e')));
    }
  }

  Future<void> _exitToMenu({bool confirm = true}) async {
    if (confirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Exit to main menu?'),
          content: const Text('Progress since your last save will be lost.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Exit')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    _flushPlayTime();
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const StartScreen()));
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
    // The game menu, as in the original: F10 opens it, Esc closes it.
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

    final arrow = _arrows[key];
    if (arrow != null) {
      if (e is KeyDownEvent) _c.setKeyScroll(arrow.$1, arrow.$2, true);
      if (e is KeyUpEvent) _c.setKeyScroll(arrow.$1, arrow.$2, false);
      return KeyEventResult.handled;
    }
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
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
                onPointerMove: (e) => _c.onWindowPointer(e.position, windowSize),
                onPointerDown: (_) => _focus.requestFocus(),
                child: Column(
                  children: [
                    ListenableBuilder(
                      listenable: _c.hud,
                      builder: (_, _) => TopBar(
                        c: _c,
                        fullscreen: _fullscreen,
                        onMenu: _openMenu,
                        onAlliances: _toggleAlliances,
                        alliancesOpen: _alliancesOpen,
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
                          // Invitations wait at the top of the view until answered.
                          Positioned(
                            top: 0,
                            left: 0,
                            right: _alliancesOpen ? 440 : 0,
                            child: Center(child: ListenableBuilder(listenable: _c.hud, builder: (_, _) => InvitationCards(c: _c))),
                          ),
                          AnimatedPositioned(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOutCubic,
                            top: 0,
                            bottom: 0,
                            right: _alliancesOpen ? 0 : -450,
                            width: 440,
                            child: ListenableBuilder(
                              listenable: _c.hud,
                              builder: (_, _) => AlliancePanel(c: _c, onClose: _toggleAlliances),
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
                ),
              ),
            ),
            if (_menuOpen) _GameMenu(onResume: _closeMenu, onSave: _saveGame, onExit: _exitToMenu, c: _c),
            if (_outcomeVisible) _OutcomeScreen(outcome: _c.outcome!, onWatch: _keepWatching, onExit: () => _exitToMenu(confirm: false)),
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
  );
}

class _GameMenu extends StatelessWidget {
  final VoidCallback onResume;
  final VoidCallback onSave;
  final VoidCallback onExit;
  final GameController c;
  const _GameMenu({required this.onResume, required this.onSave, required this.onExit, required this.c});

  @override
  Widget build(BuildContext context) {
    const button = Size.fromHeight(44);
    // Scoreboard: highest points first.
    final players = [...c.players]..sort((a, b) {
      int pts(GamePlayer p) => c.alliance.length == 8 ? c.alliance[p.slot].score : 0;
      return pts(b).compareTo(pts(a));
    });
    return _Overlay(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Game paused',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white),
          ),
          const SizedBox(height: 16),
          for (final p in players)
            Builder(builder: (_) {
              final rel = c.relation(p.slot);
              final out = c.alliance.length == 8 && !c.alliance[p.slot].active;
              final side = out ? 'out' : rel == Relation.own ? '' : rel == Relation.ally ? 'ally' : 'enemy';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    PlayerSwatch(c.colorOf(p.slot), size: 10),
                    const SizedBox(width: 8),
                    Expanded(child: Text(p.name, style: TextStyle(color: p.human ? Colors.white : const Color(0xFFBDBDBD)))),
                    Text(raceName(p.race), style: const TextStyle(color: Color(0xFF8C8C8C))),
                    SizedBox(
                      width: 50,
                      child: Text(
                        side,
                        textAlign: TextAlign.right,
                        style: TextStyle(color: side == 'ally' ? const Color(0xFFFFE14D) : side == 'out' ? const Color(0xFF5E5E5E) : const Color(0xFFFF6B5E)),
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
            }),
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
            onPressed: onExit,
            child: const Text('Exit to main menu'),
          ),
          const SizedBox(height: 12),
          const Text(
            'F10 opens this menu, Esc closes it.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Color(0xFF5E5E5E)),
          ),
        ],
      ),
    );
  }
}

class _OutcomeScreen extends StatelessWidget {
  final GameOutcome outcome;
  final VoidCallback onWatch;
  final VoidCallback onExit;
  const _OutcomeScreen({required this.outcome, required this.onWatch, required this.onExit});

  @override
  Widget build(BuildContext context) {
    final won = outcome == GameOutcome.victory;
    const button = Size.fromHeight(44);
    return _Overlay(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            won ? 'Victory!' : 'Defeat',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: won ? const Color(0xFF3CFF3C) : const Color(0xFFFF6B5E)),
          ),
          const SizedBox(height: 8),
          Text(
            won ? 'Every enemy has been defeated.' : 'All your buildings have been destroyed.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFBDBDBD)),
          ),
          const SizedBox(height: 24),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: button),
            onPressed: onExit,
            child: const Text('Exit to main menu'),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: button),
            onPressed: onWatch,
            child: Text(won ? 'Keep playing' : 'Watch the rest of the game'),
          ),
        ],
      ),
    );
  }
}
