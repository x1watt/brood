// The struct offsets in lib/engine/bw_engine.dart (class L) against the C
// layout as ffigen generated it from bw_bridge.h: fields are written through
// the generated structs and read back at L's offsets.

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:brood/engine/bw_bridge_gen.dart';
import 'package:brood/engine/bw_engine.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

ByteData _bytes(ffi.Pointer p, int n) => ByteData.sublistView(p.cast<ffi.Uint8>().asTypedList(n));

void main() {
  test('struct sizes match', () {
    expect(ffi.sizeOf<bw_game_setup>(), L.setupSize);
    expect(ffi.sizeOf<bw_draw_item>(), L.drawSize);
    expect(ffi.sizeOf<bw_unit_info>(), L.unitSize);
    expect(ffi.sizeOf<bw_unit_type_info>(), L.typeSize);
    expect(ffi.sizeOf<bw_tech_info>(), L.techSize);
    expect(ffi.sizeOf<bw_upgrade_info>(), L.upgradeSize);
    expect(ffi.sizeOf<bw_sound_event>(), L.soundEventSize);
    expect(ffi.sizeOf<bw_sound_info>(), L.soundInfoSize);
    expect(ffi.sizeOf<bw_alliance_player>(), L.allianceSize);
    expect(ffi.sizeOf<bw_alliance_event>(), L.allianceEventSize);
  });

  test('field offsets match', () {
    final s = calloc<bw_game_setup>();
    s.ref.player_count = 3;
    s.ref.controller[1] = 11;
    s.ref.race[2] = 22;
    s.ref.team[7] = 33;
    s.ref.seed = 0xdeadbeef;
    final sd = _bytes(s, L.setupSize);
    expect(sd.getInt32(L.setupCount, Endian.little), 3);
    expect(sd.getInt32(L.setupController + 4, Endian.little), 11);
    expect(sd.getInt32(L.setupRace + 8, Endian.little), 22);
    expect(sd.getInt32(L.setupTeam + 28, Endian.little), 33);
    expect(sd.getUint32(L.setupSeed, Endian.little), 0xdeadbeef);
    calloc.free(s);

    final u = calloc<bw_unit_info>();
    u.ref.queue_count = 4;
    u.ref.queue[3] = 99;
    u.ref.progress_permille = 500;
    u.ref.research_progress_permille = 7;
    u.ref.rally_unit_id = 1234;
    final ud = _bytes(u, L.unitSize);
    expect(ud.getInt32(L.unitQueueCount, Endian.little), 4);
    expect(ud.getInt32(L.unitQueue + 12, Endian.little), 99);
    expect(ud.getInt32(L.unitProgress, Endian.little), 500);
    expect(ud.getInt32(L.unitResearchProgress, Endian.little), 7);
    expect(ud.getInt32(L.unitRallyUnit, Endian.little), 1234);
    calloc.free(u);

    final t = calloc<bw_unit_type_info>();
    t.ref.name[0] = 65;
    t.ref.ready_sound = 5;
    t.ref.yes_last = 9;
    final td = _bytes(t, L.typeSize);
    expect(td.getUint8(L.typeName), 65);
    expect(td.getInt32(L.typeReadySound, Endian.little), 5);
    expect(td.getInt32(L.typeReadySound + 24, Endian.little), 9);
    calloc.free(t);

    final a = calloc<bw_alliance_player>();
    a.ref.gas_rate = 77;
    a.ref.points = 1 << 40;
    a.ref.own_points = 5;
    a.ref.kill_score = 6;
    final ad = _bytes(a, L.allianceSize);
    expect(ad.getInt32(20 * 4, Endian.little), 77);
    expect(ad.getInt64(L.alliancePoints, Endian.little), 1 << 40);
    expect(ad.getInt64(L.allianceOwnPoints, Endian.little), 5);
    expect(ad.getInt64(L.allianceKillScore, Endian.little), 6);
    calloc.free(a);

    final ti = calloc<bw_tech_info>();
    ti.ref.name[0] = 66;
    expect(_bytes(ti, L.techSize).getUint8(L.techName), 66);
    calloc.free(ti);
    final si = calloc<bw_sound_info>();
    si.ref.filename[0] = 67;
    expect(_bytes(si, L.soundInfoSize).getUint8(L.soundInfoName), 67);
    calloc.free(si);
  });
}
