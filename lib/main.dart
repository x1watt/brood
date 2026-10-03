import 'dart:io';

import 'package:flutter/material.dart';

import 'game/game_controller.dart';
import 'rendering/bw_painter.dart';
import 'rendering/camera.dart';

void main() {
  runApp(const BroodApp());
}

class BroodApp extends StatelessWidget {
  const BroodApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Brood — engine port (v0)',
      theme: ThemeData.dark(),
      home: const GameScreen(),
    );
  }
}

/// v0 viewer: hardcoded to the user's real install, Lost Temple, no HUD or
/// input yet (Phase 6) — this page exists to prove the engine/bridge/
/// rendering pipeline actually shows real sprites in a live Flutter window.
class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  final GameController _controller = GameController();
  final Camera _camera = Camera();
  bool _cameraCentered = false;

  @override
  void initState() {
    super.initState();
    final home = Platform.environment['HOME'] ?? '';
    _controller.start(
      dataDir: '$home/box/media/games/BROOD',
      mapFile: '$home/box/media/games/BROOD/maps/ladder/(4)Lost Temple.scm',
    );
    _controller.addListener(_onTick);
  }

  void _onTick() {
    // Center the camera once real unit positions are known, instead of
    // guessing map coordinates ahead of time — different maps/start
    // locations would need different guesses. Proper camera follow/clamp
    // is a Phase 6 concern; this just gets the first frame on screen.
    if (!_cameraCentered && _controller.sprites.isNotEmpty) {
      final owned = _controller.sprites.where((s) => s.owner == 0).toList();
      final pool = owned.isNotEmpty ? owned : _controller.sprites;
      final avgX = pool.map((s) => s.x).reduce((a, b) => a + b) / pool.length;
      final avgY = pool.map((s) => s.y).reduce((a, b) => a + b) / pool.length;
      final size = MediaQuery.of(context).size;
      _camera.x = avgX - size.width / 2;
      _camera.y = avgY - size.height / 2;
      _cameraCentered = true;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onTick);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller.error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Engine failed to start:\n${_controller.error}',
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: GestureDetector(
        onPanUpdate: (details) {
          _camera.pan(-details.delta.dx, -details.delta.dy);
          setState(() {});
        },
        child: CustomPaint(
          painter: BwPainter(
            sprites: _controller.sprites,
            atlas: _controller.atlas,
            camera: _camera,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}
