// lib/ui/alliance_panel.dart
//
// Diplomacy in the game: the alliance panel (who is allied with whom,
// points, invitations, leaving) and the invitation cards that pop up when
// someone asks you to join. The rules live in the bridge
// (engine/bridge/src/bw_alliances.h); this only shows them and forwards
// your choices.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../engine/models.dart';
import '../game/game_controller.dart';
import '../game/game_setup.dart';

const _panel = Color(0xF2050505);
const _card = Color(0xFF0D0D0D);
const _line = Color(0xFF262626);
const _text = Color(0xFFE8E8E8);
const _dim = Color(0xFF8C8C8C);
const _faint = Color(0xFF5E5E5E);
const _gold = Color(0xFFFFD54F);
const _allyColor = Color(0xFFFFE14D);
const _danger = Color(0xFFFF6B5E);
const _mineral = Color(0xFF6FD3FF);
const _gasColor = Color(0xFF4CE07A);

String formatPoints(int v) {
  final s = v.abs().toString();
  final b = StringBuffer(v < 0 ? '-' : '');
  for (int i = 0; i < s.length; ++i) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// 1,234 below ten thousand, then 12.3k, 1.2M.
String compactPoints(int v) {
  if (v.abs() < 10000) return formatPoints(v);
  if (v.abs() < 1000000) return '${(v / 1000).toStringAsFixed(v.abs() < 100000 ? 1 : 0)}k';
  return '${(v / 1000000).toStringAsFixed(1)}M';
}

/// What makes up a player's score, for tooltips.
String scoreBreakdown(AlliancePlayer? a, {bool allied = false}) {
  if (a == null) return 'Score';
  return 'Score ${formatPoints(a.score)}\n'
      'Mined: ${formatPoints(a.points)}${allied ? ' (everything your alliance mines counts)' : ''}\n'
      'Built: ${formatPoints(a.productionScore)}\n'
      'Destroyed: ${formatPoints(a.killScore)} (${a.unitsKilled} units, ${a.buildingsRazed} buildings)\n'
      'Units lost: ${a.unitsLost}';
}

String _gameTime(int frame) {
  final seconds = frame * GameController.frameMicros ~/ 1000000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// A small colored square with the player's in-game color.
class PlayerSwatch extends StatelessWidget {
  final Color color;
  final double size;
  const PlayerSwatch(this.color, {super.key, this.size = 12});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(3),
      boxShadow: [BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 6)],
    ),
  );
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  const _Pill(this.text, this.color);

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(left: 6),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: color.withValues(alpha: 0.7)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(text, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
  );
}

class AlliancePanel extends StatelessWidget {
  final GameController c;
  final VoidCallback onClose;
  const AlliancePanel({super.key, required this.c, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final me = c.me;
    // Groups of players still in the game: mine first, then in player
    // order. A stable order, so buttons never move under the pointer.
    final groups = <int, List<AlliancePlayer>>{};
    for (final a in c.alliance) {
      if (a.playing && a.active) groups.putIfAbsent(a.group, () => []).add(a);
    }
    final order = groups.keys.toList()
      ..sort((x, y) {
        if (me != null && x == me.group) return -1;
        if (me != null && y == me.group) return 1;
        return groups[x]!.first.slot.compareTo(groups[y]!.first.slot);
      });
    final out = [for (final a in c.alliance) if (a.playing && !a.active) a];

    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Container(
          width: 440,
          decoration: const BoxDecoration(
            color: _panel,
            border: Border(left: BorderSide(color: _line)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
                child: Row(
                  children: [
                    const Icon(Icons.handshake_outlined, color: _allyColor, size: 22),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text('Alliances', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white)),
                    ),
                    IconButton(tooltip: 'Close (F9)', onPressed: onClose, icon: const Icon(Icons.close, color: _dim, size: 20)),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 0, 18, 10),
                child: Text(
                  'Allies share one treasury, their technology and their points, and each can command the others\' units.',
                  style: TextStyle(fontSize: 12, color: _dim, height: 1.35),
                ),
              ),
              _openSwitch(),
              const Divider(height: 1, color: _line),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                  children: [
                    _Scoreboard(c: c),
                    const SizedBox(height: 14),
                    for (final g in order) _GroupCard(c: c, members: groups[g]!, mine: me != null && g == me.group, otherGroups: groups),
                    if (out.isNotEmpty) ...[
                      _heading('Out of the game'),
                      for (final a in out)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                          child: Row(
                            children: [
                              PlayerSwatch(c.colorOf(a.slot).withValues(alpha: 0.4)),
                              const SizedBox(width: 10),
                              Expanded(child: Text(c.nameOf(a.slot), style: const TextStyle(color: _faint, decoration: TextDecoration.lineThrough))),
                              Text(formatPoints(a.score), style: const TextStyle(color: _faint, fontFeatures: [FontFeature.tabularFigures()])),
                            ],
                          ),
                        ),
                    ],
                    if (c.allianceFeed.isNotEmpty) ...[
                      _heading('History'),
                      for (final n in c.allianceFeed.take(12))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 40,
                                child: Text(_gameTime(n.frame), style: const TextStyle(fontSize: 11, color: _faint, fontFeatures: [FontFeature.tabularFigures()])),
                              ),
                              Expanded(child: Text(n.text, style: TextStyle(fontSize: 12, color: n.aboutMe ? _text : _dim))),
                            ],
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
    child: Text(text.toUpperCase(), style: const TextStyle(fontSize: 11, letterSpacing: 1.2, color: _dim, fontWeight: FontWeight.w600)),
  );

  Widget _openSwitch() {
    final open = c.me?.open ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(open ? 'Open to alliances' : 'Not looking for alliances', style: const TextStyle(color: _text, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  open ? 'Others may invite you, and are more willing to accept.' : 'Switch on to let others know you are open to an alliance.',
                  style: const TextStyle(fontSize: 11, color: _faint),
                ),
              ],
            ),
          ),
          Switch(
            value: open,
            onChanged: c.setOpenToAlliances,
            thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.black : const Color(0xFF8C8C8C)),
            trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? _allyColor : const Color(0xFF1E1E1E)),
            trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? _allyColor : const Color(0xFF444444)),
          ),
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  final GameController c;
  final List<AlliancePlayer> members;
  final bool mine;
  final Map<int, List<AlliancePlayer>> otherGroups;
  const _GroupCard({required this.c, required this.members, required this.mine, required this.otherGroups});

  @override
  Widget build(BuildContext context) {
    final alliance = members.length > 1;
    final accent = c.colorOf(members.first.slot);
    final title = mine
        ? (alliance ? 'Your alliance' : 'You, on your own')
        : (alliance ? 'Alliance of ${members.length}' : c.nameOf(members.first.slot));
    // You first, then the others in player order.
    final sorted = [...members]..sort((a, b) {
      if (a.slot == c.myPlayer) return -1;
      if (b.slot == c.myPlayer) return 1;
      return a.slot.compareTo(b.slot);
    });

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: mine ? const Color(0xFF3A3A3A) : _line),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 4,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [for (final m in members) c.colorOf(m.slot)] + (members.length == 1 ? [accent] : []),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: mine ? Colors.white : _text),
                          ),
                        ),
                        if (!mine) Text(alliance ? 'enemy alliance' : 'enemy', style: const TextStyle(fontSize: 11, color: _danger)),
                      ],
                    ),
                    if (mine && alliance) _treasury(),
                    const SizedBox(height: 6),
                    for (final m in sorted) _member(m),
                    ..._actions(context),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _treasury() {
    Widget res(ui.Image? icon, Color color, int value) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: 14, height: 14, child: icon == null ? null : RawImage(image: icon, filterQuality: FilterQuality.medium)),
        const SizedBox(width: 4),
        Text('$value', style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12, fontFeatures: const [FontFeature.tabularFigures()])),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          const Text('Shared treasury', style: TextStyle(fontSize: 11, color: _dim)),
          const SizedBox(width: 10),
          res(c.icons?.resource(0), _mineral, c.minerals),
          const SizedBox(width: 12),
          res(c.icons?.resource(1 + c.myRace), _gasColor, c.gas),
        ],
      ),
    );
  }

  Widget _member(AlliancePlayer m) {
    final isMe = m.slot == c.myPlayer;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          PlayerSwatch(c.colorOf(m.slot)),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              c.nameOf(m.slot),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: isMe ? Colors.white : _text, fontWeight: isMe ? FontWeight.w700 : FontWeight.w500),
            ),
          ),
          const SizedBox(width: 6),
          Text(raceName(m.race), style: const TextStyle(fontSize: 11, color: _faint)),
          if (m.open && !isMe) const _Pill('open', Color(0xFF7CD992)),
          if (!isMe && c.me != null && c.me!.invitedBySlot(m.slot)) const _Pill('invited you', _allyColor),
          const Spacer(),
          Tooltip(
            message: scoreBreakdown(m, allied: members.length > 1),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.emoji_events_outlined, size: 14, color: _gold),
                const SizedBox(width: 4),
                Text(
                  formatPoints(m.score),
                  style: const TextStyle(color: _text, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _actions(BuildContext context) {
    if (mine) {
      if (!(c.me?.active ?? false)) return const [];
      if (members.length < 2) return const [];
      return [
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: _danger,
              side: const BorderSide(color: Color(0x66FF6B5E)),
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () => _confirmLeave(context),
            icon: const Icon(Icons.logout, size: 16),
            label: const Text('Leave alliance'),
          ),
        ),
      ];
    }
    final me = c.me;
    if (me == null || !me.active) return const [];
    final inviter = members.where((m) => me.invitedBySlot(m.slot)).firstOrNull;
    final sent = members.any((m) => c.invitedByMe(m.slot));
    // Someone must be left to fight: not my group, not this one.
    final allowed = c.alliance.any((a) => a.active && a.group != me.group && a.group != members.first.group);
    final Widget action;
    if (inviter != null) {
      action = Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(onPressed: () => c.answerInvitation(inviter.slot, false), child: const Text('Decline')),
          const SizedBox(width: 6),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _allyColor, foregroundColor: Colors.black, visualDensity: VisualDensity.compact),
            onPressed: () => c.answerInvitation(inviter.slot, true),
            icon: const Icon(Icons.handshake, size: 16),
            label: const Text('Accept'),
          ),
        ],
      );
    } else if (sent) {
      action = const Align(
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: _dim)),
            SizedBox(width: 8),
            Text('Invitation sent, waiting for an answer', style: TextStyle(fontSize: 12, color: _dim)),
          ],
        ),
      );
    } else {
      action = Align(
        alignment: Alignment.centerRight,
        child: Tooltip(
          message: allowed ? 'Ask to join forces' : "An alliance can't include every player still in the game.",
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: allowed ? () => c.inviteToAlliance(members.first.slot) : null,
            icon: const Icon(Icons.handshake_outlined, size: 16),
            label: Text(members.length > 1 ? 'Invite to join' : 'Invite'),
          ),
        ),
      );
    }
    return [const SizedBox(height: 8), action];
  }

  Future<void> _confirmLeave(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave the alliance?'),
        content: const SizedBox(
          width: 380,
          child: Text(
            'You take an equal share of the treasury and keep the technology you have. '
            'Your former allies become enemies, and you can no longer command their units.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stay')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _danger, foregroundColor: Colors.black),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (ok == true) c.leaveAlliance();
  }
}

/// Invitations waiting for an answer, shown over the game until answered.
class InvitationCards extends StatelessWidget {
  final GameController c;
  const InvitationCards({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final from = c.invitationsForMe.take(2).toList();
    if (from.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [for (final s in from) _card(s)],
    );
  }

  Widget _card(int slot) {
    final color = c.colorOf(slot);
    final allies = c.alliance.where((a) => a.active && a.slot != slot && a.group == c.alliance[slot].group).map((a) => c.nameOf(a.slot)).toList();
    return Container(
      width: 460,
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        color: const Color(0xF20A0A0A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _allyColor.withValues(alpha: 0.55)),
        boxShadow: [BoxShadow(color: _allyColor.withValues(alpha: 0.12), blurRadius: 24, spreadRadius: 2)],
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.handshake_outlined, color: _allyColor, size: 22),
              const SizedBox(width: 10),
              PlayerSwatch(color),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: c.nameOf(slot), style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
                    TextSpan(text: ' (${raceName(c.alliance[slot].race)})', style: const TextStyle(color: _dim)),
                    TextSpan(text: allies.isEmpty ? ' invites you to an alliance' : ' invites you to join their alliance with ${allies.join(' and ')}'),
                  ]),
                  style: const TextStyle(color: _text, fontSize: 14),
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.only(left: 32, top: 4),
            child: Text(
              'One treasury, shared technology and points, and you can command each other\'s units.',
              style: TextStyle(fontSize: 12, color: _dim),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => c.answerInvitation(slot, false), child: const Text('Decline')),
              const SizedBox(width: 6),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: _allyColor, foregroundColor: Colors.black),
                onPressed: () => c.answerInvitation(slot, true),
                icon: const Icon(Icons.handshake, size: 18),
                label: const Text('Accept'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Every player's score, best first: what they mined (shared with allies),
/// built and destroyed.
class _Scoreboard extends StatelessWidget {
  final GameController c;
  const _Scoreboard({required this.c});

  static const _num = TextStyle(fontSize: 12, color: _text, fontFeatures: [FontFeature.tabularFigures()]);
  static const _head = TextStyle(fontSize: 10, color: _faint, letterSpacing: 0.8, fontWeight: FontWeight.w600);

  @override
  Widget build(BuildContext context) {
    final rows = [for (final a in c.alliance) if (a.playing) a]..sort((x, y) => y.score.compareTo(x.score));
    if (rows.isEmpty) return const SizedBox.shrink();
    final best = rows.first.score <= 0 ? 1 : rows.first.score;
    Widget cell(String text, {TextStyle style = _num, double width = 58}) =>
        SizedBox(width: width, child: Text(text, textAlign: TextAlign.right, style: style));
    return Container(
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(8), border: Border.all(color: _line)),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.emoji_events_outlined, size: 16, color: _gold),
              const SizedBox(width: 6),
              const Expanded(child: Text('Score', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.white))),
              cell('MINED', style: _head),
              cell('BUILT', style: _head),
              cell('DESTROYED', style: _head, width: 70),
              cell('TOTAL', style: _head),
            ],
          ),
          const SizedBox(height: 6),
          for (final a in rows)
            Tooltip(
              message: scoreBreakdown(a, allied: c.alliance.where((o) => o.active && o.group == a.group).length > 1),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Column(
                  children: [
                    Row(
                      children: [
                        PlayerSwatch(c.colorOf(a.slot).withValues(alpha: a.active ? 1 : 0.35), size: 10),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            c.nameOf(a.slot),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: !a.active ? _faint : a.slot == c.myPlayer ? Colors.white : _text,
                              fontWeight: a.slot == c.myPlayer ? FontWeight.w700 : FontWeight.w500,
                              decoration: a.active ? null : TextDecoration.lineThrough,
                            ),
                          ),
                        ),
                        cell(compactPoints(a.points)),
                        cell(compactPoints(a.productionScore)),
                        cell(compactPoints(a.killScore), width: 70),
                        cell(compactPoints(a.score), style: _num.copyWith(fontWeight: FontWeight.w700, color: _gold)),
                      ],
                    ),
                    const SizedBox(height: 3),
                    // Share of the leader's score.
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: (a.score / best).clamp(0.0, 1.0),
                        minHeight: 2,
                        backgroundColor: const Color(0xFF161616),
                        color: c.colorOf(a.slot).withValues(alpha: a.active ? 0.8 : 0.3),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
