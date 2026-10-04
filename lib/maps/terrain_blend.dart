// lib/maps/terrain_blend.dart
//
// Fills the edges around painted terrain with the right transition tiles
// (shores around water, cliffs between levels, the layers in between), the
// way the original editor's terrain brushes do.
//
// Terrain tiles come in column pairs: a group on an even column is always
// followed by its partner on the odd one (the halves of the original
// editor's isometric diamonds). So the editor works on pair cells, 64x32
// pixels, whose value is (left group << 11) | right group.
//
// Which cells may sit next to which is learned from the player's own maps
// of the same tileset (all made with the original editor): for each of the
// eight directions, the pairs seen next to each pair, kept when seen a few
// times (rare ones are mistakes in some map). Painting forces the painted
// cells to the brush's terrain; the cells around them (a band a few cells
// wide) are then solved as a constraint problem: arc consistency, then a
// search that prefers each cell's current value and otherwise the most
// usual neighbors. If the band is too narrow for the needed layers it is
// widened. Doodads (groups 1024 and up) are never placed; next to the band
// they count as fitting anything.

import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

const int _doodad = 1024;

int pairValue(int left, int right) => (left << 11) | right;
int pairLeft(int v) => v >> 11;
int pairRight(int v) => v & 2047;
bool pairIsDoodad(int v) => pairLeft(v) >= _doodad || pairRight(v) >= _doodad;

/// Pair cell values of a map (tiles are (group << 4) | variation).
Int32List pairGrid(Uint16List tiles, int w, int h) {
  final pw = w ~/ 2;
  final out = Int32List(pw * h);
  for (int y = 0; y < h; ++y) {
    for (int x = 0; x < pw; ++x) {
      out[y * pw + x] = pairValue(tiles[y * w + 2 * x] >> 4, tiles[y * w + 2 * x + 1] >> 4);
    }
  }
  return out;
}

const List<(int, int)> _dirs = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (-1, 1), (1, -1)];

class BlendModel {
  /// counts[d][a][b]: how often b was at a's neighbor in direction d.
  final List<Map<int, Map<int, int>>> counts = List.generate(_dirs.length, (_) => HashMap<int, Map<int, int>>());
  final Map<int, int> freq = HashMap();
  int maps = 0;

  /// Adds a map's tiles; [weight] > 1 for the map being edited, whose own
  /// arrangements always count as fitting.
  void add(Uint16List tiles, int w, int h, {int weight = 1}) {
    final pw = w ~/ 2;
    final g = pairGrid(tiles, w, h);
    for (int y = 0; y < h; ++y) {
      for (int x = 0; x < pw; ++x) {
        final a = g[y * pw + x];
        freq[a] = (freq[a] ?? 0) + weight;
        for (int d = 0; d < _dirs.length; ++d) {
          final X = x + _dirs[d].$1, Y = y + _dirs[d].$2;
          if (X < 0 || Y < 0 || X >= pw || Y >= h) continue;
          final m = counts[d].putIfAbsent(a, () => HashMap<int, int>());
          final b = g[Y * pw + X];
          m[b] = (m[b] ?? 0) + weight;
        }
      }
    }
    maps++;
  }

  late final _solver = _Solver(this);

  /// Paints and blends. [forced] maps pair cells to the values they may
  /// take (the brush's terrain). Returns the new values of every cell that
  /// changed, and how many painted areas couldn't be blended (those get the
  /// brush's first value, unblended).
  BlendResult blend(Int32List grid, int pw, int h, Map<int, Set<int>> forced, {Set<int> keep = const {}}) =>
      _solver.run(grid, pw, h, forced, keep);
}

class BlendResult {
  final Map<int, int> changed; // pair cell -> value
  final int failed;
  const BlendResult(this.changed, this.failed);
}

class _Solver {
  final BlendModel model;
  static const int minPair = 3;
  static const int minFreq = 2;
  late final List<Map<int, Set<int>>> allowedSets;
  late final Set<int> all;

  _Solver(this.model) {
    allowedSets = [
      for (final m in model.counts)
        {
          for (final e in m.entries) e.key: {for (final b in e.value.entries) if (_common(e.key, b.key, b.value)) b.key},
        },
    ];
    all = {for (final e in model.freq.entries) if (e.value >= minFreq && !pairIsDoodad(e.key)) e.key};
  }

  /// Whether a pair seen [n] times next to each other is a real fit, not a
  /// slip in some map: a few times at least, and not vanishingly rare for
  /// the rarer of the two (plain floor next to space is seen here and there
  /// in maps, but never where an editor's brush made the edge).
  bool _common(int a, int b, int n) {
    if (n < minPair) return false;
    final fa = model.freq[a] ?? 0, fb = model.freq[b] ?? 0;
    return n * 2000 >= math.min(fa, fb);
  }

  Set<int> _allowed(int d, Set<int> dom) {
    final m = allowedSets[d];
    if (dom.length == 1) return m[dom.first] ?? const {};
    final out = <int>{};
    for (final v in dom) {
      final s = m[v];
      if (s != null) out.addAll(s);
    }
    return out;
  }

  BlendResult run(Int32List grid0, int pw, int h, Map<int, Set<int>> forced, Set<int> keep) {
    final grid = Int32List.fromList(grid0);
    final changed = <int, int>{};
    int failed = 0;
    final done = <int>{};
    for (final comp in _components(forced.keys.toSet(), pw)) {
      Map<int, int>? r;
      // The ground under units stays when it can; when that leaves no
      // way to blend, it may change too.
      for (final pinned in [keep, const <int>{}]) {
        for (final radius in const [2, 3, 4, 6, 8]) {
          final band = _ring(comp, radius, pw, h);
          final fixed = <int, Set<int>>{
            for (final c in comp) c: forced[c]!,
            for (final c in band) if (done.contains(c)) c: forced[c]!,
          };
          final free = band.where((c) => !fixed.containsKey(c) && !pinned.contains(c)).toSet();
          r = _solve(grid, pw, h, free, fixed);
          if (r != null) break;
        }
        if (r != null || keep.isEmpty) break;
      }
      if (r == null) {
        failed++;
        for (final c in comp) {
          final v = forced[c]!.first;
          if (grid[c] != v) {
            grid[c] = v;
            changed[c] = v;
          }
        }
      } else {
        _shrink(grid, pw, h, r, comp);
        for (final e in r.entries) {
          if (grid[e.key] != e.value) {
            grid[e.key] = e.value;
            changed[e.key] = e.value;
          }
        }
      }
      done.addAll(comp);
    }
    return BlendResult(changed, failed);
  }

  /// Puts back the original value of every changed cell that can have it
  /// again (all eight neighbors still fit), farthest from the painted area
  /// first: the solution only changes what it must.
  void _shrink(Int32List grid, int pw, int h, Map<int, int> r, Set<int> painted) {
    int at(int c) => r[c] ?? grid[c];
    bool fits(int c, int v) {
      final x = c % pw, y = c ~/ pw;
      for (int d = 0; d < _dirs.length; ++d) {
        final X = x + _dirs[d].$1, Y = y + _dirs[d].$2;
        if (X < 0 || Y < 0 || X >= pw || Y >= h) continue;
        final nv = at(Y * pw + X);
        if (pairIsDoodad(nv) || pairIsDoodad(v)) continue;
        if (!(allowedSets[d][v]?.contains(nv) ?? false)) return false;
      }
      return true;
    }

    int dist(int c) {
      final x = c % pw, y = c ~/ pw;
      int best = 1 << 30;
      for (final p in painted) {
        final d = math.max((p % pw - x).abs(), (p ~/ pw - y).abs());
        if (d < best) best = d;
      }
      return best;
    }

    final changed = [for (final e in r.entries) if (e.value != grid[e.key] && !painted.contains(e.key)) e.key];
    final far = {for (final c in changed) c: dist(c)};
    changed.sort((a, b) => far[b]!.compareTo(far[a]!));
    bool again = true;
    while (again) {
      again = false;
      for (final c in changed) {
        if (r[c] == grid[c]) continue;
        if (fits(c, grid[c])) {
          r[c] = grid[c];
          again = true;
        }
      }
    }
  }

  static List<Set<int>> _components(Set<int> cells, int pw) {
    final seen = <int>{};
    final out = <Set<int>>[];
    for (final c in cells) {
      if (!seen.add(c)) continue;
      final comp = <int>{};
      final stack = [c];
      while (stack.isNotEmpty) {
        final u = stack.removeLast();
        comp.add(u);
        for (final v in [u - 1, u + 1, u - pw, u + pw]) {
          if (cells.contains(v) && (v % pw - u % pw).abs() <= 1 && seen.add(v)) stack.add(v);
        }
      }
      out.add(comp);
    }
    return out;
  }

  static Set<int> _ring(Set<int> cells, int r, int pw, int h) {
    final out = <int>{};
    for (final c in cells) {
      final x = c % pw, y = c ~/ pw;
      for (int dy = -r; dy <= r; ++dy) {
        for (int dx = -r; dx <= r; ++dx) {
          final X = x + dx, Y = y + dy;
          if (X >= 0 && Y >= 0 && X < pw && Y < h) out.add(Y * pw + X);
        }
      }
    }
    return out..removeAll(cells);
  }

  Map<int, int>? _solve(Int32List grid, int pw, int h, Set<int> free, Map<int, Set<int>> fixed) {
    final dom = <int, Set<int>>{for (final c in free) c: Set<int>.of(all)};
    for (final e in fixed.entries) {
      dom[e.key] = Set<int>.of(e.value);
    }
    final vars = dom.keys.toList();

    Iterable<(int, int)> nbrs(int c) sync* {
      final x = c % pw, y = c ~/ pw;
      for (int d = 0; d < _dirs.length; ++d) {
        final X = x + _dirs[d].$1, Y = y + _dirs[d].$2;
        if (X >= 0 && Y >= 0 && X < pw && Y < h) yield (Y * pw + X, d);
      }
    }

    bool propagate(Map<int, Set<int>> dom, Set<int> queue) {
      while (queue.isNotEmpty) {
        final c = queue.first;
        queue.remove(c);
        final cd = dom[c];
        if (cd == null && pairIsDoodad(grid[c])) continue; // doodads fit anything
        // An unconstrained cell allows nearly anything: nothing to prune.
        if (cd != null && cd.length == all.length && free.contains(c)) continue;
        final source = cd ?? {grid[c]};
        for (final (n, d) in nbrs(c)) {
          final nd = dom[n];
          if (nd == null) continue;
          final ok = _allowed(d, source);
          final before = nd.length;
          nd.retainWhere(ok.contains);
          if (nd.isEmpty) return false;
          if (nd.length < before) queue.add(n);
        }
      }
      return true;
    }

    final start = <int>{...vars};
    for (final c in vars) {
      for (final (n, _) in nbrs(c)) {
        if (!dom.containsKey(n)) start.add(n);
      }
    }
    if (!propagate(dom, start)) return null;

    int score(int c, int v, Map<int, Set<int>> dom) {
      int s = v == grid[c] ? 1000000000000 : 0; // keep what is there
      for (final (n, d) in nbrs(c)) {
        final nd = dom[n];
        if (nd != null && nd.length != 1) continue;
        final nv = nd?.first ?? grid[n];
        if (pairIsDoodad(nv)) continue;
        s += model.counts[d][v]?[nv] ?? 0;
      }
      return s;
    }

    int nodes = 0;
    Map<int, Set<int>>? search(Map<int, Set<int>> dom) {
      if (++nodes > 4000) return null;
      int? best;
      for (final c in vars) {
        final l = dom[c]!.length;
        if (l > 1 && (best == null || l < dom[best]!.length)) best = c;
      }
      if (best == null) return dom;
      final c = best;
      final options = dom[c]!.toList();
      final scores = {for (final v in options) v: score(c, v, dom)};
      options.sort((a, b) => scores[b]!.compareTo(scores[a]!));
      for (final v in options.take(8)) {
        final next = {for (final e in dom.entries) e.key: e.key == c ? {v} : Set<int>.of(e.value)};
        if (propagate(next, {c})) {
          final r = search(next);
          if (r != null) return r;
        }
      }
      return null;
    }

    final r = search(dom);
    if (r == null) return null;
    return {for (final e in r.entries) e.key: e.value.first};
  }
}

/// Tile values for a pair cell's new value: a variation of each group
/// picked at random (the original editor does the same).
(int, int) pairTiles(int v, List<int> Function(int group) variations, math.Random rng) {
  final l = pairLeft(v), r = pairRight(v);
  final vl = variations(l), vr = variations(r);
  return ((l << 4) | vl[rng.nextInt(vl.length)], (r << 4) | vr[rng.nextInt(vr.length)]);
}
