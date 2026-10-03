// lib/ui/hud.dart
//
// Top resource bar, selection panel and command card. All rebuild from
// GameController.hud (throttled), never per simulation frame.

import 'package:flutter/material.dart';

import '../engine/models.dart';
import '../game/game_controller.dart';

const _panelColor = Color(0xFF14181C);
const _borderColor = Color(0xFF2E3A44);
const _mineralColor = Color(0xFF6FD3FF);
const _gasColor = Color(0xFF4CE07A);
const _textColor = Color(0xFFE6E6E6);
const _dimText = Color(0xFF8A96A0);

class TopBar extends StatelessWidget {
  final GameController c;
  const TopBar({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final seconds = (c.frame * GameController.frameMicros) ~/ 1000000;
    final time = '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final supplyFull = c.supplyUsed >= c.supplyMax;
    String? hint;
    if (c.mode == CommandMode.build && c.buildTypeId != null) {
      hint = 'Place ${c.engine.unitType(c.buildTypeId!).shortName}: left click to build, right click or Esc to cancel';
    } else if (c.mode != CommandMode.none) {
      hint = '${c.mode.name[0].toUpperCase()}${c.mode.name.substring(1)}: left click a target, right click or Esc to cancel';
    }
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: _panelColor,
        border: Border(bottom: BorderSide(color: _borderColor)),
      ),
      child: Row(
        children: [
          _resource(Icons.diamond, _mineralColor, '${c.minerals}', 'Minerals'),
          const SizedBox(width: 20),
          _resource(Icons.local_fire_department, _gasColor, '${c.gas}', 'Vespene gas'),
          const SizedBox(width: 20),
          _resource(
            Icons.house,
            supplyFull ? const Color(0xFFFF6B5E) : _textColor,
            '${c.supplyUsed.toStringAsFixed(0)}/${c.supplyMax.toStringAsFixed(0)}',
            'Supply used / available',
          ),
          const SizedBox(width: 20),
          Text(time, style: const TextStyle(color: _dimText, fontFeatures: [FontFeature.tabularFigures()])),
          const SizedBox(width: 24),
          Expanded(
            child: Text(
              c.message ?? hint ?? '',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.message != null ? const Color(0xFFFFD54F) : _textColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resource(IconData icon, Color color, String value, String tooltip) => Tooltip(
    message: tooltip,
    child: Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(
          value,
          style: TextStyle(color: color, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ],
    ),
  );
}

class SelectionPanel extends StatelessWidget {
  final GameController c;
  const SelectionPanel({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final selected = c.selectedUnits;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: _panelColor, border: Border.all(color: _borderColor)),
      child: selected.isEmpty
          ? const _Help()
          : selected.length == 1
          ? _single(selected.first)
          : _multiple(selected),
    );
  }

  Widget _single(UnitInfo u) {
    final t = c.engine.unitType(u.typeId);
    final owner = u.owner == GameController.myPlayer
        ? 'You'
        : u.owner == GameController.neutralPlayer
        ? 'Neutral'
        : 'Player ${u.owner + 1}';
    final lines = <Widget>[
      Row(
        children: [
          Expanded(
            child: Text(
              t.name,
              style: const TextStyle(color: _textColor, fontSize: 16, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(owner, style: const TextStyle(color: _dimText)),
        ],
      ),
      const SizedBox(height: 8),
    ];
    if (u.isResource) {
      lines.add(Text(
        '${u.typeId == 188 ? 'Vespene gas' : 'Minerals'}: ${u.resources}',
        style: TextStyle(color: u.typeId == 188 ? _gasColor : _mineralColor),
      ));
    } else {
      lines.add(_statBar('HP', u.hp, u.maxHp, _hpColor(u.hp, u.maxHp)));
      if (u.maxShields > 0) lines.add(_statBar('Shields', u.shields, u.maxShields, const Color(0xFF4FA3FF)));
      if (u.energy > 0) lines.add(_statBar('Energy', u.energy, 200, const Color(0xFFB57BFF)));
    }
    if (!u.isCompleted && u.progressPermille >= 0) {
      lines.add(const SizedBox(height: 6));
      lines.add(_progress('Under construction', u.progressPermille));
    } else if (u.queue.isNotEmpty) {
      lines.add(const SizedBox(height: 6));
      final first = c.engine.unitType(u.queue.first).shortName;
      lines.add(_progress('Training $first', u.progressPermille < 0 ? 0 : u.progressPermille));
      if (u.queue.length > 1) {
        lines.add(Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Queued: ${u.queue.skip(1).map((id) => c.engine.unitType(id).shortName).join(', ')}',
            style: const TextStyle(color: _dimText, fontSize: 12),
          ),
        ));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines);
  }

  Widget _multiple(List<UnitInfo> units) => SingleChildScrollView(
    child: Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final u in units)
          InkWell(
            onTap: () => c.select([u.unitId]),
            child: Container(
              width: 92,
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
    return f > 0.66 ? const Color(0xFF2EE62E) : f > 0.33 ? const Color(0xFFF5D90A) : const Color(0xFFE5322E);
  }

  Widget _statBar(String label, int value, int max, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      children: [
        SizedBox(width: 56, child: Text(label, style: const TextStyle(color: _dimText, fontSize: 12))),
        SizedBox(
          width: 140,
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
        child: LinearProgressIndicator(
          value: permille / 1000,
          minHeight: 6,
          color: const Color(0xFF4FA3FF),
          backgroundColor: const Color(0xFF2A2A2A),
        ),
      ),
    ],
  );
}

class _Help extends StatelessWidget {
  const _Help();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: _dimText, fontSize: 12, height: 1.5);
    return const Text(
      'Left click: select   ·   Drag: box select   ·   Shift: add to selection   ·   Double click: all of that type\n'
      'Right click: move / attack / gather / set rally point   ·   Minimap: click to jump, right click to command\n'
      'A attack   M move   S stop   H hold   P patrol   Esc cancel   ·   Arrows, screen edge or middle drag: scroll\n'
      'Select an SCV for its build menu, a Command Center to train SCVs. Workers start mining automatically.',
      style: style,
    );
  }
}

class CommandCard extends StatelessWidget {
  final GameController c;
  const CommandCard({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final selected = c.selectedUnits;
    final buttons = <Widget>[];
    if (c.selectionIsMine) {
      final movable = selected.any((u) => u.canMove);
      if (movable) {
        buttons.addAll([
          _button('Move', 'M', () => c.setMode(CommandMode.move), active: c.mode == CommandMode.move),
          _button('Stop', 'S', () => c.instantOrder(UnitOrder.stop)),
          _button('Attack', 'A', () => c.setMode(CommandMode.attack), active: c.mode == CommandMode.attack),
          _button('Patrol', 'P', () => c.setMode(CommandMode.patrol), active: c.mode == CommandMode.patrol),
          _button('Hold', 'H', () => c.instantOrder(UnitOrder.hold)),
        ]);
      }
      if (selected.length == 1) {
        final u = selected.first;
        for (final typeId in c.engine.getBuildable(GameController.myPlayer)) {
          final t = c.engine.unitType(typeId);
          final affordable = c.minerals >= t.mineralCost && c.gas >= t.gasCost;
          buttons.add(_produceButton(t, affordable, active: c.mode == CommandMode.build && c.buildTypeId == typeId));
        }
        if ((u.isBuilding && u.queue.isNotEmpty) || (!u.isCompleted && u.isBuilding)) {
          buttons.add(_button('Cancel', '', c.cancelLast, danger: true));
        }
      }
    }
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: _panelColor, border: Border.all(color: _borderColor)),
      child: buttons.isEmpty
          ? const Center(child: Text('No commands', style: TextStyle(color: _dimText)))
          : SingleChildScrollView(child: Wrap(spacing: 6, runSpacing: 6, children: buttons)),
    );
  }

  Widget _button(String label, String key, VoidCallback onTap, {bool active = false, bool danger = false}) => _Tile(
    onTap: onTap,
    active: active,
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(label, style: TextStyle(color: danger ? const Color(0xFFFF6B5E) : _textColor, fontSize: 12)),
        if (key.isNotEmpty) Text(key, style: const TextStyle(color: _dimText, fontSize: 10)),
      ],
    ),
  );

  Widget _produceButton(UnitTypeInfo t, bool affordable, {bool active = false}) => Tooltip(
    message: '${t.name}\n${t.mineralCost} minerals${t.gasCost > 0 ? ', ${t.gasCost} gas' : ''}'
        '${t.supply > 0 ? ', ${t.supply.toStringAsFixed(0)} supply' : ''}',
    child: _Tile(
      onTap: () => c.produce(t.typeId),
      active: active,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            t.shortName,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: affordable ? _textColor : _dimText, fontSize: 11),
          ),
          const SizedBox(height: 2),
          Text.rich(
            TextSpan(children: [
              TextSpan(text: '${t.mineralCost}', style: const TextStyle(color: _mineralColor)),
              if (t.gasCost > 0) TextSpan(text: ' ${t.gasCost}', style: const TextStyle(color: _gasColor)),
            ]),
            style: const TextStyle(fontSize: 10),
          ),
        ],
      ),
    ),
  );
}

class _Tile extends StatelessWidget {
  final VoidCallback onTap;
  final Widget child;
  final bool active;
  const _Tile({required this.onTap, required this.child, this.active = false});

  @override
  Widget build(BuildContext context) => Material(
    color: active ? const Color(0xFF26445A) : const Color(0xFF1E252B),
    shape: RoundedRectangleBorder(
      side: BorderSide(color: active ? const Color(0xFF6FD3FF) : _borderColor),
      borderRadius: BorderRadius.circular(3),
    ),
    child: InkWell(
      onTap: onTap,
      child: SizedBox(width: 74, height: 50, child: Padding(padding: const EdgeInsets.all(3), child: child)),
    ),
  );
}
