// lib/ui/saved_games_list.dart
//
// The saved games, for the start screen's Load game tab and the in-game
// menu's Load game: sessions grouped by map (most recent first), a search
// box, and per session its points in time (continue from the latest or pick
// an earlier one) and a delete button. Colors come from the surrounding
// theme (the menus' green on the start screen, white in a game).

import 'package:flutter/material.dart';

import '../game/game_setup.dart';
import '../game/saved_games.dart';

const _line = Color(0xFF2A2A2A);
const _dim = Color(0xFF8C8C8C);
const _faint = Color(0xFF5E5E5E);

/// Every word typed must appear somewhere in [text] (any case, any order).
bool searchMatches(String query, String text) {
  final t = text.toLowerCase();
  return query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).every(t.contains);
}

/// "just now", "5m ago", "3h ago", "2d ago".
String timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

/// A list's search box.
class SearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final VoidCallback onChanged;
  const SearchField({super.key, required this.controller, required this.hint, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: _line));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: TextField(
        controller: controller,
        onChanged: (_) => onChanged(),
        textInputAction: TextInputAction.search,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: const TextStyle(color: _faint),
          prefixIcon: const Icon(Icons.search, size: 18, color: _dim),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close, size: 16, color: _dim),
                  onPressed: () {
                    controller.clear();
                    onChanged();
                  },
                ),
          border: border,
          enabledBorder: border,
        ),
      ),
    );
  }
}

/// A list's section title, in the theme's accent color.
class ListHeading extends StatelessWidget {
  final String text;
  const ListHeading(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(fontSize: 11, letterSpacing: 1.6, color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700),
    ),
  );
}

class SavedGamesList extends StatefulWidget {
  final void Function(SaveSession session, SavePoint point) onLoad;

  /// After a session was deleted (the list reloads itself).
  final VoidCallback? onDeleted;

  /// Called on hover and click, for the menus' sounds.
  final VoidCallback? onHover;
  final VoidCallback? onClick;

  const SavedGamesList({super.key, required this.onLoad, this.onDeleted, this.onHover, this.onClick});

  @override
  State<SavedGamesList> createState() => _SavedGamesListState();
}

class _SavedGamesListState extends State<SavedGamesList> {
  final _search = TextEditingController();
  List<SaveSession> _saves = SaveSession.list();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_saves.isEmpty) {
      return const Center(child: Text('No saved games yet.', style: TextStyle(color: _dim)));
    }
    final query = _search.text;
    final byMap = <String, List<SaveSession>>{};
    for (final s in _saves) {
      if (!searchMatches(query, '${s.name} ${s.mapName} ${s.origin}')) continue;
      byMap.putIfAbsent(s.mapKey, () => []).add(s);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SearchField(controller: _search, hint: 'Search ${_saves.length} saved games', onChanged: () => setState(() {})),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              if (byMap.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('No saved game matches "$query".', style: const TextStyle(color: _dim)),
                ),
              for (final entry in byMap.entries) ...[ListHeading(entry.value.first.mapName), for (final s in entry.value) _sessionTile(s)],
            ],
          ),
        ),
      ],
    );
  }

  void _load(SaveSession s, SavePoint p) {
    widget.onClick?.call();
    widget.onLoad(s, p);
  }

  Widget _sessionTile(SaveSession s) {
    final me = s.setup.players.where((p) => p.human).firstOrNull;
    final others = s.setup.players.where((p) => !p.human).map((p) => raceName(p.race)).join(', ');
    final latest = s.latest!;
    return MouseRegion(
      onEnter: (_) => widget.onHover?.call(),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
          childrenPadding: const EdgeInsets.fromLTRB(32, 0, 12, 8),
          title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
            [
              'you as ${raceName(me?.race ?? 1)} vs $others',
              s.setup.alliances.label,
              '${s.points.length} ${s.points.length == 1 ? 'point' : 'points'} up to ${latest.gameTime}',
              'saved ${timeAgo(s.lastSaved)}',
              if (s.origin.isNotEmpty) 'from ${s.origin}',
            ].join('  ·  '),
            style: const TextStyle(fontSize: 12, color: _faint),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Delete this session',
                icon: const Icon(Icons.delete_outline, color: _dim),
                onPressed: () => _delete(s),
              ),
              const SizedBox(width: 4),
              FilledButton(onPressed: () => _load(s, latest), child: Text('Continue at ${latest.gameTime}')),
              const SizedBox(width: 4),
              const Icon(Icons.expand_more, color: _dim),
            ],
          ),
          children: [
            for (final p in s.points.reversed)
              ListTile(
                dense: true,
                leading: Icon(p.manual ? Icons.bookmark : Icons.history, size: 18, color: p.manual ? Colors.white : _dim),
                title: Text(p.manual ? '${p.gameTime}  ${p.name}' : '${p.gameTime}  auto-save'),
                subtitle: Text('saved ${timeAgo(p.saved)}', style: const TextStyle(fontSize: 11, color: _faint)),
                trailing: OutlinedButton(onPressed: () => _load(s, p), child: const Text('Load')),
                onTap: () => _load(s, p),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _delete(SaveSession s) async {
    widget.onClick?.call();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this session?'),
        content: Text('"${s.name}" and its ${s.points.length} points in time will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    s.delete();
    setState(() => _saves = SaveSession.list());
    widget.onDeleted?.call();
  }
}
