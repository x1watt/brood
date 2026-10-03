// The auto-play panel closes on a tap anywhere outside it, but not on a tap
// inside it or on its own top bar button (which toggles it instead).

import 'package:brood/game/game_controller.dart';
import 'package:brood/ui/autoplay_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a tap outside closes the auto-play panel', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = GameController();
    var open = true;
    var closes = 0;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Stack(
                children: [
                  const Positioned.fill(child: ColoredBox(key: Key('map'), color: Colors.black)),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: AutoplayButton(c: c, open: open, onPressed: () => setState(() => open = !open)),
                  ),
                  if (open)
                    Positioned(
                      top: 40,
                      right: 40,
                      child: AutoplayPanel(
                        c: c,
                        chosen: 15,
                        onChoose: (_) {},
                        onClose: () => setState(() {
                          closes++;
                          open = false;
                        }),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );

    // Inside the panel (its title): stays open.
    await tester.tap(find.text('Auto-play').last);
    await tester.pump();
    expect(open, isTrue);
    expect(closes, 0);

    // The button: toggles it closed, once, without also counting as outside.
    await tester.tap(find.byType(AutoplayButton));
    await tester.pump();
    expect(open, isFalse);
    expect(closes, 0);

    // Open again, then tap the map.
    rebuild(() => open = true);
    await tester.pump();
    await tester.tapAt(const Offset(100, 600));
    await tester.pump();
    expect(open, isFalse);
    expect(closes, 1);
  });
}
