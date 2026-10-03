import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';

import 'game/game_controller.dart';
import 'rendering/bw_painter.dart';
import 'rendering/camera.dart';

// Terran_SCV's ordinal in OpenBW's UnitTypes enum (engine/vendor/openbw/bwenums.h).
const int _unitTypeTerranScv = 7;

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

/// v0 playable viewer: hardcoded to the user's real install, Lost Temple.
/// Left click/drag to select, right click to move/attack/gather, arrow keys
/// to scroll the camera. No command card/build menu yet — "Train SCV"
/// covers the one production action needed to prove the command path end
/// to end.
class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  final GameController _controller = GameController();
  final Camera _camera = Camera();
  final FocusNode _focusNode = FocusNode();
  bool _cameraCentered = false;

  final Set<LogicalKeyboardKey> _heldKeys = {};
  static const double _cameraSpeed = 14;

  Offset? _dragStart;
  Offset? _dragCurrent;
  static const double _dragClickThreshold = 6;

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
    if (!_cameraCentered && _controller.sprites.isNotEmpty) {
      final owned = _controller.sprites.where((s) => s.owner == GameController.myPlayer).toList();
      final pool = owned.isNotEmpty ? owned : _controller.sprites;
      final avgX = pool.map((s) => s.x).reduce((a, b) => a + b) / pool.length;
      final avgY = pool.map((s) => s.y).reduce((a, b) => a + b) / pool.length;
      final size = MediaQuery.of(context).size;
      _camera.x = avgX - size.width / 2;
      _camera.y = avgY - size.height / 2;
      _cameraCentered = true;
    }

    if (_heldKeys.contains(LogicalKeyboardKey.arrowLeft)) _camera.pan(-_cameraSpeed, 0);
    if (_heldKeys.contains(LogicalKeyboardKey.arrowRight)) _camera.pan(_cameraSpeed, 0);
    if (_heldKeys.contains(LogicalKeyboardKey.arrowUp)) _camera.pan(0, -_cameraSpeed);
    if (_heldKeys.contains(LogicalKeyboardKey.arrowDown)) _camera.pan(0, _cameraSpeed);

    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onTick);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  (int x, int y) _toWorld(Offset screenPos) => (
    (screenPos.dx + _camera.x).round(),
    (screenPos.dy + _camera.y).round(),
  );

  void _handlePointerDown(PointerDownEvent event) {
    _focusNode.requestFocus();
    if (event.buttons & kPrimaryButton != 0) {
      setState(() {
        _dragStart = event.localPosition;
        _dragCurrent = event.localPosition;
      });
    } else if (event.buttons & kSecondaryButton != 0) {
      final (x, y) = _toWorld(event.localPosition);
      _controller.commandAt(x, y);
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_dragStart != null) {
      setState(() => _dragCurrent = event.localPosition);
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    final start = _dragStart;
    if (start == null) return;
    final end = event.localPosition;
    final dragDistance = (end - start).distance;

    if (dragDistance < _dragClickThreshold) {
      final (x, y) = _toWorld(end);
      _controller.selectAt(x, y);
    } else {
      final (x1, y1) = _toWorld(start);
      final (x2, y2) = _toWorld(end);
      _controller.selectBox(x1, y1, x2, y2);
    }

    setState(() {
      _dragStart = null;
      _dragCurrent = null;
    });
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

    final dragStart = _dragStart;
    final dragCurrent = _dragCurrent;
    final showDragBox =
        dragStart != null && dragCurrent != null && (dragCurrent - dragStart).distance >= _dragClickThreshold;

    return Scaffold(
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            _heldKeys.add(event.logicalKey);
          } else if (event is KeyUpEvent) {
            _heldKeys.remove(event.logicalKey);
          }
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.keyS) {
            _controller.stop();
          }
          return KeyEventResult.handled;
        },
        child: Stack(
          children: [
            // Input is scoped to just the game viewport (not the whole
            // Stack) so clicks on HUD widgets above it — the Train SCV
            // button — don't also fall through as a world click/selection:
            // Listener sees every raw pointer event in its own hit-test
            // area regardless of what a descendant does with it, so it
            // must simply not cover the HUD's screen region at all.
            Listener(
              onPointerDown: _handlePointerDown,
              onPointerMove: _handlePointerMove,
              onPointerUp: _handlePointerUp,
              child: CustomPaint(
                painter: BwPainter(
                  sprites: _controller.sprites,
                  atlas: _controller.atlas,
                  camera: _camera,
                  terrain: _controller.terrain,
                  selectedUnitIds: _controller.selectedUnitIds,
                ),
                size: Size.infinite,
              ),
            ),
            if (showDragBox)
              Positioned.fromRect(
                rect: Rect.fromPoints(dragStart, dragCurrent),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.greenAccent, width: 1),
                    color: Colors.greenAccent.withValues(alpha: 0.1),
                  ),
                ),
              ),
            _Hud(controller: _controller),
          ],
        ),
      ),
    );
  }
}

/// Minimal HUD: resources/supply and a one-button production action, enough
/// to validate the full command loop (not a real command card).
class _Hud extends StatelessWidget {
  final GameController controller;
  const _Hud({required this.controller});

  @override
  Widget build(BuildContext context) {
    final minerals = controller.engine.minerals(GameController.myPlayer);
    final gas = controller.engine.gas(GameController.myPlayer);
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: Colors.black.withValues(alpha: 0.55),
        child: Row(
          children: [
            Text(
              'Minerals: $minerals   Gas: $gas   Supply: '
              '${controller.suppliesUsed.toStringAsFixed(0)}/${controller.suppliesAvailable.toStringAsFixed(0)}   '
              'Selected: ${controller.selectedUnitIds.length}',
              style: const TextStyle(color: Colors.white),
            ),
            const Spacer(),
            ElevatedButton(
              onPressed: () => controller.train(_unitTypeTerranScv),
              child: const Text('Train SCV'),
            ),
          ],
        ),
      ),
    );
  }
}
