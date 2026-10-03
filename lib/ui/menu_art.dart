// lib/ui/menu_art.dart
//
// The original game's menu look, read from the player's own game files
// (never bundled): the title screen, the main menu's planet, each race's
// room (the backgrounds of the original's race screens) and the menu
// button sounds. Loaded once per run with a short-lived engine; anything
// missing just leaves the plain black look.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../audio/sound_system.dart';
import '../engine/bw_engine.dart';
import '../game/game_data.dart';
import '../game/settings.dart';

class MenuArt {
  final ui.Image? title;
  final ui.Image? planet;
  final List<ui.Image?> races; // zerg, terran, protoss (the race ids)
  final Map<String, Uint8List> _sounds;

  MenuArt._(this.title, this.planet, this.races, this._sounds);

  static MenuArt? _instance;
  static Future<MenuArt?>? _loading;

  /// The art once loaded (null before, or when it couldn't be read).
  static MenuArt? get current => _instance;

  /// Loads it once; later calls get the same.
  static Future<MenuArt?> load() => _loading ??= _load().then((a) => _instance = a);

  static Future<MenuArt?> _load() async {
    BwEngine? e;
    try {
      e = await BwEngine.open();
      e.loadAssets(gameDataDir);
      Future<ui.Image?> pcx(String path) async {
        final r = e!.loadPcxRgba(path);
        if (r == null) return null;
        final (w, h, rgba) = r;
        final c = Completer<ui.Image>();
        ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
        return c.future;
      }

      final title = await pcx(r'glue\title\title.pcx');
      final planet = await pcx(r'glue\Palmm\Backgnd.pcx');
      final races = [await pcx(r'glue\PalRz\Backgnd.pcx'), await pcx(r'glue\PalRt\Backgnd.pcx'), await pcx(r'glue\PalRp\Backgnd.pcx')];
      final sounds = <String, Uint8List>{};
      for (final name in const ['mouseover', 'mousedown2', 'swishin']) {
        final bytes = e.readFile('sound\\glue\\$name.wav');
        if (bytes != null) sounds[name] = bytes;
      }
      return MenuArt._(title, planet, races, sounds);
    } catch (err) {
      debugPrint('Menu art not available: $err');
      return null;
    } finally {
      e?.dispose();
    }
  }

  /// The background behind the setup for [race] (the planet for random).
  ui.Image? backgroundFor(int race) => race >= 0 && race < races.length ? (races[race] ?? planet) : planet;

  // --- sounds ---

  final Map<String, AudioSource> _sources = {};
  int _lastHoverMs = 0;

  /// The original's menu sounds: 'mouseover' (pointer over a button),
  /// 'mousedown2' (a click), 'swishin' (a screen sliding in). Quiet when the
  /// player muted the game, and only once audio is running (browsers start
  /// it on the first click).
  Future<void> play(String name, {bool startAudio = false}) async {
    final settings = Settings.load();
    if (settings.muted) return;
    if (name == 'mouseover') {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastHoverMs < 60) return;
      _lastHoverMs = now;
    }
    if (startAudio) {
      if (!await SoundSystem.startAudio()) return;
    } else if (!SoLoud.instance.isInitialized) {
      return;
    }
    final bytes = _sounds[name];
    if (bytes == null) return;
    try {
      final source = _sources[name] ??= await SoLoud.instance.loadMem('glue_$name.wav', bytes);
      SoLoud.instance.play(source, volume: settings.volume * 0.8);
    } catch (_) {}
  }
}
