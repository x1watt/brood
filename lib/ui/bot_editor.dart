// lib/ui/bot_editor.dart
//
// The bot profile editor (docs/bot_profiles.md), opened from the start
// screen's opponents. The first page lists the profiles: the ones shipped
// with the game can't be changed (they are edited as a copy), the player's
// own are kept in the game data's bots/ folder. A profile opens in two
// tabs:
//   - Settings: its name and description, and every number it plays by,
//     with what the number does and its standard value. Changes are kept in
//     the profile's settings.bot, which its profile.bot includes last.
//   - Code: its files in a text editor, for tables and events.
// Check compiles the profile as it stands (saved or not); an error names
// its place, and Show goes there.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/models.dart';
import '../game/bot_profiles.dart';

const _dim = Color(0xFF8C8C8C);
const _faint = Color(0xFF5E5E5E);
const _green = Color(0xFF32D25A);
const _red = Color(0xFFE57373);
const _mono = TextStyle(fontFamily: 'NotoSansMono', fontSize: 13, height: 1.45, color: Color(0xFFE8E8E8));

// --- the list ---------------------------------------------------------------------

class BotProfilesScreen extends StatefulWidget {
  const BotProfilesScreen({super.key});

  @override
  State<BotProfilesScreen> createState() => _BotProfilesScreenState();
}

class _BotProfilesScreenState extends State<BotProfilesScreen> {
  BotLibrary? _lib;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final lib = await BotLibrary.load();
    if (mounted) setState(() => _lib = lib);
  }

  Future<void> _open(String folder) async {
    final lib = _lib!;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => BotEditorScreen(library: lib, folder: folder)));
    if (mounted) setState(() {});
  }

  Future<void> _new({String? copyOf}) async {
    final lib = _lib!;
    final source = copyOf == null ? null : lib.byFolder(copyOf);
    final made = await showDialog<(String, String, String?)>(
      context: context,
      builder: (_) => _NewProfileDialog(library: lib, copyOf: copyOf, suggestedName: source == null ? '' : 'My ${source.name}'),
    );
    if (made == null) return;
    final (name, description, from) = made;
    final folder = await lib.create(name, description, copyOf: from);
    if (!mounted) return;
    setState(() {});
    await _open(folder);
  }

  Future<void> _delete(BotProfile p) async {
    final lib = _lib!;
    final shipped = lib.overridesShipped(p.folder);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete ${p.name}?'),
        content: Text(
          shipped
              ? 'Your changes to this profile are deleted; the one shipped with the game comes back.'
              : 'Its files are deleted from the bots folder. Saved games that used it keep playing it.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await lib.deleteProfile(p.folder);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final lib = _lib;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Bot profiles'),
        actions: [
          IconButton(
            tooltip: 'How profiles work',
            icon: const Icon(Icons.help_outline),
            onPressed: () => showDialog<void>(context: context, builder: (_) => const _HelpDialog()),
          ),
        ],
      ),
      floatingActionButton: lib == null
          ? null
          : FloatingActionButton.extended(onPressed: () => _new(), icon: const Icon(Icons.add), label: const Text('New profile')),
      body: lib == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
              children: [
                for (final p in lib.profiles)
                  ListTile(
                    leading: const Icon(Icons.smart_toy_outlined),
                    title: Text(p.name),
                    subtitle: Text(
                      [if (p.description.isNotEmpty) p.description, _origin(lib, p.folder)].join('\n'),
                      style: const TextStyle(fontSize: 12, color: _dim),
                    ),
                    isThreeLine: p.description.isNotEmpty,
                    onTap: () => lib.isBuiltIn(p.folder) ? _new(copyOf: p.folder) : _open(p.folder),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) => switch (v) {
                        'edit' => _open(p.folder),
                        'copy' => _new(copyOf: p.folder),
                        'delete' => _delete(p),
                        _ => null,
                      },
                      itemBuilder: (_) => [
                        if (!lib.isBuiltIn(p.folder)) const PopupMenuItem(value: 'edit', child: Text('Edit')),
                        const PopupMenuItem(value: 'copy', child: Text('Make a copy')),
                        if (!lib.isBuiltIn(p.folder)) const PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  static String _origin(BotLibrary lib, String folder) {
    if (lib.isBuiltIn(folder)) return 'Shipped with the game (tap to edit a copy)';
    if (lib.overridesShipped(folder)) return 'Yours: bots/$folder (replaces the shipped one)';
    return 'Yours: bots/$folder';
  }
}

class _NewProfileDialog extends StatefulWidget {
  final BotLibrary library;
  final String? copyOf;
  final String suggestedName;
  const _NewProfileDialog({required this.library, this.copyOf, this.suggestedName = ''});

  @override
  State<_NewProfileDialog> createState() => _NewProfileDialogState();
}

class _NewProfileDialogState extends State<_NewProfileDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.suggestedName);
  late final TextEditingController _description = TextEditingController(
    text: widget.copyOf == null ? '' : widget.library.byFolder(widget.copyOf!)?.description ?? '',
  );
  late String _from = widget.copyOf ?? '';

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = _name.text.trim();
    return AlertDialog(
      title: const Text('New bot profile'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            TextField(controller: _description, decoration: const InputDecoration(labelText: 'Description')),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _from,
              decoration: const InputDecoration(labelText: 'Start from'),
              items: [
                const DropdownMenuItem(value: '', child: Text('The standard player (change only what you need)')),
                for (final p in widget.library.profiles) DropdownMenuItem(value: p.folder, child: Text('A copy of ${p.name}')),
              ],
              onChanged: (v) => setState(() => _from = v ?? ''),
            ),
            const SizedBox(height: 8),
            Text(
              name.isEmpty ? '' : 'Saved in bots/${widget.library.folderFor(name)}',
              style: const TextStyle(fontSize: 12, color: _faint),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: name.isEmpty ? null : () => Navigator.pop(context, (name, _description.text.trim(), _from.isEmpty ? null : _from)),
          child: const Text('Create'),
        ),
      ],
    );
  }
}

class _HelpDialog extends StatelessWidget {
  const _HelpDialog();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Bot profiles'),
    content: const SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Text(
          'A bot profile sets how a computer player plays. Pick one for each opponent on the start screen.\n\n'
          'Settings: every number the player plays by (how big its first attack is, when it expands, '
          'how much it trusts others, and so on). Change a number and save; Reset goes back to what the '
          'profile would use otherwise.\n\n'
          'Code: the profile\'s files in BotScript, a small language like C. Build plans, research and '
          'the army mix are tables; events such as "on wave(ready)" or "on invite(from)" make decisions '
          'during the game. The full reference is docs/bot_profiles.md; the standard profile spells out '
          'every number and table.\n\n'
          'Your profiles are kept in the bots folder of your game data. A game keeps the profiles it was '
          'started with, so changing one never changes a saved game.',
        ),
      ),
    ),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
  );
}

// --- one profile -----------------------------------------------------------------

class BotEditorScreen extends StatefulWidget {
  final BotLibrary library;
  final String folder;
  const BotEditorScreen({super.key, required this.library, required this.folder});

  @override
  State<BotEditorScreen> createState() => _BotEditorScreenState();
}

class _BotEditorScreenState extends State<BotEditorScreen> with SingleTickerProviderStateMixin {
  BotLibrary get lib => widget.library;
  String get folder => widget.folder;
  String get _profilePath => '$folder/profile.bot';

  late final TabController _tabs = TabController(length: 2, vsync: this);
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _search = TextEditingController();

  // Settings: what the profile plays with without the tab's changes, the
  // standard values, and the tab's own (settings.bot).
  BotNumbers? _effective;
  BotNumbers? _standard;
  Map<String, int> _settings = {};
  late final List<BotNumberInfo> _info = lib.numberInfo();
  final Map<String, TextEditingController> _fields = {};

  // Code: the text of each file being edited.
  final Map<String, TextEditingController> _code = {};
  late String _file = _profilePath;
  final _codeFocus = FocusNode();

  bool _dirty = false;
  BotProfileReport? _report;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    final p = lib.byFolder(folder);
    _name.text = p?.name ?? folder;
    _description.text = p?.description ?? '';
    _settings = lib.settingsOf(folder);
    for (final path in lib.filesIn(folder)) {
      _code[path] = _codeController(lib.files[path]!);
    }
    _loadNumbers();
    _check();
  }

  TextEditingController _codeController(String text) => TextEditingController(text: text)..addListener(_changed);

  void _changed() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _loadNumbers() async {
    final standard = await lib.numbers(null);
    // Without the Settings tab's numbers: settings.bot left out.
    final files = Map.of(lib.filesOf(folder))..remove('$folder/settings.bot');
    final without = BotLibrary(files);
    final effective = await without.numbers(folder);
    if (!mounted) return;
    setState(() {
      _standard = standard;
      _effective = effective.error.isEmpty ? effective : standard;
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _name.dispose();
    _description.dispose();
    _search.dispose();
    _codeFocus.dispose();
    for (final c in [..._fields.values, ..._code.values]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The files as they stand in the editor (saved or not).
  Map<String, String> _currentFiles() {
    final files = Map.of(lib.files);
    for (final e in _code.entries) {
      files[e.key] = e.value.text;
    }
    final header = BotLibrary.withHeader(files[_profilePath] ?? '', name: _name.text.trim(), description: _description.text.trim());
    files[_profilePath] = header;
    return files;
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    final r = await BotLibrary(_currentFiles()).check(folder);
    if (mounted) {
      setState(() {
        _report = r;
        _checking = false;
      });
    }
  }

  Future<void> _save() async {
    // The header and code first, then the Settings tab's numbers (which
    // may add the include to profile.bot).
    final files = _currentFiles();
    for (final path in {..._code.keys, _profilePath}) {
      final text = files[path]!;
      if (lib.files[path] != text) await lib.saveFile(path, text);
    }
    if (_settings.isNotEmpty || lib.files.containsKey('$folder/settings.bot')) {
      await lib.saveSettings(folder, _settings);
      for (final path in ['$folder/settings.bot', _profilePath]) {
        final text = lib.files[path]!;
        final c = _code[path];
        if (c == null) {
          _code[path] = _codeController(text);
        } else if (c.text != text) {
          c.text = text;
        }
      }
    }
    if (!mounted) return;
    setState(() => _dirty = false);
    await _check();
    if (!mounted) return;
    final r = _report;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(r == null || r.ok ? 'Saved ${_name.text.trim()}' : 'Saved, but it doesn\'t compile: ${r.error}')),
    );
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Unsaved changes'),
        content: const Text('Leave without saving them?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Stay')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Leave')),
        ],
      ),
    );
    return ok == true;
  }

  /// Goes to the error's place, when it is in one of this profile's files.
  void _showError() {
    final m = RegExp(r'^([^:]+):(\d+):(\d+):').firstMatch(_report?.error ?? '');
    if (m == null) return;
    final path = m[1]!;
    final c = _code[path];
    if (c == null) return;
    final line = int.parse(m[2]!), col = int.parse(m[3]!);
    final lines = c.text.split('\n');
    var offset = 0;
    for (int i = 0; i < line - 1 && i < lines.length; ++i) {
      offset += lines[i].length + 1;
    }
    offset = (offset + col - 1).clamp(0, c.text.length);
    setState(() => _file = path);
    _tabs.animateTo(1);
    c.selection = TextSelection.collapsed(offset: offset);
    WidgetsBinding.instance.addPostFrameCallback((_) => _codeFocus.requestFocus());
  }

  Future<void> _addFile() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New file'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'File name', hintText: 'tactics.bot'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    final file = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_.]+'), '_').replaceAll(RegExp(r'(\.bot)?$'), '.bot');
    final path = '$folder/$file';
    if (_code.containsKey(path)) return setState(() => _file = path);
    final profile = _code[_profilePath]!;
    setState(() {
      _code[path] = _codeController('// bots/$path\n\n');
      // Included from profile.bot, so it is part of the profile.
      profile.text = '${profile.text.trimRight()}\n\ninclude "$file";\n';
      _file = path;
      _dirty = true;
    });
  }

  Future<void> _deleteFile(String path) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete ${path.split('/').last}?'),
        content: const Text('Remember to remove its include from profile.bot too.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await lib.deleteFile(path);
    setState(() {
      _code.remove(path)?.dispose();
      _file = _profilePath;
    });
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (popped, _) async {
        if (popped) return;
        if (await _confirmDiscard() && context.mounted) {
          setState(() => _dirty = false);
          // (Once the rebuild lets the page go.)
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) Navigator.of(context).pop();
          });
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Text(_name.text.trim().isEmpty ? folder : _name.text.trim()),
          actions: [
            TextButton.icon(
              onPressed: _checking ? null : _check,
              icon: Icon(r == null ? Icons.help_outline : r.ok ? Icons.check_circle_outline : Icons.error_outline, color: r == null ? _dim : r.ok ? _green : _red),
              label: const Text('Check'),
            ),
            const SizedBox(width: 4),
            FilledButton.icon(onPressed: _dirty ? _save : null, icon: const Icon(Icons.save_outlined), label: const Text('Save')),
            const SizedBox(width: 12),
          ],
          bottom: TabBar(controller: _tabs, tabs: const [Tab(text: 'Settings'), Tab(text: 'Code')]),
        ),
        body: Column(
          children: [
            if (r != null && !r.ok)
              Material(
                color: const Color(0xFF3A1414),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.error_outline, color: _red),
                  title: Text(r.error, style: const TextStyle(color: Color(0xFFFFCDD2))),
                  trailing: TextButton(onPressed: _showError, child: const Text('Show')),
                ),
              ),
            Expanded(
              child: TabBarView(controller: _tabs, children: [_settingsTab(), _codeTab()]),
            ),
          ],
        ),
      ),
    );
  }

  // --- Settings ---

  Widget _settingsTab() {
    final effective = _effective, standard = _standard;
    if (effective == null || standard == null) return const Center(child: CircularProgressIndicator());
    final query = _search.text.trim().toLowerCase();
    final shown = [
      for (final i in _info)
        if (query.isEmpty || i.name.contains(query.replaceAll(' ', '_')) || i.help.toLowerCase().contains(query)) i,
    ];
    final groups = <String, List<BotNumberInfo>>{};
    for (final i in shown) {
      groups.putIfAbsent(i.group, () => []).add(i);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Name'),
          onChanged: (_) => setState(() => _dirty = true),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _description,
          decoration: const InputDecoration(labelText: 'Description'),
          maxLines: null,
          onChanged: (_) => _changed(),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Find a number (attack, trust, expand...)'),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Text('${_settings.length} changed here', style: const TextStyle(color: _dim, fontSize: 12)),
          ],
        ),
        if (effective.random)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Some numbers depend on random(); the lowest they can be is shown.', style: TextStyle(color: _faint, fontSize: 12)),
          ),
        for (final g in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 4),
            child: Text(g.key.toUpperCase(), style: const TextStyle(color: _green, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1.5)),
          ),
          for (final i in g.value) _numberRow(i, effective.values[i.name] ?? 0, standard.values[i.name] ?? 0),
        ],
      ],
    );
  }

  Widget _numberRow(BotNumberInfo info, int profileValue, int standardValue) {
    final set = _settings[info.name];
    final value = set ?? profileValue;
    final field = _fields.putIfAbsent(info.name, () => TextEditingController(text: '$value'));
    final unit = info.isTime ? ' s' : '';
    final notes = [
      if (info.help.isNotEmpty) info.help,
      if (value != standardValue) 'standard: $standardValue$unit',
      if (set != null && set != profileValue) 'without this change: $profileValue$unit',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(info.label, style: TextStyle(color: set != null ? _green : Colors.white)),
                if (notes.isNotEmpty) Text(notes.join('; '), style: const TextStyle(color: _faint, fontSize: 11)),
              ],
            ),
          ),
          SizedBox(
            width: 96,
            child: TextField(
              controller: field,
              textAlign: TextAlign.end,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^-?\d*'))],
              decoration: InputDecoration(isDense: true, suffixText: unit.trim().isEmpty ? null : unit.trim()),
              onChanged: (t) {
                final v = int.tryParse(t);
                if (v == null) return;
                setState(() {
                  if (v == profileValue) {
                    _settings.remove(info.name);
                  } else {
                    _settings[info.name] = v;
                  }
                  _dirty = true;
                });
              },
            ),
          ),
          SizedBox(
            width: 40,
            child: set == null
                ? null
                : IconButton(
                    tooltip: 'Reset',
                    icon: const Icon(Icons.undo, size: 18),
                    onPressed: () => setState(() {
                      _settings.remove(info.name);
                      field.text = '$profileValue';
                      _dirty = true;
                    }),
                  ),
          ),
        ],
      ),
    );
  }

  // --- Code ---

  Widget _codeTab() {
    final files = _code.keys.toList()..sort((a, b) => a == _profilePath ? -1 : b == _profilePath ? 1 : a.compareTo(b));
    final controller = _code[_file];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final f in files)
                InputChip(
                  label: Text(f.split('/').last),
                  selected: f == _file,
                  onPressed: () => setState(() => _file = f),
                  onDeleted: f == _profilePath ? null : () => _deleteFile(f),
                ),
              ActionChip(avatar: const Icon(Icons.add, size: 16), label: const Text('File'), onPressed: _addFile),
              const SizedBox(width: 8),
              Text('Inherited from other profiles: ${_inherited().join(', ')}', style: const TextStyle(color: _faint, fontSize: 11)),
            ],
          ),
        ),
        Expanded(
          child: controller == null ? const SizedBox.shrink() : _CodeEditor(key: ValueKey(_file), controller: controller, focusNode: _codeFocus),
        ),
      ],
    );
  }

  /// The other profiles' files this one is made of.
  List<String> _inherited() => [
    for (final p in BotLibrary(_currentFiles()).filesOf(folder).keys)
      if (!p.startsWith('$folder/')) p,
  ];
}

/// A plain text editor for code: line numbers, a fixed-width font, tabs,
/// no wrapping.
class _CodeEditor extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  const _CodeEditor({super.key, required this.controller, required this.focusNode});

  @override
  State<_CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<_CodeEditor> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rebuild);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _rebuild() => setState(() {});

  // Tab inserts a tab rather than moving the focus.
  KeyEventResult _key(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.tab) return KeyEventResult.ignored;
    final c = widget.controller;
    final sel = c.selection;
    if (!sel.isValid) return KeyEventResult.ignored;
    c.value = c.value.replaced(sel, '\t');
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    final lines = '\n'.allMatches(text).length + 1;
    final longest = text.split('\n').fold<int>(0, (m, l) => l.replaceAll('\t', '    ').length > m ? l.replaceAll('\t', '    ').length : m);
    final painter = TextPainter(text: const TextSpan(text: 'M', style: _mono), textDirection: TextDirection.ltr)..layout();
    final charWidth = painter.width;
    const strut = StrutStyle(fontFamily: 'NotoSansMono', fontSize: 13, height: 1.45, forceStrutHeight: true);
    return Container(
      color: const Color(0xFF0B0B0B),
      child: LayoutBuilder(
        builder: (context, box) => Scrollbar(
          controller: _vertical,
          child: SingleChildScrollView(
            controller: _vertical,
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 48,
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    [for (int i = 1; i <= lines; ++i) '$i'].join('\n'),
                    textAlign: TextAlign.end,
                    strutStyle: strut,
                    style: _mono.copyWith(color: _faint),
                  ),
                ),
                Expanded(
                  child: Scrollbar(
                    controller: _horizontal,
                    child: SingleChildScrollView(
                      controller: _horizontal,
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: (longest + 4) * charWidth > box.maxWidth - 60 ? (longest + 4) * charWidth : box.maxWidth - 60,
                        child: Focus(
                          onKeyEvent: _key,
                          child: TextField(
                            controller: widget.controller,
                            focusNode: widget.focusNode,
                            maxLines: null,
                            style: _mono,
                            strutStyle: strut,
                            cursorColor: _green,
                            decoration: const InputDecoration(border: InputBorder.none, isCollapsed: true, filled: false),
                            keyboardType: TextInputType.multiline,
                            autocorrect: false,
                            enableSuggestions: false,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
