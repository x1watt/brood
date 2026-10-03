// Touch gestures on the world view (lib/ui/game_viewport.dart), with a
// controller that records what it is asked to do instead of driving an
// engine: two fingers pan, one finger boxes, a drag from the selection
// gives a command, holding still gives it in place, a tap selects.

import 'dart:ui' show PointerDeviceKind;

import 'package:brood/game/game_controller.dart';
import 'package:brood/ui/game_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Recorder extends GameController {
  bool onSelection = false; // whether a finger lands on the selected units
  Rect? boxed;
  Offset? commanded;
  bool commandedByTouch = false;
  Offset? tapped;
  final List<Offset?> arrow = [];

  @override
  bool get selectionCommandable => true;

  @override
  bool nearSelected(Offset screen) => onSelection;

  @override
  int pickNear(Offset map, {double slop = 0, bool ownFirst = false, bool skipSelected = false}) => 0;

  @override
  void boxSelect(Rect screenRect, {bool add = false}) => boxed = screenRect;

  @override
  void smartCommand(Offset mapPos, {bool queue = false, bool touch = false}) {
    commanded = mapPos;
    commandedByTouch = touch;
  }

  @override
  void clickSelect(Offset screen, {bool add = false, bool touch = false}) => tapped = screen;

  @override
  void setCommandDrag(Offset? to) {
    commandDragTo = to;
    arrow.add(to);
  }
}

Future<_Recorder> _view(WidgetTester tester) async {
  tester.view.physicalSize = const Size(820, 360);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final c = _Recorder();
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: GameViewport(controller: c))));
  return c;
}

Future<TestGesture> _finger(WidgetTester tester, Offset at, int pointer) => tester.startGesture(at, kind: PointerDeviceKind.touch, pointer: pointer);

void main() {
  testWidgets('two fingers move the map and select nothing', (tester) async {
    final c = await _view(tester);
    c.camX = 500;
    c.camY = 400;
    final a = await _finger(tester, const Offset(300, 150), 1);
    final b = await _finger(tester, const Offset(400, 150), 2);
    for (int i = 0; i < 5; ++i) {
      await a.moveBy(const Offset(-12, -8));
      await b.moveBy(const Offset(-12, -8));
    }
    await a.up();
    await b.up();
    // The map follows the fingers: dragging left and up shows what's right and below.
    expect(c.camX, 560);
    expect(c.camY, 440);
    expect(c.boxed, isNull);
    expect(c.commanded, isNull);
    expect(c.tapped, isNull);
  });

  testWidgets('a second finger cancels the box the first one started', (tester) async {
    final c = await _view(tester);
    final a = await _finger(tester, const Offset(100, 100), 1);
    await a.moveBy(const Offset(60, 40));
    expect(c.dragBox, isNotNull);
    final b = await _finger(tester, const Offset(500, 100), 2);
    expect(c.dragBox, isNull);
    await a.up();
    await b.up();
    expect(c.boxed, isNull);
  });

  testWidgets('one finger on the ground draws a box and selects in it', (tester) async {
    final c = await _view(tester);
    final a = await _finger(tester, const Offset(100, 100), 1);
    await a.moveBy(const Offset(40, 30));
    await a.moveBy(const Offset(40, 30));
    await a.up();
    expect(c.boxed, Rect.fromPoints(const Offset(100, 100), const Offset(180, 160)));
    expect(c.commanded, isNull);
  });

  testWidgets('dragging from the selection shows the arrow and commands where it lifts', (tester) async {
    final c = await _view(tester);
    c.camX = 1000;
    c.onSelection = true;
    final a = await _finger(tester, const Offset(200, 200), 1);
    await a.moveBy(const Offset(60, 0));
    await a.moveBy(const Offset(60, -40));
    expect(c.commandDragTo, const Offset(320, 160));
    await a.up();
    expect(c.commandDragTo, isNull);
    expect(c.commanded, const Offset(1320, 160)); // map space
    expect(c.commandedByTouch, isTrue);
    expect(c.boxed, isNull);
  });

  testWidgets('holding a finger still gives the command there', (tester) async {
    final c = await _view(tester);
    final a = await _finger(tester, const Offset(400, 120), 1);
    await tester.pump(const Duration(milliseconds: 600));
    expect(c.commanded, const Offset(400, 120));
    await a.up();
    expect(c.tapped, isNull); // the hold isn't also a tap
  });

  testWidgets('a tap selects (a small wobble is still a tap)', (tester) async {
    final c = await _view(tester);
    final a = await _finger(tester, const Offset(250, 90), 1);
    await a.moveBy(const Offset(4, 3));
    await a.up();
    expect(c.tapped, const Offset(254, 93));
    expect(c.boxed, isNull);
    expect(c.commanded, isNull);
  });
}
