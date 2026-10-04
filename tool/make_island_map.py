#!/usr/bin/env python3
# tool/make_island_map.py
#
# Makes an island version of a land map: every start location and every
# expansion (a cluster of minerals and gas) gets its own island, separated
# by channels of deep water, keeping the rest of the original design.
#
#   tool/make_island_map.py <data_dir> <map.scm> <out.scm> "<name>"
#   e.g. tool/make_island_map.py ~/box/media/games/BROOD \
#          "$HOME/box/media/games/BROOD/maps/BroodWar/WebMaps/(8)Big Game Hunters.scm" \
#          "$HOME/box/media/games/BROOD/maps/Brood/(8)Big Game Islands.scm" "Big Game Islands"
#
# How: the engine's map tool (engine/tools/map_tool, built on demand) reads
# the map's scenario data and how the engine sees each tile. Every walkable
# tile goes to the island of the nearest start or resource cluster, by
# walking distance; where two islands meet, the tiles become the tileset's
# deep water (a channel two tiles wide at least, which ground units can't
# cross). Ground near resources and start locations is never touched.
# Doodad sprites left standing in the new water are removed. The result is
# written as a new map archive (the scenario stored uncompressed, which the
# game and OpenBW read like any other). Last, tool/blend_terrain.dart gives
# the channels proper shores and cliffs, as the map editor's terrain brush
# does (skipped with --no-blend, or when Dart isn't there: the channels then
# keep straight edges).
#
# Nothing of the original is changed; the new map is the player's own file.

import json
import os
import struct
import subprocess
import sys
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL_DIR = os.path.join(HERE, '..', 'engine', 'tools', 'map_tool')

FLAG_WALKABLE = 0x1
FLAG_UNWALKABLE = 0x4
FLAG_PARTIAL = 0x2000
FLAG_HEIGHT = 0x100 | 0x200 | 0x400


def map_tool():
    exe = os.path.join(TOOL_DIR, 'build', 'map_tool')
    if not os.path.exists(exe):
        subprocess.run(['cmake', '-S', TOOL_DIR, '-B', os.path.join(TOOL_DIR, 'build'), '-DCMAKE_BUILD_TYPE=Release'], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['cmake', '--build', os.path.join(TOOL_DIR, 'build'), '-j4'], check=True, stdout=subprocess.DEVNULL)
    return exe


# --- the scenario data (CHK): a list of tagged sections ----------------------------

def read_chk(data):
    sections = []
    i = 0
    while i + 8 <= len(data):
        tag = data[i:i + 4]
        size = struct.unpack_from('<i', data, i + 4)[0]
        body = data[i + 8:i + 8 + max(0, size)]
        sections.append([tag, bytearray(body)])
        i += 8 + max(0, size)
    return sections


def write_chk(sections):
    out = bytearray()
    for tag, body in sections:
        out += tag + struct.pack('<i', len(body)) + body
    return bytes(out)


def section(sections, tag):
    for s in sections:
        if s[0] == tag:
            return s
    return None


def set_name(sections, name):
    """Points the scenario's name (SPRP) at a new string."""
    sprp, strs = section(sections, b'SPRP'), section(sections, b'STR ')
    if not sprp or not strs:
        return
    body = strs[1]
    count = struct.unpack_from('<H', body, 0)[0]
    offsets = struct.unpack_from('<%dH' % count, body, 2)
    texts = []
    for off in offsets:
        end = body.index(0, off) if off < len(body) else off
        texts.append(bytes(body[off:end]) if off < len(body) else b'')
    texts.append(name.encode('latin-1'))
    count += 1
    out = bytearray(struct.pack('<H', count))
    pos = 2 + 2 * count
    data = bytearray()
    offs = []
    for t in texts:
        offs.append(pos + len(data))
        data += t + b'\0'
    out += struct.pack('<%dH' % count, *offs) + data
    strs[1] = out
    struct.pack_into('<H', sprp[1], 0, count)  # 1-based string index


# --- islands ---------------------------------------------------------------------

def make_islands(info, mtxm, protect_tiles=2, start_protect=6):
    W, H = info['width'], info['height']
    flags = [f for _, f in info['tiles']]
    walk = [bool(f & FLAG_WALKABLE) or bool(f & FLAG_PARTIAL) for f in flags]

    # Deep water: the most common fully unwalkable, low tile of the map.
    counts = {}
    for i, f in enumerate(flags):
        if f & FLAG_UNWALKABLE and not f & FLAG_WALKABLE and not f & FLAG_PARTIAL and not f & FLAG_HEIGHT:
            counts[mtxm[i]] = counts.get(mtxm[i], 0) + 1
    if not counts:
        raise SystemExit('this map has no water to copy')
    water = max(counts, key=counts.get)

    # Anchors: start locations (with their own minerals and gas), then
    # expansions (resource clusters; close ones share an island). Each
    # island grows from all of its seeds, so its resources lie inside it.
    starts = [(x // 32, y // 32) for _, x, y in info['starts']]
    res = [(x // 32, y // 32) for _, x, y in info['resources']]
    anchors = list(starts)
    seeds = [[p] for p in starts]
    rest = []
    for rx, ry in res:
        near_start = [k for k, (ax, ay) in enumerate(starts) if abs(ax - rx) <= 14 and abs(ay - ry) <= 14]
        if near_start:
            seeds[near_start[0]].append((rx, ry))
        else:
            rest.append((rx, ry))
    # Expansions: resources linked to one another within 10 tiles.
    parent = list(range(len(rest)))

    def root(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for a in range(len(rest)):
        for b in range(a + 1, len(rest)):
            if abs(rest[a][0] - rest[b][0]) <= 10 and abs(rest[a][1] - rest[b][1]) <= 10:
                parent[root(a)] = root(b)
    groups = {}
    for a, p in enumerate(rest):
        groups.setdefault(root(a), []).append(p)
    for members in groups.values():
        anchors.append((sum(p[0] for p in members) // len(members), sum(p[1] for p in members) // len(members)))
        seeds.append(members)

    # Each walkable tile to the nearest seed, walking (8 directions).
    cell = [-1] * (W * H)
    q = deque()
    for k, group in enumerate(seeds):
        for sx, sy in group:
            for r in range(0, 4):
                found = None
                for dy in range(-r, r + 1):
                    for dx in range(-r, r + 1):
                        x, y = sx + dx, sy + dy
                        if found is None and 0 <= x < W and 0 <= y < H and walk[y * W + x] and cell[y * W + x] < 0:
                            found = (x, y)
                if found:
                    cell[found[1] * W + found[0]] = k
                    q.append(found)
                    break
    while q:
        x, y = q.popleft()
        k = cell[y * W + x]
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < W and 0 <= ny < H and walk[ny * W + nx] and cell[ny * W + nx] < 0:
                cell[ny * W + nx] = k
                q.append((nx, ny))

    # Never under bases: around resources and start locations.
    protected = [False] * (W * H)
    for (px, py), r in [(p, protect_tiles) for p in res] + [(a, start_protect) for a in starts]:
        for y in range(max(0, py - r), min(H, py + r + 1)):
            for x in range(max(0, px - r), min(W, px + r + 1)):
                protected[y * W + x] = True

    # Channels: a tile next to (8 directions) another island's tile.
    new = list(mtxm)
    changed = 0
    for y in range(H):
        for x in range(W):
            i = y * W + x
            if cell[i] < 0 or protected[i]:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < W and 0 <= ny < H and cell[ny * W + nx] >= 0 and cell[ny * W + nx] != cell[i]:
                    new[i] = water
                    changed += 1
                    break
    return new, water, anchors, cell, changed


def check_islands(info, new, water, anchors, W, H):
    """Walkable land after the change, as connected pieces: which anchors share one."""
    flags = [f for _, f in info['tiles']]
    land = [new[i] != water and (flags[i] & FLAG_WALKABLE or flags[i] & FLAG_PARTIAL) for i in range(W * H)]
    piece = [-1] * (W * H)
    n = 0
    for s in range(W * H):
        if not land[s] or piece[s] >= 0:
            continue
        piece[s] = n
        q = deque([s])
        while q:
            i = q.popleft()
            x, y = i % W, i // W
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
                nx, ny = x + dx, y + dy
                j = ny * W + nx
                if 0 <= nx < W and 0 <= ny < H and land[j] and piece[j] < 0:
                    # Diagonal steps between two blocked tiles don't count.
                    if dx and dy and not (land[y * W + nx] or land[ny * W + x]):
                        continue
                    piece[j] = n
                    q.append(j)
        n += 1
    shared = {}
    for k, (ax, ay) in enumerate(anchors):
        best = None
        for r in range(6):
            for dy in range(-r, r + 1):
                for dx in range(-r, r + 1):
                    x, y = ax + dx, ay + dy
                    if best is None and 0 <= x < W and 0 <= y < H and piece[y * W + x] >= 0:
                        best = piece[y * W + x]
        shared.setdefault(best, []).append(k)
    return [v for k, v in shared.items() if len(v) > 1]


# --- the map archive (MPQ) ---------------------------------------------------------

def crypt_table():
    t = [0] * 0x500
    seed = 0x00100001
    for i in range(0x100):
        j = i
        for _ in range(5):
            seed = (seed * 125 + 3) % 0x2AAAAB
            a = (seed & 0xFFFF) << 0x10
            seed = (seed * 125 + 3) % 0x2AAAAB
            t[j] = a | (seed & 0xFFFF)
            j += 0x100
    return t


CRYPT = crypt_table()


def hash_string(s, kind):
    seed1, seed2 = 0x7FED7FED, 0xEEEEEEEE
    for ch in s.upper().encode('latin-1'):
        seed1 = (CRYPT[(kind << 8) + ch] ^ (seed1 + seed2)) & 0xFFFFFFFF
        seed2 = (ch + seed1 + seed2 + (seed2 << 5) + 3) & 0xFFFFFFFF
    return seed1


def encrypt(words, key):
    seed = 0xEEEEEEEE
    out = []
    for v in words:
        seed = (seed + CRYPT[0x400 + (key & 0xFF)]) & 0xFFFFFFFF
        out.append((v ^ (key + seed)) & 0xFFFFFFFF)
        key = (((~key << 0x15) + 0x11111111) | (key >> 0x0B)) & 0xFFFFFFFF
        seed = (v + seed + (seed << 5) + 3) & 0xFFFFFFFF
    return out


def write_mpq(path, files):
    """files: [(name, bytes)]. Each stored in 4096-byte sectors, not
    compressed (flagged as compressed with every sector stored raw, the form
    OpenBW reads), tables encrypted as usual."""
    sector = 4096
    header_size = 32
    blocks = []
    data = bytearray()
    for name, content in files:
        content = bytes(content)
        if len(content) % sector == 0:
            raise SystemExit('%s: size is a multiple of the sector size' % name)
        n = (len(content) + sector - 1) // sector
        offsets = [4 * (n + 1)]
        for k in range(n):
            offsets.append(offsets[-1] + len(content[k * sector:(k + 1) * sector]))
        start = header_size + len(data)
        data += struct.pack('<%dI' % (n + 1), *offsets) + content
        blocks.append((start, offsets[-1], len(content), 0x80000000 | 0x200))
    hash_size = 16
    while hash_size < 2 * len(files):
        hash_size *= 2
    table = [(0xFFFFFFFF, 0xFFFFFFFF, 0xFFFF, 0xFFFF, 0xFFFFFFFF)] * hash_size
    for b, (name, _) in enumerate(files):
        i = hash_string(name, 0) % hash_size
        while table[i][4] != 0xFFFFFFFF:
            i = (i + 1) % hash_size
        table[i] = (hash_string(name, 1), hash_string(name, 2), 0, 0, b)
    hash_words = []
    for h1, h2, loc, plat, blk in table:
        hash_words += [h1, h2, loc | (plat << 16), blk]
    block_words = []
    for b in blocks:
        block_words += list(b)
    hash_offset = header_size + len(data)
    block_offset = hash_offset + 16 * hash_size
    total = block_offset + 16 * len(blocks)
    out = bytearray(b'MPQ\x1a')
    out += struct.pack('<IIHHIIII', header_size, total, 0, 3, hash_offset, block_offset, hash_size, len(blocks))
    out += data
    out += struct.pack('<%dI' % len(hash_words), *encrypt(hash_words, hash_string('(hash table)', 3)))
    out += struct.pack('<%dI' % len(block_words), *encrypt(block_words, hash_string('(block table)', 3)))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(out)


# --- doodads ------------------------------------------------------------------------

def drop_sprites_in_water(sections, new, water, W):
    """THG2 sprites (doodads) standing on tiles that became water."""
    s = section(sections, b'THG2')
    if not s:
        return 0
    body = s[1]
    keep = bytearray()
    dropped = 0
    for i in range(0, len(body) - len(body) % 10, 10):
        _, x, y = struct.unpack_from('<HHH', body, i)
        t = (y // 32) * W + (x // 32)
        if 0 <= t < len(new) and new[t] == water:
            dropped += 1
            continue
        keep += body[i:i + 10]
    s[1] = keep
    return dropped


def main():
    args = [a for a in sys.argv[1:] if a != '--no-blend']
    blend = '--no-blend' not in sys.argv
    if len(args) != 4:
        print('usage: make_island_map.py [--no-blend] <data_dir> <map> <out> <name>')
        sys.exit(2)
    data_dir, src, out, name = args
    tool = map_tool()
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    tmp = out + '.tmp'
    subprocess.run([tool, 'extract', src, tmp + '.chk'], check=True)
    subprocess.run([tool, 'info', data_dir.rstrip('/') + '/', src, tmp + '.json'], check=True)
    chk = open(tmp + '.chk', 'rb').read()
    info = json.load(open(tmp + '.json'))
    W, H = info['width'], info['height']
    sections = read_chk(chk)
    mtxm_s = section(sections, b'MTXM')
    mtxm = list(struct.unpack_from('<%dH' % (W * H), mtxm_s[1], 0))
    new, water, anchors, cell, changed = make_islands(info, mtxm)
    joined = check_islands(info, new, water, anchors, W, H)
    if joined:
        print('Warning: still joined by land:', joined)
    mtxm_s[1] = bytearray(struct.pack('<%dH' % (W * H), *new))
    tile = section(sections, b'TILE')
    if tile:
        tile[1] = bytearray(struct.pack('<%dH' % (W * H), *new))
    dropped = drop_sprites_in_water(sections, new, water, W)
    set_name(sections, name)
    data = write_chk(sections)
    if len(data) % 4096 == 0:
        sections.append([b'PAD ', bytearray(4)])
        data = write_chk(sections)
    cut = out + '.cut.scm' if blend else out
    write_mpq(cut, [('staredit\\scenario.chk', data), ('(listfile)', b'staredit\\scenario.chk\r\n')])
    for f in (tmp + '.chk', tmp + '.json'):
        os.remove(f)
    if blend:
        try:
            subprocess.run(['dart', 'run', os.path.join(HERE, 'blend_terrain.dart'), data_dir, src, cut, out],
                           check=True, cwd=os.path.join(HERE, '..'))
            os.remove(cut)
        except (OSError, subprocess.CalledProcessError) as e:
            print('Blending the shores failed (%s); keeping straight channels.' % e)
            os.replace(cut, out)
    print('%s: %d islands, %d tiles turned to water (tile %d), %d doodads removed%s' %
          (out, len(anchors), changed, water, dropped, '' if not joined else ', some still joined'))


if __name__ == '__main__':
    main()
