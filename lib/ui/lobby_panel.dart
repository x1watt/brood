// lib/ui/lobby_panel.dart
//
// The start screen's Multiplayer tab: the games running on the home server
// (tool/brood_server.dart), each with its players by alliance. Any player
// the computer plays can be taken over: you join the game in its place,
// with its alliance. Every game started from a page of the home server is
// listed here for the others.

import 'package:flutter/material.dart';

import '../game/game_controller.dart';
import '../game/game_setup.dart';
import '../net/multiplayer.dart';

const _green = Color(0xFF32D25A);
const _yellow = Color(0xFFFCE45C);
const _dim = Color(0xFF8C8C8C);
const _faint = Color(0xFF5E5E5E);
const _line = Color(0xFF2A2A2A);

class LobbyPanel extends StatefulWidget {
  final MpClient client;
  final void Function(LobbyGame game, LobbySlot slot) onJoin;
  final ValueChanged<String> onRename;
  const LobbyPanel({super.key, required this.client, required this.onJoin, required this.onRename});

  @override
  State<LobbyPanel> createState() => _LobbyPanelState();
}

class _LobbyPanelState extends State<LobbyPanel> {
  late final _name = TextEditingController(text: widget.client.name == 'Player' ? '' : widget.client.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  static String _time(int frame) {
    final s = frame * GameController.frameMicros ~/ 1000000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: _line));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(
            children: [
              SizedBox(
                width: 260,
                child: TextField(
                  controller: _name,
                  onChanged: widget.onRename,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: 'Your name',
                    hintText: 'Player',
                    prefixIcon: const Icon(Icons.person_outline, size: 18, color: _dim),
                    border: border,
                    enabledBorder: border,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ValueListenableBuilder<List<String>>(
                  valueListenable: widget.client.urls,
                  builder: (_, urls, _) => Text(
                    urls.isEmpty
                        ? 'Others at home join from this computer\'s network address, port ${Uri.base.port}.'
                        : 'Others at home open ${urls.join('  or  ')} in their browser.',
                    style: const TextStyle(fontSize: 12, color: _dim),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ValueListenableBuilder<List<LobbyGame>>(
            valueListenable: widget.client.games,
            builder: (_, games, _) => games.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No games running. A game started on this server shows up here for the others,\n'
                        'who can join it by taking over one of the computer players.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: _dim),
                      ),
                    ),
                  )
                : ListView(padding: const EdgeInsets.only(bottom: 12), children: [for (final g in games) _game(g)]),
          ),
        ),
      ],
    );
  }

  Widget _game(LobbyGame g) {
    final groups = <int, List<LobbySlot>>{};
    for (final s in g.slots) {
      groups.putIfAbsent(s.group, () => []).add(s);
    }
    final humans = g.slots.where((s) => s.human != null).map((s) => s.human).join(', ');
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(border: Border.all(color: _line), borderRadius: BorderRadius.circular(6)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(g.mapName, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white))),
              Text(
                '${_time(g.frame)}${g.paused ? '  paused' : ''}  ·  ${humans.isEmpty ? 'nobody playing' : humans}',
                style: const TextStyle(fontSize: 12, color: _dim),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final e in groups.entries) ...[
            if (groups.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 2),
                child: Text(
                  e.value.length > 1 ? 'ALLIANCE' : 'ALONE',
                  style: const TextStyle(fontSize: 10, letterSpacing: 1.4, color: _green, fontWeight: FontWeight.w700),
                ),
              ),
            for (final s in e.value) _slot(g, s),
          ],
        ],
      ),
    );
  }

  Widget _slot(LobbyGame g, LobbySlot s) {
    final playing = s.human != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(playing ? Icons.person : Icons.smart_toy_outlined, size: 16, color: playing ? _yellow : _dim),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              playing && s.human != s.name ? '${s.human} (was ${s.name})' : s.name,
              style: TextStyle(color: s.active ? (playing ? Colors.white : const Color(0xFFBDBDBD)) : _faint),
            ),
          ),
          Text(raceName(s.race), style: const TextStyle(color: _dim, fontSize: 12)),
          const SizedBox(width: 12),
          SizedBox(
            width: 150,
            child: !s.active
                ? const Text('defeated', textAlign: TextAlign.right, style: TextStyle(color: _faint, fontSize: 12))
                : playing
                ? const SizedBox()
                : FilledButton(onPressed: () => widget.onJoin(g, s), child: const Text('Play this one')),
          ),
        ],
      ),
    );
  }
}
