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

const _fight = Color(0xFFFF4D3D);
const _vassalColor = Color(0xFFFFA24D);

/// The players a group is clashing with right now (outside the group).
Set<int> _clashes(GameController c, List<AlliancePlayer> members) {
  final ids = {for (final m in members) m.slot};
  final out = <int>{};
  for (final m in members) {
    for (int s = 0; s < 8; ++s) {
      if (m.fightingSlot(s) && !ids.contains(s)) out.add(s);
    }
  }
  return out;
}

/// Rank by total score among everyone who played (1 = best).
Map<int, int> _ranks(GameController c) {
  final players = [for (final a in c.alliance) if (a.playing) a]..sort((x, y) => y.score.compareTo(x.score));
  return {for (int i = 0; i < players.length; ++i) players[i].slot: i + 1};
}

/// The alliance panel (F9): one compact card per side of the game, wars on
/// top in red. Details (score breakdown, per-player stats) are in tooltips.
class AlliancePanel extends StatelessWidget {
  final GameController c;
  final VoidCallback onClose;
  final bool dockedLeft;
  final VoidCallback onToggleSide;
  // Blurring what's behind costs a full-screen pass every frame: too much
  // for a phone's GPU.
  final bool blur;
  const AlliancePanel({super.key, required this.c, required this.onClose, this.dockedLeft = false, required this.onToggleSide, this.blur = true});

  @override
  Widget build(BuildContext context) {
    final me = c.me;
    final groups = <int, List<AlliancePlayer>>{};
    for (final a in c.alliance) {
      if (a.playing && a.active) groups.putIfAbsent(a.group, () => []).add(a);
    }
    final fighting = {for (final g in groups.keys) g: _clashes(c, groups[g]!).isNotEmpty};
    final order = groups.keys.toList()
      ..sort((x, y) {
        if (fighting[x]! != fighting[y]!) return fighting[x]! ? -1 : 1;
        if (me != null && x == me.group) return -1;
        if (me != null && y == me.group) return 1;
        return groups[x]!.first.slot.compareTo(groups[y]!.first.slot);
      });
    final out = [for (final a in c.alliance) if (a.playing && !a.active) a];
    final ranks = _ranks(c);

    return ClipRect(
      child: BackdropFilter(
        enabled: blur,
        filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Container(
          width: 440,
          decoration: BoxDecoration(
            color: _panel,
            border: dockedLeft ? const Border(right: BorderSide(color: _line)) : const Border(left: BorderSide(color: _line)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              if (me != null && me.isVassal) _vassalBanner(me.lord),
              const Divider(height: 1, color: _line),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                  children: [
                    for (final g in order) _GroupCard(c: c, members: groups[g]!, mine: me != null && g == me.group, ranks: ranks),
                    if (out.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                        child: Text(
                          'Out of the game: ${out.map((a) => c.nameOf(a.slot)).join(', ')}',
                          style: const TextStyle(fontSize: 12, color: _faint),
                        ),
                      ),
                    if (c.allianceFeed.isNotEmpty) _history(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final me = c.me;
    final open = me?.open ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
      child: Row(
        children: [
          const Icon(Icons.handshake_outlined, color: _allyColor, size: 20),
          const SizedBox(width: 8),
          const Text('Alliances', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
          const SizedBox(width: 4),
          const Tooltip(
            message: 'Allies share one treasury, their technology and their mining points, and each can command the others\' units.\n'
                'A player who surrenders becomes a permanent ally and pays half its points to its conqueror.\n'
                'Sides at war are listed first, in red.',
            child: Icon(Icons.info_outline, size: 16, color: _faint),
          ),
          const Spacer(),
          if (me != null && !me.isVassal)
            Tooltip(
              message: open ? 'Others may invite you, and accept more readily. Click to stop.' : 'Click to let others know you are open to alliances.',
              child: FilterChip(
                label: Text(open ? 'Open' : 'Closed'),
                selected: open,
                showCheckmark: true,
                checkmarkColor: Colors.black,
                selectedColor: _allyColor,
                labelStyle: TextStyle(fontSize: 12, color: open ? Colors.black : _dim, fontWeight: FontWeight.w600),
                visualDensity: VisualDensity.compact,
                onSelected: c.setOpenToAlliances,
              ),
            ),
          IconButton(
            tooltip: dockedLeft ? 'Move to the right side' : 'Move to the left side',
            onPressed: onToggleSide,
            icon: Icon(dockedLeft ? Icons.keyboard_double_arrow_right : Icons.keyboard_double_arrow_left, color: _dim, size: 20),
          ),
          IconButton(tooltip: 'Close (F9)', onPressed: onClose, icon: const Icon(Icons.close, color: _dim, size: 20)),
        ],
      ),
    );
  }

  Widget _vassalBanner(int lord) => Container(
    margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(color: const Color(0x1AFFA24D), borderRadius: BorderRadius.circular(6), border: Border.all(color: const Color(0x66FFA24D))),
    child: Row(
      children: [
        const Icon(Icons.flag, color: _vassalColor, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text('You serve ${c.nameOf(lord)}: permanent ally, half your points go to them.', style: const TextStyle(fontSize: 12, color: _text)),
        ),
      ],
    ),
  );

  Widget _history() => Theme(
    data: ThemeData.dark().copyWith(dividerColor: Colors.transparent),
    child: ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 4),
      childrenPadding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      title: Text('History (${c.allianceFeed.length})', style: const TextStyle(fontSize: 12, color: _dim, fontWeight: FontWeight.w600)),
      children: [
        for (final n in c.allianceFeed.take(10))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 38, child: Text(_gameTime(n.frame), style: const TextStyle(fontSize: 11, color: _faint, fontFeatures: [FontFeature.tabularFigures()]))),
                Expanded(child: Text(n.text, style: TextStyle(fontSize: 12, color: n.aboutMe ? _text : _dim))),
              ],
            ),
          ),
      ],
    ),
  );
}

class _GroupCard extends StatelessWidget {
  final GameController c;
  final List<AlliancePlayer> members;
  final bool mine;
  final Map<int, int> ranks;
  const _GroupCard({required this.c, required this.members, required this.mine, required this.ranks});

  bool get _ally => members.any((m) => m.slot != c.myPlayer) && mine;

  @override
  Widget build(BuildContext context) {
    final alliance = members.length > 1;
    final first = members.first;
    final clashes = _clashes(c, members);
    final atWar = clashes.isNotEmpty;
    final sorted = [...members]..sort((a, b) {
      if (a.slot == c.myPlayer) return -1;
      if (b.slot == c.myPlayer) return 1;
      return a.slot.compareTo(b.slot);
    });
    final title = alliance ? c.allianceNameOf(first.slot) : c.nameOf(first.slot);
    final tag = mine ? (_ally ? 'YOUR ALLIANCE' : 'YOU') : 'ENEMY';
    final tagColor = mine ? _allyColor : _danger;
    final actions = _actions(context, clashes);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: atWar ? const Color(0xFF150808) : _card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: atWar ? _fight : (mine ? const Color(0xFF3A3A3A) : _line), width: atWar ? 1.5 : 1),
        boxShadow: atWar ? [BoxShadow(color: _fight.withValues(alpha: 0.22), blurRadius: 12)] : null,
      ),
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Name, side and (alone) rank and score.
          Row(
            children: [
              if (!alliance) ...[PlayerSwatch(c.colorOf(first.slot)), const SizedBox(width: 8)],
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: mine ? Colors.white : _text),
                      ),
                    ),
                    if (alliance || !mine) ...[
                      const SizedBox(width: 8),
                      Text(tag, style: TextStyle(fontSize: 9.5, letterSpacing: 1, fontWeight: FontWeight.w700, color: tagColor)),
                    ],
                  ],
                ),
              ),
              if (!alliance) _score(first),
            ],
          ),
          const SizedBox(height: 4),
          // Stats, with a single action (e.g. Invite) on the same line.
          Row(
            children: [
              Expanded(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: _power())),
              if (actions.length == 1) actions.single,
            ],
          ),
          if (atWar)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Row(
                children: [
                  const Icon(Icons.local_fire_department, size: 14, color: _fight),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Fighting ${clashes.map((s) => s == c.myPlayer ? 'you' : c.nameOf(s)).join(', ')}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: _fight, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          if (alliance) ...[
            const SizedBox(height: 6),
            for (final m in sorted) _member(m),
          ],
          if (_ally) ...[_shareSwitch(), _defensiveSwitch()],
          if (actions.length > 1) ...[const SizedBox(height: 4), Row(mainAxisAlignment: MainAxisAlignment.end, children: actions)],
        ],
      ),
    );
  }

  // Off by default: allies can't spend your money until you say so.
  Widget _shareSwitch() => _switchRow(
    icon: Icons.savings_outlined,
    title: 'Share resources',
    on: c.sharingResources,
    onText: 'One treasury with allies who share: they spend it too.',
    offText: 'Your minerals and gas are yours alone.',
    onChanged: c.setShareResources,
  );

  // Your computer allies stop attacking, fortify and guard each other.
  Widget _defensiveSwitch() => _switchRow(
    icon: Icons.shield_outlined,
    title: 'Defensive mode',
    on: c.defensiveMode,
    onText: 'Computer allies build ground and air defences, help each other against attacks and never attack enemy bases.',
    offText: 'Computer allies attack enemy bases when ready.',
    onChanged: c.setDefensiveMode,
  );

  Widget _switchRow({
    required IconData icon,
    required String title,
    required bool on,
    required String onText,
    required String offText,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: on ? _allyColor.withValues(alpha: 0.08) : null,
        border: Border.all(color: on ? _allyColor.withValues(alpha: 0.5) : _line),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: on ? _allyColor : _dim),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: on ? Colors.white : _text)),
                Text(on ? onText : offText, style: const TextStyle(fontSize: 11, color: _dim)),
              ],
            ),
          ),
          Switch(value: on, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _score(AlliancePlayer m) => Tooltip(
    message: scoreBreakdown(m, allied: members.length > 1),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('#${ranks[m.slot] ?? '-'}', style: const TextStyle(fontSize: 11, color: _faint, fontWeight: FontWeight.w700)),
        const SizedBox(width: 6),
        const Icon(Icons.emoji_events_outlined, size: 13, color: _gold),
        const SizedBox(width: 3),
        Text(formatPoints(m.score), style: const TextStyle(color: _text, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
      ],
    ),
  );

  // One line: army, minerals and gas per minute (the whole alliance's).
  Widget _power() {
    int army = 0, minerals = 0, gas = 0, workers = 0;
    for (final m in members) {
      army += m.armyValue;
      minerals += m.mineralRate;
      gas += m.gasRate;
      workers += m.workers;
    }
    Widget icon(int i) {
      final img = c.icons?.resource(i);
      return SizedBox(width: 12, height: 12, child: img == null ? null : RawImage(image: img, filterQuality: FilterQuality.medium));
    }

    const style = TextStyle(fontSize: 11.5, color: _dim, fontFeatures: [FontFeature.tabularFigures()]);
    return Tooltip(
      message: '${members.length > 1 ? 'Together: ' : ''}army worth ${formatPoints(army)} (what its combat units cost), $workers workers, '
          'mining ${formatPoints(minerals)} minerals and ${formatPoints(gas)} gas per minute',
      child: Row(
        children: [
          const Icon(Icons.shield_outlined, size: 13, color: Color(0xFFFF8A65)),
          const SizedBox(width: 3),
          Text('${compactPoints(army)} army', style: style),
          const SizedBox(width: 12),
          icon(0),
          const SizedBox(width: 3),
          Text('${compactPoints(minerals)}/min', style: style.copyWith(color: _mineral)),
          const SizedBox(width: 10),
          icon(1 + c.myRace),
          const SizedBox(width: 3),
          Text('${compactPoints(gas)}/min', style: style.copyWith(color: _gasColor)),
        ],
      ),
    );
  }

  Widget _member(AlliancePlayer m) {
    final isMe = m.slot == c.myPlayer;
    final offers = c.me?.offersSurrender(m.slot) ?? false;
    final invited = c.me?.invitedBySlot(m.slot) ?? false;
    return Tooltip(
      message: '${c.nameOf(m.slot)} (${raceName(m.race)}): army ${formatPoints(m.armyValue)}, ${m.workers} workers, '
          '${formatPoints(m.mineralRate)} minerals and ${formatPoints(m.gasRate)} gas per minute'
          '${m.isVassal ? '\nSurrendered to ${m.lord == c.myPlayer ? 'you' : c.nameOf(m.lord)}' : ''}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            PlayerSwatch(c.colorOf(m.slot), size: 10),
            const SizedBox(width: 8),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      c.nameOf(m.slot),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: isMe ? Colors.white : _text, fontWeight: isMe ? FontWeight.w700 : FontWeight.w500),
                    ),
                  ),
                  if (m.slot < c.shares.length && c.shares[m.slot]) ...[
                    const SizedBox(width: 6),
                    const Tooltip(message: 'Shares resources', child: Icon(Icons.savings_outlined, size: 13, color: _dim)),
                  ],
                  if (m.isVassal) ...[const SizedBox(width: 6), const Icon(Icons.flag, size: 13, color: _vassalColor)],
                  if (offers || invited) ...[const SizedBox(width: 6), Icon(offers ? Icons.flag_outlined : Icons.mail_outline, size: 13, color: _allyColor)],
                ],
              ),
            ),
            // You can put an ally out of your alliance (not one who
            // surrendered: that is for good).
            if (mine && !isMe && !m.isVassal && !(c.me?.isVassal ?? true))
              Builder(
                builder: (context) => IconButton(
                  tooltip: 'Put ${c.nameOf(m.slot)} out of the alliance',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  color: _danger,
                  onPressed: () => _confirmKick(context, m.slot),
                  icon: const Icon(Icons.person_remove_outlined),
                ),
              ),
            _score(m),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmKick(BuildContext context, int slot) async {
    final name = c.nameOf(slot);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Put $name out of the alliance?'),
        content: Text('$name leaves with any players who surrendered to them, takes its share of a shared treasury, and becomes an enemy.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Put out')),
        ],
      ),
    );
    if (ok == true) c.kickFromAlliance(slot);
  }

  Widget _small(String label, VoidCallback onPressed, {IconData? icon, Color? color, bool filled = false}) {
    final style = (filled ? FilledButton.styleFrom(backgroundColor: color, foregroundColor: Colors.black) : TextButton.styleFrom(foregroundColor: color))
        .copyWith(visualDensity: VisualDensity.compact, padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)));
    final child = icon == null
        ? Text(label)
        : Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 15), const SizedBox(width: 5), Text(label)]);
    return filled ? FilledButton(style: style, onPressed: onPressed, child: child) : TextButton(style: style, onPressed: onPressed, child: child);
  }

  List<Widget> _actions(BuildContext context, Set<int> clashes) {
    final me = c.me;
    if (me == null || !me.active || me.isVassal) return const [];
    final widgets = <Widget>[];
    if (mine) {
      // Leaving needs someone to leave: a free member who isn't my vassal.
      if (members.any((m) => m.slot != c.myPlayer && m.lord != c.myPlayer)) {
        widgets.add(_small('Leave', () => _confirmLeave(context), icon: Icons.logout, color: _danger));
      }
    } else {
      final lead = members.firstWhere((m) => !m.isVassal, orElse: () => members.first);
      final surrendering = members.where((m) => me.offersSurrender(m.slot)).firstOrNull;
      final inviter = members.where((m) => me.invitedBySlot(m.slot)).firstOrNull;
      final sent = members.any((m) => c.invitedByMe(m.slot));
      // Someone must stay outside, and the joined alliance holds at most
      // three members (players who surrendered don't count).
      int sizeOf(int group) => c.alliance.where((a) => a.playing && a.active && a.group == group && !a.isVassal).length;
      final allowed =
          c.alliance.any((a) => a.active && a.group != me.group && a.group != first.group) &&
          sizeOf(me.group) + sizeOf(first.group) <= GameSetup.maxAllianceSize;
      if (surrendering != null) {
        widgets.add(_small('Refuse', () => c.answerSurrender(surrendering.slot, false), color: _dim));
        widgets.add(_small('Accept surrender', () => c.answerSurrender(surrendering.slot, true), icon: Icons.flag, color: _vassalColor, filled: true));
      } else if (inviter != null) {
        widgets.add(_small('Decline', () => c.answerInvitation(inviter.slot, false), color: _dim));
        widgets.add(_small('Accept alliance', () => c.answerInvitation(inviter.slot, true), icon: Icons.handshake, color: _allyColor, filled: true));
      } else {
        if (clashes.contains(c.myPlayer) && c.canSurrenderTo(lead.slot)) {
          widgets.add(_small('Surrender', () => _confirmSurrender(context, lead.slot), icon: Icons.flag_outlined, color: _vassalColor));
        }
        if (sent) {
          widgets.add(const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Text('Invitation sent', style: TextStyle(fontSize: 12, color: _dim)),
          ));
        } else if (allowed) {
          widgets.add(_small('Invite', () => c.inviteToAlliance(lead.slot), icon: Icons.handshake_outlined, color: _text));
        }
      }
    }
    return widgets;
  }

  AlliancePlayer get first => members.first;

  Future<void> _confirmSurrender(BuildContext context, int to) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Surrender to ${c.nameOf(to)}?'),
        content: const SizedBox(
          width: 400,
          child: Text(
            'If they accept, you become their permanent ally: the fighting stops, you keep playing at their side, '
            'but you can no longer leave or join other alliances, and half of your points go to them.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep fighting')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _vassalColor, foregroundColor: Colors.black),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Offer surrender'),
          ),
        ],
      ),
    );
    if (ok == true) c.offerSurrender(to);
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
    final surrenders = c.surrendersForMe.take(2).toList();
    final from = c.invitationsForMe.take(2 - surrenders.length).toList();
    if (from.isEmpty && surrenders.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [for (final s in surrenders) _surrenderCard(s), for (final s in from) _card(s)],
    );
  }

  Widget _surrenderCard(int slot) {
    final a = c.alliance[slot];
    return Container(
      width: 460,
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        color: const Color(0xF20A0A0A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _vassalColor.withValues(alpha: 0.6)),
        boxShadow: [BoxShadow(color: _vassalColor.withValues(alpha: 0.12), blurRadius: 24, spreadRadius: 2)],
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.flag_outlined, color: _vassalColor, size: 22),
              const SizedBox(width: 10),
              PlayerSwatch(c.colorOf(slot)),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: c.nameOf(slot), style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
                    TextSpan(text: ' (${raceName(a.race)})', style: const TextStyle(color: _dim)),
                    const TextSpan(text: ' offers to surrender to you'),
                  ]),
                  style: const TextStyle(color: _text, fontSize: 14),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 32, top: 4),
            child: Text(
              'They become your permanent ally and pay you half of their points. '
              'Army ${formatPoints(a.armyValue)}, mining ${formatPoints(a.mineralRate + a.gasRate)} per minute.',
              style: const TextStyle(fontSize: 12, color: _dim),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => c.answerSurrender(slot, false), child: const Text('Refuse')),
              const SizedBox(width: 6),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: _vassalColor, foregroundColor: Colors.black),
                onPressed: () => c.answerSurrender(slot, true),
                icon: const Icon(Icons.flag, size: 18),
                label: const Text('Accept surrender'),
              ),
            ],
          ),
        ],
      ),
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

