// lib/ui/map_editor/map_editor_screen.dart
//
// The map editor, opened from a map's edit button on the start screen.
// Tools: select (move, delete, change a start's player or a resource's
// amount), terrain (paints a terrain; the edges around it are filled with
// the right transitions, lib/maps/terrain_blend.dart), tile (places one
// exact tile, no blending; alt-click picks the tile under the cursor), and placing start locations, mineral fields and geysers.
// The side panel also sets every resource at once, the map's name and
// description, and saves the map or a copy under a new name.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../engine/bw_engine.dart';
import '../../game/game_data.dart';
import '../../maps/blend_worker.dart';
import '../../maps/chk.dart';
import '../../maps/map_document.dart';
import '../../maps/terrain_blend.dart';
import '../../maps/tileset.dart';
import '../../rendering/megatile_atlas.dart';
import 'map_canvas.dart';

const _green = Color(0xFF32D25A);
const _yellow = Color(0xFFFCE45C);
const _dim = Color(0xFF8C8C8C);
const _line = Color(0xFF2A2A2A);
const _panelColor = Color(0xFF0E0F0E);

enum EditorTool {
  select(Icons.near_me_outlined, 'Select', 'Click a start location or resource to change it; drag to move it.'),
  terrain(Icons.brush_outlined, 'Terrain', 'Paint a terrain; the edges around it get the right shores and cliffs.'),
  tile(Icons.grid_on, 'Tile', 'Place one exact tile, without blending. Alt-click picks the tile under the cursor.'),
  start(Icons.flag_outlined, 'Start', 'Place a start location for the next player.'),
  mineral(Icons.diamond_outlined, 'Minerals', 'Place a mineral field.'),
  geyser(Icons.local_fire_department_outlined, 'Geyser', 'Place a vespene geyser.');

  final IconData icon;
  final String label;
  final String help;
  const EditorTool(this.icon, this.label, this.help);
}

/// Resource amounts the panel offers at once: (label, minerals, gas).
const List<(String, int, int)> resourceLevels = [
  ('Poor', 500, 2000),
  ('Low', 1000, 3500),
  ('Standard', 1500, 5000),
  ('Rich', 3000, 10000),
  ('Very rich', 8000, 25000),
  ('Gold rush', 20000, 50000),
];

class MapEditorScreen extends StatefulWidget {
  final GameMap map;
  const MapEditorScreen({super.key, required this.map});

  @override
  State<MapEditorScreen> createState() => _MapEditorScreenState();
}

class _MapEditorScreenState extends State<MapEditorScreen> {
  BwEngine? _engine;
  MapDocument? _doc;
  MegatileAtlas? _atlas;
  BlendWorker? _worker;
  final _camera = EditorCamera();
  final Map<int, UnitSprite> _sprites = {};
  String? _error;
  late GameMap _map = widget.map;

  // Learning the tileset's transitions (in the background).
  bool _learning = true;
  int _learnedMaps = 0;
  bool _blending = false;

  EditorTool _tool = EditorTool.select;
  int _brushTerrain = -1; // index into _terrains
  int _brushSize = 2;
  bool _autoEdges = true;
  int _tileValue = 0; // the tile tool's tile
  bool _grid = false;
  int _mineralType = ChkUnit.mineralTypes.first;
  int _mineralAmount = 1500;
  int _gasAmount = 5000;

  ChkUnit? _selected;
  Offset? _hover;
  Offset? _dragFrom; // select tool: where the drag started (map px)
  (int, int)? _dragOrigin; // the unit's position before the drag
  bool _dragged = false;
  final Set<int> _stroke = {}; // terrain: pair cells of the stroke
  final Map<int, int> _tileStroke = {}; // tile: tile index -> value
  List<_Terrain> _terrains = const [];

  final _name = TextEditingController();
  final _description = TextEditingController();
  final _amount = TextEditingController();
  final _focus = FocusNode();
  ui.Image? _minimap;
  int _minimapRevision = -1;
  Timer? _minimapTimer;
  final _rng = math.Random();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _worker?.dispose();
    _engine?.dispose();
    _atlas?.dispose();
    _minimap?.dispose();
    _minimapTimer?.cancel();
    _camera.dispose();
    _name.dispose();
    _description.dispose();
    _amount.dispose();
    _focus.dispose();
    for (final s in _sprites.values) {
      s.image.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final engine = await BwEngine.open();
      _engine = engine;
      engine.loadAssets(gameDataDir);
      final bytes = engine.readMapFile(_map.path, r'staredit\scenario.chk');
      if (bytes == null) throw StateError('The map could not be read.');
      final doc = MapDocument.open(bytes, (i) => Tileset.load(i, engine.readFile));
      if (doc == null) throw StateError('This map has no terrain the editor can read.');
      final atlas = MegatileAtlas(doc.tileset);
      final terrains = _Terrain.of(doc.tileset);
      final used = <int>{
        for (final t in doc.tiles) doc.tileset.megatile(t),
        for (final t in terrains) doc.tileset.megatile(t.left << 4 | doc.tileset.variations(t.left).first),
      };
      await atlas.ensure(used);
      _loadSprites(engine, doc.tileset);
      if (!mounted) return;
      setState(() {
        _doc = doc;
        _atlas = atlas;
        _terrains = terrains;
        _brushTerrain = terrains.indexWhere((t) => t.water);
        if (_brushTerrain < 0 && terrains.isNotEmpty) _brushTerrain = 0;
        _tileValue = doc.tileAt(0, 0);
        _name.text = doc.name;
        _description.text = doc.description;
      });
      doc.addListener(_docChanged);
      _rebuildMinimap();
      _learn(engine, doc);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _learn(BwEngine engine, MapDocument doc) async {
    final worker = BlendWorker.create((f) => engine.readMapFile(f, r'staredit\scenario.chk'));
    _worker = worker;
    try {
      final files = [for (final m in GameMap.list()) m.path];
      final n = await worker.learn(doc.tileset.index, files, _map.path, doc.tiles, doc.width, doc.height);
      if (mounted) {
        setState(() {
          _learning = false;
          _learnedMaps = n;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _learning = false;
          _autoEdges = false;
        });
      }
    }
  }

  void _loadSprites(BwEngine engine, Tileset ts) {
    Future<void> load(int type, String path) async {
      final h = engine.grpLoad(path);
      if (h < 0) return;
      final f = engine.grpFrame(h, 0);
      if (f == null) return;
      final (w, hh, px) = f;
      final rgba = Uint8List(w * hh * 4);
      for (int i = 0; i < w * hh; ++i) {
        final c = px[i];
        if (c == 0) continue;
        rgba[i * 4] = ts.palette[c * 4];
        rgba[i * 4 + 1] = ts.palette[c * 4 + 1];
        rgba[i * 4 + 2] = ts.palette[c * 4 + 2];
        rgba[i * 4 + 3] = 255;
      }
      final done = Completer<ui.Image>();
      ui.decodeImageFromPixels(rgba, w, hh, ui.PixelFormat.rgba8888, done.complete);
      final image = await done.future;
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() => _sprites[type] = UnitSprite(image));
    }

    load(176, r'unit\neutral\min01.grp');
    load(177, r'unit\neutral\min02.grp');
    load(178, r'unit\neutral\min03.grp');
    load(ChkUnit.geyser, r'unit\neutral\geyser.grp');
    load(ChkUnit.startLocation, r'unit\thingy\StartLoc.grp');
  }

  void _docChanged() {
    final doc = _doc!;
    // New tiles may need megatiles not decoded yet.
    final atlas = _atlas!;
    final missing = <int>{};
    for (final t in doc.tiles) {
      final m = doc.tileset.megatile(t);
      if (!atlas.has(m)) missing.add(m);
    }
    if (missing.isNotEmpty) atlas.ensure(missing).then((_) => mounted ? setState(() {}) : null);
    if (_selected != null && !doc.units.contains(_selected)) _selected = null;
    if (_name.text != doc.name) _name.text = doc.name;
    if (_description.text != doc.description) _description.text = doc.description;
    _minimapTimer?.cancel();
    _minimapTimer = Timer(const Duration(milliseconds: 250), _rebuildMinimap);
    setState(() {});
  }

  void _rebuildMinimap() {
    final doc = _doc, atlas = _atlas;
    if (doc == null || atlas == null || doc.revision == _minimapRevision) return;
    _minimapRevision = doc.revision;
    final px = Uint32List(doc.width * doc.height);
    for (int i = 0; i < px.length; ++i) {
      final c = atlas.averageColor[doc.tileset.megatile(doc.tiles[i])] ?? 0xff000000;
      px[i] = 0xff000000 | ((c & 0xff) << 16) | (c & 0xff00) | ((c >> 16) & 0xff); // ARGB to RGBA bytes
    }
    ui.decodeImageFromPixels(px.buffer.asUint8List(), doc.width, doc.height, ui.PixelFormat.rgba8888, (img) {
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _minimap?.dispose();
        _minimap = img;
      });
    });
  }

  // --- tools ---

  int get _pw => _doc!.width ~/ 2;

  /// Pair cells under a brush centered at [p].
  Set<int> _brushCells(Offset p) {
    final doc = _doc!;
    final n = _brushSize;
    final cx = (p.dx / 64 - n / 2).round(), cy = (p.dy / 32 - n).round();
    return {
      for (int y = cy; y < cy + 2 * n; ++y)
        for (int x = cx; x < cx + n; ++x)
          if (x >= 0 && y >= 0 && x < _pw && y < doc.height) y * _pw + x,
    };
  }

  int? _unitType() => switch (_tool) {
    EditorTool.start => ChkUnit.startLocation,
    EditorTool.mineral => _mineralType,
    EditorTool.geyser => ChkUnit.geyser,
    _ => null,
  };

  ChkUnit? _unitAt(Offset p) {
    final doc = _doc!;
    ChkUnit? best;
    for (final u in doc.units) {
      if (!(u.isResource || (u.isStart && u.owner < 8))) continue;
      final (w, h) = MapDocument.footprint(u.type);
      final r = Rect.fromCenter(center: Offset(u.x.toDouble(), u.y.toDouble()), width: w * 32.0, height: h * 32.0);
      if (r.contains(p) && (best == null || u.isStart)) best = u;
    }
    return best;
  }

  void _onDown(Offset p) {
    final doc = _doc;
    if (doc == null || _blending) return;
    _focus.requestFocus();
    switch (_tool) {
      case EditorTool.select:
        final u = _unitAt(p);
        setState(() {
          _selected = u;
          _amount.text = u != null && u.isResource ? '${u.resources}' : '';
        });
        if (u != null) {
          _dragFrom = p;
          _dragOrigin = (u.x, u.y);
          _dragged = false;
        }
      case EditorTool.terrain:
        if (_brushTerrain < 0) return;
        setState(() => _stroke.addAll(_brushCells(p)));
      case EditorTool.tile:
        final tx = p.dx ~/ 32, ty = p.dy ~/ 32;
        if (tx < 0 || ty < 0 || tx >= doc.width || ty >= doc.height) return;
        if (HardwareKeyboard.instance.isAltPressed) {
          setState(() => _tileValue = doc.tileAt(tx, ty));
          return;
        }
        setState(() => _tileStroke[ty * doc.width + tx] = _tileValue);
      case EditorTool.start:
      case EditorTool.mineral:
      case EditorTool.geyser:
        _place(p);
    }
  }

  void _onMove(Offset p) {
    final doc = _doc;
    if (doc == null) return;
    setState(() => _hover = p);
    switch (_tool) {
      case EditorTool.select:
        final u = _selected, from = _dragFrom;
        if (u == null || from == null) return;
        if (!_dragged && (p - from).distance < 8) return;
        if (!_dragged) doc.checkpoint();
        _dragged = true;
        final (tx, ty) = MapDocument.snap(u.type, _dragOrigin!.$1 + p.dx - from.dx, _dragOrigin!.$2 + p.dy - from.dy);
        final (x, y) = MapDocument.centerAt(u.type, tx, ty);
        if (x != u.x || y != u.y) doc.moveUnit(u, x, y);
      case EditorTool.terrain:
        if (_stroke.isEmpty) return;
        setState(() => _stroke.addAll(_brushCells(p)));
      case EditorTool.tile:
        if (_tileStroke.isEmpty) return;
        final tx = p.dx ~/ 32, ty = p.dy ~/ 32;
        if (tx < 0 || ty < 0 || tx >= doc.width || ty >= doc.height) return;
        setState(() => _tileStroke[ty * doc.width + tx] = _tileValue);
      default:
        break;
    }
  }

  void _onUp() {
    final doc = _doc;
    if (doc == null) return;
    switch (_tool) {
      case EditorTool.select:
        final u = _selected;
        if (u != null && _dragged) {
          final (fw, fh) = MapDocument.footprint(u.type);
          final tx = (u.x - fw * 16) ~/ 32, ty = (u.y - fh * 16) ~/ 32;
          final problem = doc.placementProblem(u.type, tx, ty, ignore: u);
          if (problem != null) {
            doc.moveUnit(u, _dragOrigin!.$1, _dragOrigin!.$2);
            _tell('$problem: moved back.');
          }
        }
        _dragFrom = null;
        _dragged = false;
      case EditorTool.terrain:
        if (_stroke.isNotEmpty) _paintStroke();
      case EditorTool.tile:
        if (_tileStroke.isNotEmpty) {
          doc.checkpoint();
          doc.setTiles(Map.of(_tileStroke));
          setState(_tileStroke.clear);
        }
      default:
        break;
    }
  }

  Future<void> _paintStroke() async {
    final doc = _doc!;
    final terrain = _terrains[_brushTerrain];
    final cells = Set<int>.of(_stroke);
    final value = pairValue(terrain.left, terrain.right);
    doc.checkpoint();
    Map<int, int> pairs;
    int failed = 0;
    if (_autoEdges && !_learning && _worker != null) {
      setState(() => _blending = true);
      try {
        // Start locations and resources keep the ground they stand on.
        final keep = <int>{};
        for (final u in doc.units) {
          if (!(u.isResource || u.isStart)) continue;
          final (w, h) = MapDocument.footprint(u.type);
          final tx = (u.x - w * 16) ~/ 32, ty = (u.y - h * 16) ~/ 32;
          for (int y = ty; y < ty + h; ++y) {
            for (int x = tx; x < tx + w; ++x) {
              if (x >= 0 && y >= 0 && x < doc.width && y < doc.height) keep.add(y * _pw + x ~/ 2);
            }
          }
        }
        final r = await _worker!.blend(pairGrid(doc.tiles, doc.width, doc.height), _pw, doc.height, {for (final c in cells) c: {value}}, keep);
        pairs = r.changed;
        failed = r.failed;
      } catch (e) {
        pairs = {for (final c in cells) c: value};
        failed = 1;
      }
      if (!mounted) return;
      setState(() => _blending = false);
    } else {
      pairs = {for (final c in cells) c: value};
    }
    final changes = <int, int>{};
    pairs.forEach((c, v) {
      final x = (c % _pw) * 2, y = c ~/ _pw;
      final (l, r) = pairTiles(v, doc.tileset.variations, _rng);
      changes[y * doc.width + x] = l;
      changes[y * doc.width + x + 1] = r;
    });
    doc.setTiles(changes);
    setState(_stroke.clear);
    if (failed > 0) _tell('Some edges could not be blended here; the terrain was placed as painted.');
  }

  void _place(Offset p) {
    final doc = _doc!;
    final type = _unitType()!;
    final (tx, ty) = MapDocument.snap(type, p.dx, p.dy);
    final problem = doc.placementProblem(type, tx, ty);
    if (problem != null) {
      _tell(problem);
      return;
    }
    final (x, y) = MapDocument.centerAt(type, tx, ty);
    if (type == ChkUnit.startLocation && doc.freePlayer == null) {
      _tell('All eight players have a start location.');
      return;
    }
    doc.checkpoint();
    final u = type == ChkUnit.startLocation
        ? doc.addStart(x, y)
        : doc.addResource(type, x, y, type == ChkUnit.geyser ? _gasAmount : _mineralAmount);
    setState(() => _selected = u);
  }

  void _deleteSelected() {
    final u = _selected, doc = _doc;
    if (u == null || doc == null) return;
    doc.checkpoint();
    doc.removeUnit(u);
    setState(() => _selected = null);
  }

  CanvasOverlay _overlay() {
    final doc = _doc!;
    Rect? ghost;
    bool ok = true;
    final h = _hover;
    final type = _unitType();
    if (h != null && type != null) {
      final (tx, ty) = MapDocument.snap(type, h.dx, h.dy);
      final (w, hh) = MapDocument.footprint(type);
      ghost = Rect.fromLTWH(tx * 32.0, ty * 32.0, w * 32.0, hh * 32.0);
      ok = doc.placementProblem(type, tx, ty) == null && (type != ChkUnit.startLocation || doc.freePlayer != null);
    } else if (h != null && _tool == EditorTool.terrain && _stroke.isEmpty) {
      final cells = _brushCells(h);
      if (cells.isNotEmpty) {
        final xs = cells.map((c) => c % _pw), ys = cells.map((c) => c ~/ _pw);
        ghost = Rect.fromLTRB(xs.reduce(math.min) * 64.0, ys.reduce(math.min) * 32.0, (xs.reduce(math.max) + 1) * 64.0, (ys.reduce(math.max) + 1) * 32.0);
      }
    } else if (h != null && _tool == EditorTool.tile) {
      ghost = Rect.fromLTWH((h.dx ~/ 32) * 32.0, (h.dy ~/ 32) * 32.0, 32, 32);
    }
    final strokeColor = _brushTerrain >= 0 && _brushTerrain < _terrains.length ? _terrains[_brushTerrain].color(_atlas!, doc.tileset) : Colors.blue;
    return CanvasOverlay(
      strokeCells: _stroke,
      strokeColor: strokeColor,
      ghost: ghost,
      ghostOk: ok,
      selected: _selected,
      grid: _grid,
    );
  }

  void _tell(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  // --- saving ---

  Future<void> _save() async {
    final doc = _doc;
    if (doc == null) return;
    _applyInfo();
    final problem = _saveProblem(doc);
    if (problem != null && !await _confirm('Save anyway?', problem, 'Save')) return;
    try {
      final path = await GameFiles.instance.saveMap(_map.key, doc.save());
      _map = GameMap(path);
      if (mounted) _tell('Saved ${_map.name}.');
    } catch (e) {
      if (mounted) _tell('Saving failed: $e');
    }
  }

  Future<void> _saveAs() async {
    final doc = _doc;
    if (doc == null) return;
    _applyInfo();
    final ext = _map.path.toLowerCase().endsWith('.scx') ? '.scx' : '.scm';
    final base = _map.name.replaceFirst(RegExp(r'^\(\d\)'), '');
    final suggested = '(${doc.starts.length})${doc.name.trim().isNotEmpty && doc.name != base ? doc.name.trim() : '$base copy'}';
    final file = await showDialog<String>(context: context, builder: (_) => _SaveAsDialog(initial: suggested, folder: _map.folder));
    if (file == null || file.trim().isEmpty || !mounted) return;
    final clean = file.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final rel = '${_map.folder.isEmpty ? 'maps' : _map.folder}/$clean$ext';
    final enginePath = '$gameDataDir/$rel';
    if (GameFiles.instance.exists(enginePath) && enginePath != _map.path) {
      if (!await _confirm('Replace it?', 'A map named "$clean" is already there.', 'Replace')) return;
    }
    final problem = _saveProblem(doc);
    if (problem != null && !await _confirm('Save anyway?', problem, 'Save')) return;
    try {
      final path = await GameFiles.instance.saveMap(rel, doc.save());
      setState(() => _map = GameMap(path));
      if (mounted) _tell('Saved as ${_map.name}.');
    } catch (e) {
      if (mounted) _tell('Saving failed: $e');
    }
  }

  String? _saveProblem(MapDocument doc) {
    final n = doc.starts.length;
    if (n < 2) return 'The map has $n start location${n == 1 ? '' : 's'}; a game needs at least two.';
    final named = RegExp(r'^\((\d)\)').firstMatch(_map.name);
    if (named != null && int.parse(named.group(1)!) != n) {
      return 'The file name says ${named.group(1)} players but the map has $n start locations. "Save as" can give it a matching name.';
    }
    return null;
  }

  Future<bool> _confirm(String title, String text, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
          ],
        ),
      ) ==
      true;

  void _applyInfo() {
    final doc = _doc;
    if (doc == null) return;
    if (_name.text != doc.name || _description.text != doc.description) {
      doc.checkpoint();
      doc.setInfo(_name.text, _description.text);
    }
  }

  Future<void> _close() async {
    final doc = _doc;
    _applyInfo();
    if (doc != null && doc.dirty && !await _confirm('Leave without saving?', 'Your changes to this map will be lost.', 'Leave')) return;
    if (mounted) Navigator.of(context).pop(true);
  }

  // --- layout ---

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    if (doc == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error == null) const CircularProgressIndicator(color: _green),
              const SizedBox(height: 16),
              Text(_error ?? 'Opening ${widget.map.name}...', style: TextStyle(color: _error == null ? _dim : const Color(0xFFFF6B5E))),
              if (_error != null) ...[
                const SizedBox(height: 16),
                FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Back')),
              ],
            ],
          ),
        ),
      );
    }
    final phone = MediaQuery.sizeOf(context).shortestSide < 500;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyZ, control: true): doc.undo,
          const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): doc.redo,
          const SingleActivator(LogicalKeyboardKey.keyY, control: true): doc.redo,
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
          const SingleActivator(LogicalKeyboardKey.delete): _deleteSelected,
          const SingleActivator(LogicalKeyboardKey.backspace): _deleteSelected,
          const SingleActivator(LogicalKeyboardKey.escape): () => setState(() => _selected = null),
        },
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              child: Row(
                children: [
                  _toolbar(),
                  Expanded(
                    child: Stack(
                      children: [
                        MapCanvas(
                          doc: doc,
                          atlas: _atlas!,
                          camera: _camera,
                          sprites: _sprites,
                          overlay: _overlay,
                          onDown: _onDown,
                          onMove: _onMove,
                          onUp: _onUp,
                          onHover: (p) => setState(() => _hover = p),
                        ),
                        if (_blending || _learning) Positioned(left: 12, top: 12, child: _status()),
                        if (_tool == EditorTool.tile)
                          Positioned(
                            right: 12,
                            bottom: 12,
                            child: OutlinedButton(onPressed: _pickTileUnderView, child: const Text('Pick the tile at the center')),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(width: phone ? 260 : 330, child: _panel()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _pickTileUnderView() {
    final doc = _doc!;
    final c = _camera.toMap(Offset(_camera.view.width / 2, _camera.view.height / 2));
    final tx = (c.dx ~/ 32).clamp(0, doc.width - 1), ty = (c.dy ~/ 32).clamp(0, doc.height - 1);
    setState(() => _tileValue = doc.tileAt(tx, ty));
  }

  Widget _status() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(color: const Color(0xDD000000), borderRadius: BorderRadius.circular(6), border: Border.all(color: _line)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: _green)),
        const SizedBox(width: 10),
        Text(_blending ? 'Fitting the edges...' : 'Learning this tileset\'s edges from your maps...', style: const TextStyle(color: _dim, fontSize: 12)),
      ],
    ),
  );

  Widget _toolbar() => Container(
    width: 56,
    color: _panelColor,
    child: Column(
      children: [
        const SizedBox(height: 8),
        IconButton(tooltip: 'Close the editor', icon: const Icon(Icons.arrow_back), onPressed: _close),
        const Divider(color: _line),
        for (final t in EditorTool.values)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: IconButton(
              tooltip: '${t.label}: ${t.help}',
              isSelected: _tool == t,
              color: _dim,
              selectedIcon: Icon(t.icon, color: _yellow),
              icon: Icon(t.icon),
              onPressed: () => setState(() {
                _tool = t;
                if (t != EditorTool.select) _selected = null;
              }),
            ),
          ),
        const Spacer(),
        IconButton(tooltip: 'Undo (Ctrl+Z)', icon: const Icon(Icons.undo), onPressed: _doc!.canUndo ? _doc!.undo : null),
        IconButton(tooltip: 'Redo (Ctrl+Y)', icon: const Icon(Icons.redo), onPressed: _doc!.canRedo ? _doc!.redo : null),
        IconButton(
          tooltip: 'Grid',
          isSelected: _grid,
          selectedIcon: const Icon(Icons.grid_4x4, color: _yellow),
          icon: const Icon(Icons.grid_4x4),
          onPressed: () => setState(() => _grid = !_grid),
        ),
        IconButton(
          tooltip: 'Whole map',
          icon: const Icon(Icons.fit_screen_outlined),
          onPressed: () => _camera.fit(Size(_doc!.width * 32.0, _doc!.height * 32.0)),
        ),
        const SizedBox(height: 8),
      ],
    ),
  );

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 14, 0, 6),
    child: Text(text.toUpperCase(), style: const TextStyle(fontSize: 11, letterSpacing: 1.6, color: _green, fontWeight: FontWeight.w700)),
  );

  Widget _panel() {
    final doc = _doc!;
    final minerals = doc.resources.where((u) => u.isMineral).toList();
    final geysers = doc.resources.where((u) => u.isGeyser).toList();
    return Container(
      color: _panelColor,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
        children: [
          Text(_map.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
          Text(
            '${doc.width} x ${doc.height}, ${_tilesetLabel(doc.tileset.name)}, ${doc.starts.length} start locations${doc.dirty ? ', not saved' : ''}',
            style: const TextStyle(fontSize: 12, color: _dim),
          ),
          const SizedBox(height: 10),
          _minimapView(),
          _heading(_tool.label),
          Text(_tool.help, style: const TextStyle(fontSize: 12, color: _dim)),
          const SizedBox(height: 8),
          ..._toolOptions(),
          _heading('Resources'),
          Text(
            '${minerals.length} mineral fields (${_sum(minerals)} minerals), ${geysers.length} geysers (${_sum(geysers)} gas)',
            style: const TextStyle(fontSize: 12, color: _dim),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (label, m, g) in resourceLevels)
                ActionChip(
                  label: Text(label, style: const TextStyle(fontSize: 12)),
                  tooltip: 'Every mineral field $m, every geyser $g',
                  onPressed: () {
                    doc.checkpoint();
                    doc.setAllAmounts(minerals: m, gas: g);
                    setState(() {
                      _mineralAmount = m;
                      _gasAmount = g;
                      if (_selected?.isResource == true) _amount.text = '${_selected!.resources}';
                    });
                  },
                ),
            ],
          ),
          _heading('Map'),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name in the game', isDense: true),
            onSubmitted: (_) => _applyInfo(),
            onTapOutside: (_) => _applyInfo(),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _description,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Description', isDense: true),
            onTapOutside: (_) => _applyInfo(),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save_outlined, size: 18), label: const Text('Save'))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton(onPressed: _saveAs, child: const Text('Save as...'))),
            ],
          ),
        ],
      ),
    );
  }

  static String _sum(List<ChkUnit> units) => '${units.fold<int>(0, (s, u) => s + u.resources)}';

  static String _tilesetLabel(String name) => switch (name) {
    'ashworld' => 'Ash World',
    'install' => 'Installation',
    'platform' => 'Space Platform',
    _ => name[0].toUpperCase() + name.substring(1),
  };

  Widget _minimapView() {
    final doc = _doc!;
    return AspectRatio(
      aspectRatio: doc.width / doc.height,
      child: LayoutBuilder(
        builder: (context, box) => GestureDetector(
          onTapDown: (d) => _camera.centerOn(Offset(d.localPosition.dx / box.maxWidth * doc.width * 32, d.localPosition.dy / box.maxHeight * doc.height * 32)),
          onPanUpdate: (d) => _camera.centerOn(Offset(d.localPosition.dx / box.maxWidth * doc.width * 32, d.localPosition.dy / box.maxHeight * doc.height * 32)),
          child: CustomPaint(painter: _MinimapPainter(doc, _minimap, _camera)),
        ),
      ),
    );
  }

  List<Widget> _toolOptions() {
    final doc = _doc!;
    switch (_tool) {
      case EditorTool.select:
        final u = _selected;
        if (u == null) return [const Text('Nothing selected.', style: TextStyle(color: _dim, fontSize: 12))];
        if (u.isStart) {
          return [
            Text('Start location of player ${u.owner + 1}', style: const TextStyle(color: Colors.white)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (int p = 0; p < 8; ++p)
                  ChoiceChip(
                    label: Text('P${p + 1}'),
                    selected: u.owner == p,
                    avatar: CircleAvatar(backgroundColor: editorPlayerColors[p], radius: 6),
                    onSelected: (_) {
                      doc.checkpoint();
                      doc.setStartPlayer(u, p);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: _deleteSelected, icon: const Icon(Icons.delete_outline, size: 18), label: const Text('Remove')),
          ];
        }
        return [
          Text(u.isGeyser ? 'Vespene geyser' : 'Mineral field', style: const TextStyle(color: Colors.white)),
          const SizedBox(height: 6),
          TextField(
            controller: _amount,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: u.isGeyser ? 'Gas' : 'Minerals', isDense: true),
            onSubmitted: (v) => _setAmount(u, v),
            onTapOutside: (_) => _setAmount(u, _amount.text),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: _deleteSelected, icon: const Icon(Icons.delete_outline, size: 18), label: const Text('Remove')),
        ];
      case EditorTool.terrain:
        return [
          if (_learning)
            const Text('Edges are filled in once learning ends; until then paint lands as is.', style: TextStyle(color: _dim, fontSize: 12))
          else if (_learnedMaps == 0)
            const Text('None of your maps use this tileset, so edges can\'t be filled in.', style: TextStyle(color: _dim, fontSize: 12))
          else
            Text('Edges learned from $_learnedMaps of your maps.', style: const TextStyle(color: _dim, fontSize: 12)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Fill in the edges'),
            value: _autoEdges,
            onChanged: (v) => setState(() => _autoEdges = v),
          ),
          Row(
            children: [
              const Text('Brush', style: TextStyle(fontSize: 12, color: _dim)),
              Expanded(
                child: Slider(value: _brushSize.toDouble(), min: 1, max: 8, divisions: 7, label: '$_brushSize', onChanged: (v) => setState(() => _brushSize = v.round())),
              ),
            ],
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (int i = 0; i < _terrains.length; ++i)
                Tooltip(
                  message: _terrains[i].label,
                  child: InkWell(
                    onTap: () => setState(() => _brushTerrain = i),
                    child: Container(
                      decoration: BoxDecoration(border: Border.all(color: i == _brushTerrain ? _yellow : _line, width: 2)),
                      child: _TileSwatch(atlas: _atlas!, megatile: doc.tileset.megatile(_terrains[i].left << 4 | doc.tileset.variations(_terrains[i].left).first), size: 44),
                    ),
                  ),
                ),
            ],
          ),
          if (_brushTerrain >= 0) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_terrains[_brushTerrain].label, style: const TextStyle(color: Colors.white, fontSize: 12))),
        ];
      case EditorTool.tile:
        return [
          Row(
            children: [
              _TileSwatch(atlas: _atlas!, megatile: doc.tileset.megatile(_tileValue), size: 56),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Group ${_tileValue >> 4}, variation ${_tileValue & 15}', style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              IconButton(
                tooltip: 'Previous group',
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _stepTile(-1),
              ),
              IconButton(tooltip: 'Next group', icon: const Icon(Icons.chevron_right), onPressed: () => _stepTile(1)),
              IconButton(
                tooltip: 'Next variation',
                icon: const Icon(Icons.shuffle),
                onPressed: () {
                  final vars = doc.tileset.variations(_tileValue >> 4);
                  final i = vars.indexOf(_tileValue & 15);
                  setState(() => _tileValue = (_tileValue & ~15) | vars[(i + 1) % vars.length]);
                },
              ),
            ],
          ),
        ];
      case EditorTool.start:
        final p = doc.freePlayer;
        return [Text(p == null ? 'All eight players have a start location.' : 'The next one is player ${p + 1}\'s.', style: const TextStyle(color: Colors.white, fontSize: 12))];
      case EditorTool.mineral:
        return [
          Wrap(
            spacing: 6,
            children: [
              for (final t in ChkUnit.mineralTypes)
                ChoiceChip(label: Text('Type ${t - 175}'), selected: _mineralType == t, onSelected: (_) => setState(() => _mineralType = t)),
            ],
          ),
          _amountField('Minerals per field', _mineralAmount, (v) => _mineralAmount = v),
        ];
      case EditorTool.geyser:
        return [_amountField('Gas per geyser', _gasAmount, (v) => _gasAmount = v)];
    }
  }

  Widget _amountField(String label, int value, void Function(int) set) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: TextFormField(
      key: ValueKey('$label$value'),
      initialValue: '$value',
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: label, isDense: true),
      onChanged: (v) => set((int.tryParse(v) ?? value).clamp(0, 65535)),
    ),
  );

  void _setAmount(ChkUnit u, String text) {
    final v = int.tryParse(text);
    final doc = _doc;
    if (v == null || doc == null || !doc.units.contains(u) || v == u.resources) return;
    doc.checkpoint();
    doc.setAmount(u, v.clamp(0, 65535));
    _amount.text = '${u.resources}';
  }

  void _stepTile(int dir) {
    final ts = _doc!.tileset;
    int g = _tileValue >> 4;
    for (int k = 0; k < ts.groupCount; ++k) {
      g = (g + dir) % ts.groupCount;
      if (g < 0) g += ts.groupCount;
      if (ts.groupType(g) != 0 && ts.megatile(g << 4 | ts.variations(g).first) != 0) break;
    }
    final v = g << 4 | ts.variations(g).first;
    _atlas!.ensure([ts.megatile(v)]).then((_) => mounted ? setState(() {}) : null);
    setState(() => _tileValue = v);
  }
}

/// A brush of the terrain tool: a plain terrain (same edge on all sides).
class _Terrain {
  final int left, right; // the pair's groups
  final String label;
  final bool water;
  const _Terrain(this.left, this.right, this.label, this.water);

  Color color(MegatileAtlas atlas, Tileset ts) {
    final c = atlas.averageColor[ts.megatile(left << 4 | ts.variations(left).first)] ?? 0xff3060ff;
    return Color(c);
  }

  static List<_Terrain> of(Tileset ts) {
    final out = <_Terrain>[];
    final height = ['Low', 'Middle', 'High'];
    final names = <String, int>{};
    for (final groups in ts.plainTerrains().values) {
      if (groups.length < 2) continue;
      final l = groups[0], r = groups[1];
      // Named by what the tiles are: walkable or not, and their level.
      final m = ts.megatile(l << 4 | ts.variations(l).first);
      int walk = 0, level = 0;
      for (int i = 0; i < 16; ++i) {
        final f = ts.minitileFlags(m, i);
        if (f & 1 != 0) walk++;
        if (f & 4 != 0) {
          level = 2;
        } else if (f & 2 != 0 && level < 1) {
          level = 1;
        }
      }
      final water = walk == 0 && level == 0;
      var label = walk == 0 ? (level == 0 ? (ts.name == 'platform' || ts.name == 'install' ? 'Space' : 'Water') : 'Blocked') : '${height[level]} ground';
      final n = (names[label] ?? 0) + 1;
      names[label] = n;
      if (n > 1) label = '$label $n';
      out.add(_Terrain(l, r, label, water && n == 1));
    }
    return out;
  }
}

class _TileSwatch extends StatelessWidget {
  final MegatileAtlas atlas;
  final int megatile;
  final double size;
  const _TileSwatch({required this.atlas, required this.megatile, required this.size});

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _SwatchPainter(atlas, megatile));
}

class _SwatchPainter extends CustomPainter {
  final MegatileAtlas atlas;
  final int megatile;
  _SwatchPainter(this.atlas, this.megatile);

  @override
  void paint(Canvas canvas, Size size) {
    if (!atlas.has(megatile)) return;
    final (page, src) = atlas.source(megatile);
    final img = page < atlas.pages.length ? atlas.pages[page] : null;
    if (img == null) return;
    canvas.drawImageRect(img, src, Offset.zero & size, Paint()..filterQuality = FilterQuality.low);
  }

  @override
  bool shouldRepaint(_SwatchPainter old) => true;
}

class _MinimapPainter extends CustomPainter {
  final MapDocument doc;
  final ui.Image? image;
  final EditorCamera cam;
  _MinimapPainter(this.doc, this.image, this.cam) : super(repaint: cam);

  @override
  void paint(Canvas canvas, Size size) {
    final img = image;
    if (img != null) {
      canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), Offset.zero & size, Paint()..filterQuality = FilterQuality.low);
    }
    final sx = size.width / (doc.width * 32), sy = size.height / (doc.height * 32);
    for (final u in doc.units) {
      final c = Offset(u.x * sx, u.y * sy);
      if (u.isStart && u.owner < 8) {
        canvas.drawRect(Rect.fromCenter(center: c, width: 7, height: 6), Paint()..color = editorPlayerColors[u.owner]);
      } else if (u.isResource) {
        canvas.drawRect(Rect.fromCenter(center: c, width: 2.5, height: 2), Paint()..color = u.isGeyser ? const Color(0xFF7CFC8C) : const Color(0xFF8CD8FF));
      }
    }
    final view = Rect.fromLTWH(cam.x * sx, cam.y * sy, cam.view.width / cam.zoom * sx, cam.view.height / cam.zoom * sy);
    canvas.drawRect(
      view,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_MinimapPainter old) => true;
}

class _SaveAsDialog extends StatefulWidget {
  final String initial;
  final String folder;
  const _SaveAsDialog({required this.initial, required this.folder});

  @override
  State<_SaveAsDialog> createState() => _SaveAsDialogState();
}

class _SaveAsDialogState extends State<_SaveAsDialog> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Save as a new map'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(controller: _c, autofocus: true, decoration: const InputDecoration(labelText: 'File name'), onSubmitted: (v) => Navigator.pop(context, v)),
        const SizedBox(height: 8),
        Text(
          'In ${widget.folder.isEmpty ? 'maps' : widget.folder}. Start the name with the number of players, like "(4)", so the start screen knows how many can play.',
          style: const TextStyle(fontSize: 12, color: _dim),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(context, _c.text), child: const Text('Save')),
    ],
  );
}
