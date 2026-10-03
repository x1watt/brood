// lib/audio/sound_system.dart
//
// Plays the game's own WAVs (loaded from the user's MPQs through the
// bridge) with the same rules as OpenBW's reference UI (ui/ui.h
// play_sound):
//   - volume = max(sound's min_volume, 99 - 99 * distance_off_screen / 512),
//     dropped if <= 10
//   - 8 channels; a sound takes a free one or steals the lowest-priority one
//     (never one whose sound has flag 0x20)
//   - flag 0x10: don't start while the same sound still plays
//   - flag 0x02: one such sound per unit type at a time
//   - the same sound isn't restarted within 80 ms
// WAVs are loaded lazily; a sound requested while still loading plays as
// soon as it's ready if that's within 300 ms, so the first unit reply isn't
// lost.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../engine/bw_engine_io.dart';
import '../engine/models.dart';

class _Channel {
  SoundHandle? handle;
  int soundId = -1;
  int priority = 0;
  int flags = 0;
  int unitTypeId = -1;
}

class SoundSystem {
  final BwEngine _engine;
  final List<_Channel> _channels = List.generate(8, (_) => _Channel());
  final Map<int, AudioSource?> _sources = {};
  final Map<int, Future<AudioSource?>> _loading = {};
  final Map<int, SoundInfo?> _infos = {};
  final Map<int, int> _lastPlayedMs = {};
  final math.Random _rng = math.Random();
  bool _ready = false;

  double _volume = 0.7;
  bool _muted = false;

  /// Master volume 0-1 (also affects sounds already playing).
  double get volume => _volume;
  set volume(double v) {
    _volume = v.clamp(0.0, 1.0);
    _applyGlobal();
  }

  bool get muted => _muted;
  set muted(bool m) {
    _muted = m;
    _applyGlobal();
  }

  void _applyGlobal() {
    if (_ready) SoLoud.instance.setGlobalVolume(_muted ? 0 : _volume);
  }

  SoundSystem(this._engine);

  Future<void> init() async {
    // BROOD_AUDIO_BACKEND=pulse|alsa forces a backend (e.g. so a test run can
    // be sent to a silent sink with PULSE_SINK); default lets miniaudio pick.
    final backend = switch (Platform.environment['BROOD_AUDIO_BACKEND']) {
      'pulse' => LinuxAudioBackend.pulseAudio,
      'alsa' => LinuxAudioBackend.alsa,
      _ => LinuxAudioBackend.auto,
    };
    if (Platform.environment['BROOD_MUTE'] == '1') _muted = true;
    try {
      await SoLoud.instance.init(linuxAudioBackend: backend);
      _ready = true;
      _applyGlobal();
    } catch (e) {
      debugPrint('Sound disabled: $e');
    }
  }

  void dispose() {
    if (_ready) SoLoud.instance.deinit();
  }

  SoundInfo? _info(int id) => _infos.putIfAbsent(id, () => _engine.soundInfo(id));

  Future<AudioSource?> _source(int id) {
    if (_sources.containsKey(id)) return Future.value(_sources[id]);
    return _loading.putIfAbsent(id, () async {
      AudioSource? source;
      try {
        final bytes = _engine.loadSound(id);
        if (bytes != null) source = await SoLoud.instance.loadMem('bw_sound_$id.wav', bytes);
      } catch (e) {
        debugPrint('Sound $id failed to load: $e');
      }
      _sources[id] = source;
      _loading.remove(id);
      return source;
    });
  }

  /// Plays sound [id]. [position] (map pixels) makes it quieter the further
  /// it is from [screen]. [ui] sounds (voice replies, advisor, buttons) play
  /// at full volume; non-positional engine sounds use their min_volume, as
  /// in the reference UI.
  void play(int id, {Offset? position, Rect? screen, int unitTypeId = -1, bool ui = false}) {
    if (!_ready || _muted || id < 0) return;
    final info = _info(id);
    if (info == null || info.filename.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - (_lastPlayedMs[id] ?? -1000) <= 80) return;
    _lastPlayedMs[id] = now;

    int vol = info.minVolume;
    if (position != null && screen != null) {
      double distance = 0;
      if (position.dx < screen.left) distance += screen.left - position.dx;
      if (position.dx > screen.right) distance += position.dx - screen.right;
      if (position.dy < screen.top) distance += screen.top - position.dy;
      if (position.dy > screen.bottom) distance += position.dy - screen.bottom;
      final distanceVolume = 99 - (99 * distance / 512).round();
      if (distanceVolume > vol) vol = distanceVolume;
    }
    if (ui) vol = 99;
    if (vol <= 10) return;

    final source = _sources[id];
    if (source != null) {
      _start(id, source, info, vol, unitTypeId);
    } else if (!_sources.containsKey(id)) {
      _source(id).then((s) {
        if (s != null && DateTime.now().millisecondsSinceEpoch - now < 300) _start(id, s, info, vol, unitTypeId);
      });
    }
  }

  bool _playing(_Channel c) {
    final h = c.handle;
    if (h == null) return false;
    if (SoLoud.instance.getIsValidVoiceHandle(h)) return true;
    c.handle = null;
    return false;
  }

  void _start(int id, AudioSource source, SoundInfo info, int vol, int unitTypeId) {
    if (info.flags & 0x10 != 0) {
      if (_channels.any((c) => c.soundId == id && _playing(c))) return;
    } else if (info.flags & 0x02 != 0 && unitTypeId >= 0) {
      if (_channels.any((c) => c.unitTypeId == unitTypeId && c.flags & 0x02 != 0 && _playing(c))) return;
    }

    _Channel? channel;
    for (final c in _channels) {
      if (!_playing(c)) {
        channel = c;
        break;
      }
    }
    if (channel == null) {
      var best = info.priority;
      for (final c in _channels) {
        if (c.flags & 0x20 != 0) continue;
        if (c.priority < best) {
          best = c.priority;
          channel = c;
        }
      }
      if (channel == null) return;
      final old = channel.handle;
      if (old != null) unawaited(SoLoud.instance.stop(old));
    }

    channel.handle = SoLoud.instance.play(source, volume: vol / 100);
    channel.soundId = id;
    channel.priority = info.priority;
    channel.flags = info.flags;
    channel.unitTypeId = unitTypeId;
  }

  /// Picks a random sound in [first]..[last] (inclusive); no-op if empty.
  void playRandom(int first, int last, {int unitTypeId = -1}) {
    if (first <= 0 || last < first) return;
    play(first + _rng.nextInt(last - first + 1), unitTypeId: unitTypeId, ui: true);
  }

  /// Plays everything the simulation queued since the last call.
  void drainEngine(Rect screen) {
    for (final e in _engine.pollSounds()) {
      play(
        e.soundId,
        position: e.hasPosition ? Offset(e.x.toDouble(), e.y.toDouble()) : null,
        screen: screen,
        unitTypeId: e.unitTypeId,
      );
    }
  }
}
