// lib/ui/hud.dart
//
// Top resource bar, selection panel and command card. All rebuild from
// GameController.hud (throttled), never per simulation frame.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'dart:ui' as ui;

import '../engine/models.dart';
import '../game/command_cards.dart';
import '../game/game_controller.dart';
import '../rendering/icon_atlas.dart';
import 'alliance_panel.dart';
import 'autoplay_panel.dart';

const _panelColor = Color(0xFF000000);
const _borderColor = Color(0xFF2A2A2A);
const _mineralColor = Color(0xFF6FD3FF);
const _gasColor = Color(0xFF4CE07A);
const _textColor = Color(0xFFE8E8E8);
const _dimText = Color(0xFF8C8C8C);

class TopBar extends StatelessWidget {
  final GameController c;
  final bool fullscreen;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onVolume;
  final ValueChanged<double> onVolumeDone;
  final VoidCallback onMenu;
  final VoidCallback onAlliances;
  final bool alliancesOpen;
  final VoidCallback onAutoplay;
  final bool autoplayOpen;
  final bool compact; // phone: thin, over the map, touch wording
  const TopBar({
    super.key,
    required this.c,
    this.compact = false,
    required this.onMenu,
    required this.onAlliances,
    required this.alliancesOpen,
    required this.onAutoplay,
    required this.autoplayOpen,
    required this.fullscreen,
    required this.onToggleFullscreen,
    required this.onToggleMute,
    required this.onVolume,
    required this.onVolumeDone,
  });

  static IconData _volumeIcon(GameController c) {
    final sound = c.sound;
    if (sound == null || sound.muted) return Icons.volume_off;
    if (sound.volume < 0.4) return Icons.volume_down;
    return Icons.volume_up;
  }

  @override
  Widget build(BuildContext context) {
    final seconds = (c.frame * GameController.frameMicros) ~/ 1000000;
    final time = '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final supplyFull = c.supplyUsed >= c.supplyMax;
    final hint = hintText(c, compact);
    final gap = compact ? 12.0 : 20.0;
    return Container(
      height: compact ? 32 : 34,
      padding: const EdgeInsets.only(left: 2, right: 12),
      decoration: BoxDecoration(
        color: compact ? const Color(0xCC000000) : _panelColor,
        border: const Border(bottom: BorderSide(color: _borderColor)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Menu (F10)',
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            color: _textColor,
            onPressed: onMenu,
            icon: const Icon(Icons.menu),
          ),
          const SizedBox(width: 6),
          // The original's own icons (game\icons.grp): minerals, then the
          // race's gas and supply icons.
          _resource(c.icons?.resource(0), _mineralColor, '${c.minerals}', 'Minerals'),
          SizedBox(width: gap),
          _resource(c.icons?.resource(1 + c.myRace), _gasColor, '${c.gas}', 'Vespene gas'),
          SizedBox(width: gap),
          _resource(
            c.icons?.resource(4 + c.myRace),
            supplyFull ? const Color(0xFFFF6B5E) : _textColor,
            '${c.supplyUsed.toStringAsFixed(0)}/${c.supplyMax.toStringAsFixed(0)}',
            const ['Control (Overlords)', 'Supplies (Supply Depots)', 'Psi (Pylons)'][c.myRace.clamp(0, 2)],
          ),
          SizedBox(width: gap),
          Text(
            time,
            style: const TextStyle(color: _dimText, fontFeatures: [FontFeature.tabularFigures()]),
          ),
          SizedBox(width: gap),
          Tooltip(
            message: scoreBreakdown(c.me, allied: c.myAllies.isNotEmpty),
            child: Row(
              children: [
                const Icon(Icons.emoji_events_outlined, size: 17, color: Color(0xFFFFD54F)),
                const SizedBox(width: 5),
                Text(
                  formatPoints(c.score),
                  style: const TextStyle(color: Color(0xFFFFD54F), fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]),
                ),
              ],
            ),
          ),
          SizedBox(width: compact ? 12 : 24),
          Expanded(
            // On a phone the hint has no room here: HintToast shows it.
            child: compact
                ? const SizedBox()
                : Text(
                    c.message ?? hint ?? '',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.message != null ? const Color(0xFFFFD54F) : _textColor),
                  ),
          ),
          AutoplayButton(c: c, open: autoplayOpen, onPressed: onAutoplay, compact: compact),
          const SizedBox(width: 6),
          _AllianceButton(c: c, open: alliancesOpen, onPressed: onAlliances, compact: compact),
          const SizedBox(width: 6),
          IconButton(
            tooltip: (c.sound?.muted ?? false) ? 'Unmute' : 'Mute',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            color: _textColor,
            onPressed: onToggleMute,
            icon: Icon(_volumeIcon(c)),
          ),
          if (!compact)
            SizedBox(
              width: 120,
              child: Tooltip(
                message: 'Volume ${((c.sound?.volume ?? 0) * 100).round()}%',
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: (c.sound?.muted ?? false) ? _dimText : _textColor,
                    inactiveTrackColor: const Color(0xFF2A2A2A),
                    thumbColor: (c.sound?.muted ?? false) ? _dimText : _textColor,
                  ),
                  child: Slider(value: c.sound?.volume ?? 0, onChanged: c.sound == null ? null : onVolume, onChangeEnd: onVolumeDone),
                ),
              ),
            ),
          if (!compact)
            IconButton(
              tooltip: fullscreen ? 'Exit fullscreen (F11)' : 'Fullscreen (F11)',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              color: _textColor,
              onPressed: onToggleFullscreen,
              icon: Icon(fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
            ),
        ],
      ),
    );
  }

  /// What the armed command expects, or null.
  static String? hintText(GameController c, bool compact) {
    final click = compact ? 'tap' : 'left click';
    final cancel = compact ? 'Cancel to stop' : 'right click or Esc to cancel';
    if (c.mode == CommandMode.build && c.buildTypeId != null) {
      return 'Place ${c.engine.unitType(c.buildTypeId!).shortName}: $click to build, $cancel';
    } else if (c.mode == CommandMode.cast && c.castAbility != null) {
      final t = c.castAbility!.tech >= 0 ? c.engine.techInfo(c.myPlayer, c.castAbility!.tech) : null;
      return '${t?.name ?? 'Ability'}: $click a target, $cancel';
    } else if (c.mode == CommandMode.rally) {
      return 'Set rally point: $click a spot or unit, $cancel';
    } else if (c.mode != CommandMode.none) {
      return '${c.mode.name[0].toUpperCase()}${c.mode.name.substring(1)}: $click a target, $cancel';
    }
    return null;
  }

  Widget _resource(ui.Image? icon, Color color, String value, String tooltip) => Tooltip(
    message: tooltip,
    child: Row(
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: icon == null ? null : RawImage(image: icon, filterQuality: FilterQuality.medium, fit: BoxFit.contain),
        ),
        const SizedBox(width: 6),
        Text(
          value,
          style: TextStyle(color: color, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ],
    ),
  );
}

/// Phones: messages and the armed command's hint, wrapped, under the top
/// bar. It never takes a touch meant for the map.
class HintToast extends StatelessWidget {
  final GameController c;
  const HintToast({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final text = c.message ?? TopBar.hintText(c, true);
    if (text == null || text.isEmpty) return const SizedBox();
    return IgnorePointer(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(6)),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: c.message != null ? const Color(0xFFFFD54F) : _textColor),
        ),
      ),
    );
  }
}

/// Opens the alliance panel; shows your allies' colors and a badge for
/// invitations waiting for an answer.
class _AllianceButton extends StatelessWidget {
  final GameController c;
  final bool open;
  final VoidCallback onPressed;
  final bool compact;
  const _AllianceButton({required this.c, required this.open, required this.onPressed, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final waiting = c.invitationsForMe.length + c.surrendersForMe.length;
    final allies = c.myAllies;
    return Tooltip(
      message: 'Alliances (F9)',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onPressed,
        child: Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: waiting > 0 ? const Color(0xFFFFE14D) : (open ? const Color(0xFF555555) : _borderColor)),
            color: open ? const Color(0xFF1A1A1A) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Badge(
                isLabelVisible: waiting > 0,
                backgroundColor: const Color(0xFFFFE14D),
                textColor: Colors.black,
                label: Text('$waiting'),
                child: Icon(Icons.handshake_outlined, size: 17, color: allies.isEmpty ? _textColor : const Color(0xFFFFE14D)),
              ),
              if (!compact) ...[
                const SizedBox(width: 6),
                Text(allies.isEmpty ? 'Alliances' : 'Allied', style: const TextStyle(color: _textColor, fontSize: 12)),
              ],
              for (final s in allies) ...[const SizedBox(width: 5), PlayerSwatch(c.colorOf(s), size: 9)],
            ],
          ),
        ),
      ),
    );
  }
}

class SelectionPanel extends StatelessWidget {
  final GameController c;
  final bool compact; // phone: a small card over the map, nothing when empty
  const SelectionPanel({super.key, required this.c, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final selected = c.selectedUnits;
    if (compact && selected.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.all(compact ? 6 : 10),
      decoration: BoxDecoration(
        color: compact ? const Color(0xCC000000) : _panelColor,
        border: Border.all(color: _borderColor),
        borderRadius: compact ? BorderRadius.circular(6) : null,
      ),
      child: selected.isEmpty
          ? const _Help()
          : selected.length == 1
          ? _single(selected.first)
          : _multiple(selected),
    );
  }

  Widget _single(UnitInfo u) {
    final t = c.engine.unitType(u.typeId);
    final player = c.playerAt(u.owner);
    final owner = switch (c.relation(u.owner)) {
      Relation.own => 'You',
      Relation.neutral => 'Neutral',
      Relation.ally => '${player?.name ?? 'Player ${u.owner + 1}'} (ally, under your command)',
      Relation.enemy => '${player?.name ?? 'Player ${u.owner + 1}'} (enemy)',
    };
    final lines = <Widget>[
      Row(
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
        children: [
          if (compact)
            Text(
              t.name,
              style: const TextStyle(color: _textColor, fontSize: 13, fontWeight: FontWeight.w600),
            )
          else
            Expanded(
              child: Text(
                t.name,
                style: const TextStyle(color: _textColor, fontSize: 16, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (compact) const SizedBox(width: 12),
          Flexible(
            child: Text(
              owner,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _dimText, fontSize: compact ? 11 : null),
            ),
          ),
        ],
      ),
      SizedBox(height: compact ? 4 : 8),
    ];
    if (u.isResource) {
      lines.add(Text('${u.typeId == 188 ? 'Vespene gas' : 'Minerals'}: ${u.resources}', style: TextStyle(color: u.typeId == 188 ? _gasColor : _mineralColor)));
    } else {
      lines.add(_statBar('HP', u.hp, u.maxHp, _hpColor(u.hp, u.maxHp)));
      if (u.maxShields > 0) lines.add(_statBar('Shields', u.shields, u.maxShields, const Color(0xFF4FA3FF)));
      if (u.maxEnergy > 0) lines.add(_statBar('Energy', u.energy, u.maxEnergy, const Color(0xFFB57BFF)));
    }
    if (u.isBusyResearching && u.researchProgressPermille >= 0 && c.canControl(u.owner)) {
      final tech = u.researchingTech >= 0 ? c.engine.techInfo(c.myPlayer, u.researchingTech) : null;
      final upgrade = u.upgrading >= 0 ? c.engine.upgradeInfo(c.myPlayer, u.upgrading) : null;
      final name = tech?.name ?? upgrade?.name ?? '';
      final icon = tech?.icon ?? upgrade?.icon ?? -1;
      lines.add(const SizedBox(height: 8));
      lines.add(
        Row(
          mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
          children: [
            _QueueSlot(
              c: c,
              icon: icon,
              progressPermille: u.researchProgressPermille,
              tooltip: '${tech != null ? 'Researching' : 'Upgrading'} $name (click to cancel)',
              onTap: c.cancelResearch,
            ),
            const SizedBox(width: 10),
            Text(
              '${tech != null ? 'Researching' : 'Upgrading'} $name  ${(u.researchProgressPermille / 10).round()}%',
              style: const TextStyle(color: _textColor, fontSize: 12),
            ),
          ],
        ),
      );
    }
    // What a transport or bunker carries: click one to let it out.
    if (c.canControl(u.owner) && (u.typeId == 11 || u.typeId == 69 || u.typeId == 42 || u.typeId == 125)) {
      final carried = c.carriedBy(u);
      if (carried.isNotEmpty) {
        lines.add(const SizedBox(height: 8));
        lines.add(Text('Carrying ${carried.length}  (click one to unload it)', style: const TextStyle(color: _dimText, fontSize: 11)));
        lines.add(const SizedBox(height: 4));
        lines.add(
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final w in carried)
                _QueueSlot(
                  c: c,
                  icon: w.typeId,
                  progressPermille: -1,
                  tooltip: '${c.engine.unitType(w.typeId).name}: unload',
                  onTap: () => c.unloadOne(w.unitId),
                ),
            ],
          ),
        );
      } else if (u.typeId != 125) {
        lines.add(const SizedBox(height: 8));
        lines.add(const Text('Empty. Right-click it with units selected to load them; D unloads at a spot you pick.', style: TextStyle(color: _dimText, fontSize: 11)));
      }
    }
    if (!u.isCompleted && u.progressPermille >= 0) {
      lines.add(const SizedBox(height: 6));
      lines.add(_progress('Under construction', u.progressPermille));
    } else if (u.queue.isNotEmpty && c.canControl(u.owner) && (u.isBuilding || u.typeId == 72 || u.typeId == 83 || u.typeId == 36)) {
      // The original's five production slots: what's being made (with its
      // progress) and what's waiting, each a unit icon; click one to cancel it.
      final first = c.engine.unitType(u.queue.first).shortName;
      lines.add(const SizedBox(height: 8));
      lines.add(
        Row(
          mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
          children: [
            for (int i = 0; i < 5; ++i)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: i < u.queue.length
                    ? _QueueSlot(
                        c: c,
                        icon: u.queue[i],
                        progressPermille: i == 0 ? (u.progressPermille < 0 ? 0 : u.progressPermille) : -1,
                        tooltip: '${c.engine.unitType(u.queue[i]).name}${i == 0 ? ' (in production)' : ' (queued)'}, click to cancel',
                        onTap: () => c.cancelQueueSlot(i),
                      )
                    : const _QueueSlot.empty(),
              ),
            const SizedBox(width: 4),
            Text('$first  ${((u.progressPermille < 0 ? 0 : u.progressPermille) / 10).round()}%', style: const TextStyle(color: _textColor, fontSize: 12)),
          ],
        ),
      );
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: lines);
  }

  Widget _multiple(List<UnitInfo> units) => SingleChildScrollView(
    child: Wrap(
      spacing: compact ? 4 : 6,
      runSpacing: compact ? 4 : 6,
      children: [
        for (final u in units)
          InkWell(
            onTap: () => c.select([u.unitId]),
            child: Container(
              width: compact ? 64 : 92,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(border: Border.all(color: _borderColor)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.engine.unitType(u.typeId).shortName,
                    style: const TextStyle(color: _textColor, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  LinearProgressIndicator(
                    value: u.maxHp == 0 ? 0 : u.hp / u.maxHp,
                    minHeight: 3,
                    color: _hpColor(u.hp, u.maxHp),
                    backgroundColor: const Color(0xFF2A2A2A),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );

  static Color _hpColor(int hp, int max) {
    final f = max == 0 ? 0 : hp / max;
    return f > 0.66
        ? const Color(0xFF2EE62E)
        : f > 0.33
        ? const Color(0xFFF5D90A)
        : const Color(0xFFE5322E);
  }

  Widget _statBar(String label, int value, int max, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
      children: [
        SizedBox(
          width: compact ? 46 : 56,
          child: Text(
            label,
            style: TextStyle(color: _dimText, fontSize: compact ? 11 : 12),
          ),
        ),
        SizedBox(
          width: compact ? 90 : 140,
          child: LinearProgressIndicator(
            value: max == 0 ? 0 : (value / max).clamp(0.0, 1.0),
            minHeight: 6,
            color: color,
            backgroundColor: const Color(0xFF2A2A2A),
          ),
        ),
        const SizedBox(width: 8),
        Text('$value/$max', style: const TextStyle(color: _textColor, fontSize: 12)),
      ],
    ),
  );

  Widget _progress(String label, int permille) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('$label  ${(permille / 10).round()}%', style: const TextStyle(color: _textColor, fontSize: 12)),
      const SizedBox(height: 3),
      SizedBox(
        width: 220,
        child: LinearProgressIndicator(value: permille / 1000, minHeight: 6, color: const Color(0xFF4FA3FF), backgroundColor: const Color(0xFF2A2A2A)),
      ),
    ],
  );
}

/// One production slot: an icon, a progress bar for the item in
/// production, or an empty frame.
class _QueueSlot extends StatelessWidget {
  final GameController? c;
  final int icon;
  final int progressPermille; // -1 = no bar
  final String tooltip;
  final VoidCallback? onTap;
  const _QueueSlot({required GameController this.c, required this.icon, required this.progressPermille, required this.tooltip, required this.onTap});
  const _QueueSlot.empty() : c = null, icon = -1, progressPermille = -1, tooltip = '', onTap = null;

  @override
  Widget build(BuildContext context) {
    final image = icon >= 0 ? c?.icons?.command(icon, IconState.normal) : null;
    final box = Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        border: Border.all(color: onTap == null ? const Color(0xFF1A1A1A) : _borderColor),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Stack(
        children: [
          if (image != null)
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: RawImage(image: image, filterQuality: FilterQuality.medium, fit: BoxFit.contain),
              ),
            ),
          if (progressPermille >= 0)
            Positioned(
              left: 2,
              right: 2,
              bottom: 2,
              child: LinearProgressIndicator(
                value: progressPermille / 1000,
                minHeight: 4,
                color: const Color(0xFF3CFF3C),
                backgroundColor: const Color(0xFF101010),
              ),
            ),
        ],
      ),
    );
    if (onTap == null) return box;
    return Tooltip(
      message: tooltip,
      child: InkWell(onTap: onTap, child: box),
    );
  }
}

class _Help extends StatelessWidget {
  const _Help();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: _dimText, fontSize: 12, height: 1.5);
    return const Text(
      'Left click: select   ·   Drag: box select   ·   Shift: add to selection   ·   Double click: all of that type\n'
      'Right click: move / attack / gather / set rally point   ·   Minimap: click to jump, right click to command\n'
      'Hotkeys as in the original: the highlighted letter on each button. Workers: B / V open the build menus,\n'
      'then the building letter (SCV: B, S = Supply Depot; Probe: B, C = Photon Cannon). Esc goes back, or opens the game menu.\n'
      'Ctrl+1..9 assigns a group, 1..9 selects it (twice jumps to it), Shift+1..9 adds to it.\n'
      'Scroll: push the mouse against any screen edge or corner, arrow keys, middle drag. F11: fullscreen.',
      style: style,
    );
  }
}

class CommandCard extends StatelessWidget {
  final GameController c;
  final bool compact; // phone: square touch-sized buttons over the map
  const CommandCard({super.key, required this.c, this.compact = false});

  /// The compact card: a fixed grid of five by two 46 dp buttons (a card
  /// never has more than nine), so a button never moves under the finger
  /// when another one appears.
  static const int compactColumns = 5;
  static const double compactWidth = compactColumns * 46 + (compactColumns - 1) * 4 + 12;

  @override
  Widget build(BuildContext context) {
    final buttons = c.commandCard();
    if (compact) {
      if (buttons.isEmpty) return const SizedBox.shrink();
      final rows = math.max(2, (buttons.length + compactColumns - 1) ~/ compactColumns);
      return Container(
        width: compactWidth,
        height: rows * 46 + (rows - 1) * 4 + 12,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: const Color(0xCC000000),
          border: Border.all(color: _borderColor),
          borderRadius: BorderRadius.circular(6),
        ),
        child: GridView.count(
          crossAxisCount: compactColumns,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          physics: const NeverScrollableScrollPhysics(),
          children: [for (final b in buttons) _button(b)],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: _panelColor,
        border: Border.all(color: _borderColor),
      ),
      child: buttons.isEmpty
          ? const Center(
              child: Text('No commands', style: TextStyle(color: _dimText)),
            )
          : GridView.count(crossAxisCount: 4, mainAxisSpacing: 5, crossAxisSpacing: 5, childAspectRatio: 1.25, children: [for (final b in buttons) _button(b)]),
    );
  }

  Widget _button(CmdButton b) {
    final state = !b.enabled ? IconState.disabled : (b.active ? IconState.active : IconState.normal);
    final icon = b.icon >= 0 ? c.icons?.command(b.icon, state) : null;
    final hasCost = b.mineralCost > 0 || b.gasCost > 0;
    const short = Color(0xFFFF6B5E);
    const greyed = Color(0xFF5A5A5A);
    final costs = <String>[
      if (b.mineralCost > 0) '${b.mineralCost} minerals',
      if (b.gasCost > 0) '${b.gasCost} gas',
      if (b.energyCost > 0) '${b.energyCost} energy',
      if (b.kind == CmdKind.produce && c.engine.unitType(b.typeId).supply > 0) '${c.engine.unitType(b.typeId).supply.toStringAsFixed(0)} supply',
    ];
    final tooltip = [
      '${b.label}${b.hotkey.isEmpty ? '' : '  (${b.hotkey})'}',
      if (costs.isNotEmpty) costs.join(', '),
      if (!b.enabled) b.kind == CmdKind.produce && requirementText.containsKey(b.typeId) ? 'Requires ${requirementText[b.typeId]}' : 'Requirements not met',
    ].join('\n');
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 300),
      child: _Tile(
        onTap: () => c.activate(b, fromClick: true),
        active: b.active,
        child: Stack(
          children: [
            Positioned.fill(
              bottom: hasCost ? 12 : 0,
              child: icon != null
                  ? RawImage(image: icon, filterQuality: FilterQuality.medium, fit: BoxFit.contain)
                  : Center(
                      child: compact
                          ? FittedBox(
                              fit: BoxFit.scaleDown,
                              child: _HotkeyLabel(label: b.label, hotkey: b.hotkey, color: b.enabled ? _textColor : greyed),
                            )
                          : _HotkeyLabel(label: b.label, hotkey: b.hotkey, color: b.enabled ? _textColor : greyed),
                    ),
            ),
            if (b.hotkey.length == 1)
              Positioned(
                left: 1,
                top: 0,
                child: Text(
                  b.hotkey,
                  style: TextStyle(color: b.enabled ? const Color(0xFFFFD54F) : greyed, fontSize: 10, fontWeight: FontWeight.w700),
                ),
              ),
            if (hasCost)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Text.rich(
                  TextSpan(
                    children: [
                      if (b.mineralCost > 0)
                        TextSpan(
                          text: '${b.mineralCost}',
                          style: TextStyle(
                            color: !b.enabled
                                ? greyed
                                : c.minerals >= b.mineralCost
                                ? _mineralColor
                                : short,
                          ),
                        ),
                      if (b.gasCost > 0)
                        TextSpan(
                          text: ' ${b.gasCost}',
                          style: TextStyle(
                            color: !b.enabled
                                ? greyed
                                : c.gas >= b.gasCost
                                ? _gasColor
                                : short,
                          ),
                        ),
                    ],
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 9),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A label with its hotkey letter highlighted, like the original's buttons.
class _HotkeyLabel extends StatelessWidget {
  final String label;
  final String hotkey;
  final Color color;
  const _HotkeyLabel({required this.label, required this.hotkey, required this.color});

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(color: color, fontSize: 11);
    final i = hotkey.length == 1 ? label.toUpperCase().indexOf(hotkey) : -1;
    if (i < 0) {
      return Text(hotkey.length == 1 ? '$label ($hotkey)' : label, style: style, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis);
    }
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: label.substring(0, i)),
          TextSpan(
            text: label.substring(i, i + 1),
            style: TextStyle(color: color == const Color(0xFF5A5A5A) ? color : const Color(0xFFFFD54F), fontWeight: FontWeight.w700),
          ),
          TextSpan(text: label.substring(i + 1)),
        ],
      ),
      style: style,
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _Tile extends StatelessWidget {
  final VoidCallback onTap;
  final Widget child;
  final bool active;
  const _Tile({required this.onTap, required this.child, this.active = false});

  @override
  Widget build(BuildContext context) => Material(
    color: active ? const Color(0xFF2E2E2E) : const Color(0xFF111111),
    shape: RoundedRectangleBorder(
      side: BorderSide(color: active ? const Color(0xFFFFFFFF) : _borderColor),
      borderRadius: BorderRadius.circular(3),
    ),
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Center(child: child),
      ),
    ),
  );
}

/// F12: frame rate and where frame time goes, to tell a slow frame from a
/// slow desktop compositor.
class PerfOverlay extends StatelessWidget {
  final GameController c;
  final List<ui.FrameTiming> timings;
  const PerfOverlay({super.key, required this.c, required this.timings});

  static double _ms(Iterable<int> micros, {bool worst = false}) {
    if (micros.isEmpty) return 0;
    final list = micros.toList();
    return (worst ? list.reduce((a, b) => a > b ? a : b) : list.reduce((a, b) => a + b) / list.length) / 1000;
  }

  @override
  Widget build(BuildContext context) {
    final t = timings;
    double fps = 0;
    if (t.length > 1) {
      final span = t.last.timestampInMicroseconds(ui.FramePhase.vsyncStart) - t.first.timestampInMicroseconds(ui.FramePhase.vsyncStart);
      if (span > 0) fps = (t.length - 1) * 1e6 / span;
    }
    final build = t.map((f) => f.buildDuration.inMicroseconds);
    final raster = t.map((f) => f.rasterDuration.inMicroseconds);
    final total = t.map((f) => f.totalSpan.inMicroseconds);
    final lines = [
      '${fps.toStringAsFixed(1)} fps',
      'tick   ${_ms(c.tickMicros).toStringAsFixed(1)} ms  (worst ${_ms(c.tickMicros, worst: true).toStringAsFixed(1)})',
      'build  ${_ms(build).toStringAsFixed(1)} ms  (worst ${_ms(build, worst: true).toStringAsFixed(1)})',
      'raster ${_ms(raster).toStringAsFixed(1)} ms  (worst ${_ms(raster, worst: true).toStringAsFixed(1)})',
      'frame  ${_ms(total).toStringAsFixed(1)} ms  (worst ${_ms(total, worst: true).toStringAsFixed(1)})',
    ];
    return Container(
      padding: const EdgeInsets.all(8),
      color: const Color(0xCC000000),
      child: Text(
        lines.join('\n'),
        style: const TextStyle(color: Color(0xFF3CFF3C), fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }
}
