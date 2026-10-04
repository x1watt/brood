// lib/ui/score_screen.dart
//
// The end of a game, as in the original: Victory or Defeat over the
// original's picture for your race (from the player's own game files), and
// every player's numbers in four tabs: Units (produced, killed, lost),
// Structures (constructed, razed, lost), Resources (minerals and gas mined,
// spent) and Score (units, structures, resources, their total, and this
// game's alliance score). Numbers count up when a tab opens.

import 'package:flutter/material.dart';

import '../engine/models.dart';
import '../game/game_controller.dart';
import '../game/game_setup.dart';
import 'alliance_panel.dart';

const _green = Color(0xFF32D25A);
const _greenDim = Color(0xFF1C7A36);
const _yellow = Color(0xFFFCE45C);
const _text = Color(0xFFE8E8E8);
const _dim = Color(0xFF8C8C8C);
const _victory = Color(0xFF3CFF3C);
const _defeat = Color(0xFFFF6B5E);

enum _Tab {
  units('Units', ['Produced', 'Killed', 'Lost']),
  structures('Structures', ['Constructed', 'Razed', 'Lost']),
  resources('Resources', ['Minerals mined', 'Gas mined', 'Spent']),
  score('Score', ['Units', 'Structures', 'Resources', 'Alliance', 'Total']);

  final String label;
  final List<String> columns;
  const _Tab(this.label, this.columns);
}

class ScoreScreen extends StatefulWidget {
  final GameController c;
  final VoidCallback onExit;
  final VoidCallback onWatch;
  const ScoreScreen({super.key, required this.c, required this.onExit, required this.onWatch});

  @override
  State<ScoreScreen> createState() => _ScoreScreenState();
}

class _ScoreScreenState extends State<ScoreScreen> {
  _Tab _tab = _Tab.score;
  late final Map<int, PlayerStats> _stats = widget.c.playerStats();

  GameController get c => widget.c;

  List<int> _values(int slot) {
    final s = _stats[slot] ?? const PlayerStats();
    return switch (_tab) {
      _Tab.units => [s.unitsProduced, s.unitsKilled, s.unitsLost],
      _Tab.structures => [s.buildingsBuilt, s.buildingsRazed, s.buildingsLost],
      _Tab.resources => [s.mineralsMined, s.gasMined, s.mineralsSpent + s.gasSpent],
      _Tab.score => [s.unitsScore, s.structuresScore, s.resourcesScore, _allianceScore(slot), s.totalScore],
    };
  }

  int _allianceScore(int slot) => slot < c.alliance.length ? c.alliance[slot].score : 0;

  // Your side, the others' relation to you, or out of the game.
  (String, Color) _side(int slot) {
    if (slot == c.myPlayer) return ('', _text);
    final out = slot < c.alliance.length && !c.alliance[slot].active;
    if (out) return ('defeated', const Color(0xFF5E5E5E));
    return switch (c.relation(slot)) {
      Relation.ally => ('ally', const Color(0xFFFFE14D)),
      _ => ('enemy', _defeat),
    };
  }

  @override
  Widget build(BuildContext context) {
    final won = c.outcome == GameOutcome.victory;
    final art = c.outcomeArt;
    final seconds = (c.frame * GameController.frameMicros) ~/ 1000000;
    final time = '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final players = [...c.players]..sort((a, b) => (_stats[b.slot]?.totalScore ?? 0).compareTo(_stats[a.slot]?.totalScore ?? 0));
    final short = MediaQuery.sizeOf(context).height < 500;

    return Positioned.fill(
      // Opaque to the pointer: nothing reaches the game underneath.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        onSecondaryTap: () {},
        child: MouseRegion(
          opaque: true,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Colors.black),
              if (art != null) RawImage(image: art, fit: BoxFit.cover, filterQuality: FilterQuality.medium),
              const DecoratedBox(
                decoration: BoxDecoration(gradient: RadialGradient(radius: 1.2, colors: [Color(0x55000000), Color(0xCC000000)])),
              ),
              SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(short ? 8 : 24),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 940),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            won ? 'VICTORY!' : 'DEFEAT',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: short ? 32 : 46,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 6,
                              color: won ? _victory : _defeat,
                              shadows: [Shadow(color: (won ? _victory : _defeat).withValues(alpha: 0.6), blurRadius: 18)],
                            ),
                          ),
                          Text(
                            '${won ? 'Every enemy has been defeated.' : 'All your buildings have been destroyed.'}  Game time $time',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Color(0xFFBDBDBD)),
                          ),
                          SizedBox(height: short ? 10 : 20),
                          _tabs(),
                          const SizedBox(height: 8),
                          _table(players),
                          SizedBox(height: short ? 10 : 20),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size(220, 44),
                                  backgroundColor: const Color(0xFF15502A),
                                  foregroundColor: _yellow,
                                  side: const BorderSide(color: _green, width: 1.5),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                ),
                                onPressed: widget.onExit,
                                child: const Text('EXIT TO MAIN MENU', style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 1.2)),
                              ),
                              const SizedBox(width: 12),
                              OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(220, 44),
                                  foregroundColor: _green,
                                  side: const BorderSide(color: _greenDim),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                ),
                                onPressed: widget.onWatch,
                                child: Text(won ? 'Keep playing' : 'Watch the rest of the game'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabs() => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      for (final t in _Tab.values)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => setState(() => _tab = t),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                color: t == _tab ? const Color(0xFF123A1E) : const Color(0x99000000),
                border: Border.all(color: t == _tab ? _green : _greenDim),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                t.label.toUpperCase(),
                style: TextStyle(color: t == _tab ? _yellow : _green, fontWeight: FontWeight.w700, letterSpacing: 1.4),
              ),
            ),
          ),
        ),
    ],
  );

  Widget _table(List<GamePlayer> players) {
    const nameWidth = 250.0, colWidth = 128.0;
    final cols = _tab.columns;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xC4000000),
        border: Border.all(color: _greenDim, width: 1.5),
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [BoxShadow(color: Color(0x5532D25A), blurRadius: 14)],
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      // Centered when it fits; scrolls sideways on a narrow screen.
      child: Center(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // (Centered when it fits; scrolls sideways on a narrow screen.)
          child: SizedBox(
            width: nameWidth + colWidth * cols.length,
            // Every number counts up from zero when the tab opens.
            child: TweenAnimationBuilder<double>(
              key: ValueKey(_tab),
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 1400),
              curve: Curves.easeOutCubic,
              builder: (context, t, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const SizedBox(width: nameWidth),
                      for (final col in cols)
                        SizedBox(
                          width: colWidth,
                          child: Text(
                            col.toUpperCase(),
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 11, letterSpacing: 1.4, color: _green, fontWeight: FontWeight.w700),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  for (final p in players) _row(p, nameWidth, colWidth, t),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(GamePlayer p, double nameWidth, double colWidth, double t) {
    final me = p.slot == c.myPlayer;
    final (side, sideColor) = _side(p.slot);
    final values = _values(p.slot);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
      decoration: BoxDecoration(color: me ? const Color(0x3332D25A) : null, borderRadius: BorderRadius.circular(4)),
      child: Row(
        children: [
          SizedBox(
            width: nameWidth - 12,
            child: Row(
              children: [
                PlayerSwatch(c.colorOf(p.slot)),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    c.nameOf(p.slot),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: me ? Colors.white : _text, fontWeight: me ? FontWeight.w800 : FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                Text(raceName(p.race), style: const TextStyle(color: _dim, fontSize: 12)),
                if (side.isNotEmpty) ...[const SizedBox(width: 6), Text(side, style: TextStyle(color: sideColor, fontSize: 12))],
              ],
            ),
          ),
          for (int i = 0; i < values.length; ++i)
            SizedBox(
              width: colWidth,
              child: Text(
                formatPoints((values[i] * t).round()),
                textAlign: TextAlign.right,
                style: TextStyle(
                  // The total stands out.
                  color: _tab == _Tab.score && i == values.length - 1 ? _yellow : _text,
                  fontWeight: _tab == _Tab.score && i == values.length - 1 ? FontWeight.w800 : FontWeight.w600,
                  fontSize: 15,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
