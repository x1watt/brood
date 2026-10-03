import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'engine/models.dart';
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
      home: const GameScreen(),
    );
  }
}

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with SingleTickerProviderStateMixin {
  final GameController _c = GameController();
  final FocusNode _focus = FocusNode();
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    // Simulation pacing follows the display's vsync, not a Timer: a Timer
    // beating against the refresh rate made motion judder.
    _ticker = createTicker(_c.tick)..start();
    final home = Platform.environment['HOME'] ?? '';
    final dataDir = Platform.environment['BROOD_DATA'] ?? '$home/box/media/games/BROOD';
    final map = Platform.environment['BROOD_MAP'] ?? '$dataDir/maps/ladder/(4)Lost Temple.scm';
    _c.start(dataDir: dataDir, mapFile: map).then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  static final _arrows = {
    LogicalKeyboardKey.arrowLeft: (-1, 0),
    LogicalKeyboardKey.arrowRight: (1, 0),
    LogicalKeyboardKey.arrowUp: (0, -1),
    LogicalKeyboardKey.arrowDown: (0, 1),
  };

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final arrow = _arrows[e.logicalKey];
    if (arrow != null) {
      if (e is KeyDownEvent) _c.setKeyScroll(arrow.$1, arrow.$2, true);
      if (e is KeyUpEvent) _c.setKeyScroll(arrow.$1, arrow.$2, false);
      return KeyEventResult.handled;
    }
    if (e is! KeyDownEvent || !_c.ready) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _c.cancelMode();
    } else if (key == LogicalKeyboardKey.keyA) {
      _c.setMode(CommandMode.attack);
    } else if (key == LogicalKeyboardKey.keyM) {
      _c.setMode(CommandMode.move);
    } else if (key == LogicalKeyboardKey.keyP) {
      _c.setMode(CommandMode.patrol);
    } else if (key == LogicalKeyboardKey.keyS) {
      _c.instantOrder(UnitOrder.stop);
    } else if (key == LogicalKeyboardKey.keyH) {
      _c.instantOrder(UnitOrder.hold);
    } else if (key == LogicalKeyboardKey.space) {
      final sel = _c.selectedUnits;
      if (sel.isNotEmpty) _c.centerOn(sel.first.x.toDouble(), sel.first.y.toDouble());
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(
          children: [
            ListenableBuilder(listenable: _c.hud, builder: (_, _) => TopBar(c: _c)),
            Expanded(
              child: Listener(
                onPointerDown: (_) => _focus.requestFocus(),
                child: GameViewport(controller: _c),
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
                    SizedBox(width: 340, child: CommandCard(c: _c)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
