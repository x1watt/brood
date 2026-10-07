// lib/ui/ownership_screen.dart
//
// Asked once: the player confirms they have a copy of the original game's
// files. No leaves the game (in the browser the page goes blank). Pages from
// a home server don't ask (lib/main.dart).

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../game/settings.dart';
import 'web_fullscreen.dart';
import 'window_control.dart';

const _faint = Color(0xFF5E5E5E);
const _line = Color(0xFF2A2A2A);

class OwnershipScreen extends StatelessWidget {
  /// The screen that follows a yes.
  final Widget next;
  const OwnershipScreen({super.key, required this.next});

  void _yes(BuildContext context) {
    Settings.load()
      ..ownsGameFiles = true
      ..save();
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => next));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Container(
          width: 480,
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            border: Border.all(color: _line),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Brood',
                style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: Colors.white),
              ),
              const SizedBox(height: 16),
              const Text('I have a copy of the original game files.', style: TextStyle(fontSize: 16, height: 1.4)),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      onPressed: kIsWeb ? webLeave : WindowControl.quit,
                      child: const Text('No'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      autofocus: true,
                      onPressed: () => _yes(context),
                      child: const Text('Yes'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const Text('Brood is not affiliated with Blizzard Entertainment.', style: TextStyle(fontSize: 11, color: _faint)),
            ],
          ),
        ),
      ),
    );
  }
}
