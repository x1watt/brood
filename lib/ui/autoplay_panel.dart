// lib/ui/autoplay_panel.dart
//
// Auto-play: the computer player plays your side with you, limited to what
// you pick. A button in the top bar shows whether it's on and opens this
// panel. The rules live in the bridge (engine/bridge/src/bw_ai.h): units you
// command or keep in a control group stay yours, and defending the base
// always comes first, whatever the modes.

import 'package:flutter/material.dart';

import '../engine/models.dart';
import '../game/game_controller.dart';

const _accent = Color(0xFF7FD4FF);
const _text = Color(0xFFE8E8E8);
const _dim = Color(0xFF8C8C8C);
const _faint = Color(0xFF5E5E5E);
const _line = Color(0xFF2A2A2A);

class _Option {
  final int bits;
  final IconData icon;
  final String title;
  final String description;
  const _Option(this.bits, this.icon, this.title, this.description);
}

const _auto = _Option(AutoplayMode.all, Icons.auto_awesome, 'Auto', 'Plays like a computer player: everything below.');
const _options = [
  _Option(1, Icons.diamond_outlined, 'Resources', 'Workers on minerals and gas, more workers, spread evenly over your bases.'),
  _Option(2, Icons.domain_add_outlined, 'Building', 'Every building and upgrade of the build order as soon as it can.'),
  _Option(4, Icons.gps_fixed, 'Attacking', 'Trains an army and attacks nearby enemies, like any computer player.'),
  _Option(8, Icons.travel_explore, 'Colonizing', 'Takes new mineral fields: town hall, workers and defences.'),
];

String autoplaySummary(int modes) {
  if (modes == 0) return 'Off';
  if (modes == AutoplayMode.all) return 'Auto';
  return [
    for (final o in _options)
      if (modes & o.bits != 0) o.title,
  ].join(' + ');
}

/// Top bar button: shows what auto-play is doing, opens the panel.
class AutoplayButton extends StatelessWidget {
  final GameController c;
  final bool open;
  final VoidCallback onPressed;
  final bool compact; // icon only
  const AutoplayButton({super.key, required this.c, required this.open, required this.onPressed, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final on = c.autoplay != 0;
    // Same tap group as the panel: tapping the button isn't a tap outside.
    return TapRegion(
      groupId: AutoplayPanel.tapGroup,
      child: Tooltip(
        message: 'Auto-play (F8)',
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onPressed,
          child: Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: on ? _accent.withValues(alpha: 0.8) : (open ? const Color(0xFF555555) : _line)),
              color: on ? _accent.withValues(alpha: 0.12) : (open ? const Color(0xFF1A1A1A) : null),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.smart_toy_outlined, size: 16, color: on ? _accent : _text),
                if (!compact) ...[
                  const SizedBox(width: 6),
                  Text(on ? 'Auto-play: ${autoplaySummary(c.autoplay)}' : 'Auto-play', style: TextStyle(color: on ? _accent : _text, fontSize: 12)),
                  const SizedBox(width: 2),
                  Icon(open ? Icons.expand_less : Icons.expand_more, size: 16, color: _dim),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AutoplayPanel extends StatelessWidget {
  final GameController c;
  final int chosen; // what switching on runs (remembered between games)
  final ValueChanged<int> onChoose;
  final VoidCallback onClose;
  const AutoplayPanel({super.key, required this.c, required this.chosen, required this.onChoose, required this.onClose});

  /// The panel and its top bar button: a tap anywhere else closes the panel.
  static const Object tapGroup = AutoplayPanel;

  bool get _on => c.autoplay != 0;
  int get _modes => _on ? c.autoplay : chosen;

  void _toggle(bool on) => c.setAutoplay(on ? chosen : 0);

  // Auto is everything; a single mode picked while everything is on means
  // "just this"; otherwise modes add and remove (never down to none).
  void _pick(_Option o) {
    int next;
    if (o.bits == AutoplayMode.all) {
      next = AutoplayMode.all;
    } else if (_modes == AutoplayMode.all) {
      next = o.bits;
    } else {
      next = _modes ^ o.bits;
      if (next == 0) return;
    }
    onChoose(next);
    if (_on) c.setAutoplay(next);
  }

  @override
  Widget build(BuildContext context) {
    final modes = _modes;
    return TapRegion(
      groupId: tapGroup,
      onTapOutside: (_) => onClose(),
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 380,
          decoration: BoxDecoration(
            color: const Color(0xF2080808),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _on ? _accent.withValues(alpha: 0.5) : const Color(0xFF333333)),
            boxShadow: const [BoxShadow(color: Color(0xAA000000), blurRadius: 24)],
          ),
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
          // On a phone the panel is taller than the screen: it scrolls.
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.smart_toy_outlined, color: _on ? _accent : _text, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Auto-play',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white),
                      ),
                    ),
                    Switch(
                      value: _on,
                      onChanged: _toggle,
                      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.black : _dim),
                      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? _accent : const Color(0xFF1E1E1E)),
                      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? _accent : const Color(0xFF444444)),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: onClose,
                      icon: const Icon(Icons.close, size: 18, color: _dim),
                    ),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.only(right: 6, bottom: 8),
                  child: Text(
                    'The computer plays your side with you. Units you command or keep in a control group stay yours, '
                    'and defending your base always comes first.',
                    style: TextStyle(fontSize: 12, color: _dim, height: 1.35),
                  ),
                ),
                _tile(_auto, modes == AutoplayMode.all, included: false),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Divider(height: 1, color: _line),
                ),
                for (final o in _options) _tile(o, modes & o.bits != 0, included: modes == AutoplayMode.all),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tile(_Option o, bool selected, {required bool included}) {
    final active = selected && _on;
    final color = active ? _accent : (selected ? _text : _dim);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _pick(o),
      child: Container(
        margin: const EdgeInsets.only(right: 6, top: 2, bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: selected && !included ? (active ? _accent.withValues(alpha: 0.10) : const Color(0xFF151515)) : null,
          border: Border.all(color: selected && !included ? (active ? _accent.withValues(alpha: 0.6) : const Color(0xFF3A3A3A)) : Colors.transparent),
        ),
        child: Row(
          children: [
            Icon(o.icon, size: 20, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    o.title,
                    style: TextStyle(fontWeight: FontWeight.w700, color: selected ? Colors.white : _text),
                  ),
                  const SizedBox(height: 1),
                  Text(o.description, style: const TextStyle(fontSize: 11.5, color: _faint)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? (included ? color.withValues(alpha: 0.6) : color) : const Color(0xFF444444),
            ),
          ],
        ),
      ),
    );
  }
}
