// lib/ui/data_setup_screen.dart
//
// First start in the browser or on Android: the game files the build
// carries are copied in (the APK's, or the page's gamedata/ folder), else the
// player picks their game folder once. The files are kept by the browser
// (IndexedDB) or copied into the app's own storage, and nothing is uploaded
// anywhere.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../game/game_data.dart';
import 'start_screen.dart';

const _dim = Color(0xFF8C8C8C);
const _faint = Color(0xFF5E5E5E);
const _line = Color(0xFF2A2A2A);

class DataSetupScreen extends StatefulWidget {
  const DataSetupScreen({super.key});

  @override
  State<DataSetupScreen> createState() => _DataSetupScreenState();
}

// Set only for automated browser tests (--dart-define=BROOD_TEST_DATA=<url>):
// the game files come from the test server instead of a file dialog.
const _testData = String.fromEnvironment('BROOD_TEST_DATA');

class _DataSetupScreenState extends State<DataSetupScreen> {
  bool _busy = false;
  int _done = 0, _total = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_testData.isNotEmpty) return _importFrom(_testData);
      // The game files the app carries (Android).
      if (await GameFiles.instance.hasBundled() && mounted) return _importBundled();
      // Opened from the home server (tool/brood_server.dart), which has the
      // game files: load them from there, nothing to choose.
      final base = await GameFiles.instance.serverFiles();
      if (base != null && mounted) await _importFrom(base);
    });
  }

  Future<void> _importBundled() async {
    setState(() => _busy = true);
    final error = await GameFiles.instance.importBundled((done, total) {
      if (mounted) {
        setState(() {
          _done = done;
          _total = total;
        });
      }
    });
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const StartScreen()));
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  Future<void> _importFrom(String base) async {
    setState(() => _busy = true);
    final error = await GameFiles.instance.importFromUrl(base, (done, total) {
      if (mounted) {
        setState(() {
          _done = done;
          _total = total;
        });
      }
    });
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const StartScreen()));
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  Future<void> _choose({required bool folder}) async {
    setState(() {
      _busy = true;
      _error = null;
      _done = _total = 0;
    });
    final error = await GameFiles.instance.pickAndImport((done, total) {
      if (mounted) {
        setState(() {
          _done = done;
          _total = total;
        });
      }
    }, folder: folder);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const StartScreen()));
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Container(
          width: 560,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            border: Border.all(color: _line),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Brood',
                style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: Colors.white),
              ),
              const SizedBox(height: 16),
              const Text(
                'Brood plays with your own copy of StarCraft: Brood War. Choose its folder: the one with '
                'StarDat.mpq, BrooDat.mpq, Patch_rt.mpq and the maps folder.',
                style: TextStyle(fontSize: 15, height: 1.4),
              ),
              const SizedBox(height: 10),
              Text(
                kIsWeb
                    ? 'The files are kept in this browser and never leave your computer. You only do this once.'
                    : 'The files are copied into the app (about 115 MB) and never leave your device. You only do this once. '
                          'You can also copy the folder over USB to Android/data/dev.x1watt.brood/files/BROOD.',
                style: const TextStyle(fontSize: 13, color: _dim, height: 1.4),
              ),
              const SizedBox(height: 24),
              if (_busy) ...[
                LinearProgressIndicator(value: _total == 0 ? null : _done / _total, color: Colors.white, backgroundColor: _line),
                const SizedBox(height: 10),
                Text(_total == 0 ? 'Waiting for your choice...' : 'Copying $_done of $_total files...', style: const TextStyle(color: _dim)),
              ] else ...[
                FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: () => _choose(folder: true),
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Choose the game folder'),
                ),
                if (kIsWeb) const SizedBox(height: 10),
                if (kIsWeb)
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                    onPressed: () => _choose(folder: false),
                    child: const Text('Or pick the files one by one (the three .mpq files and some maps)'),
                  ),
              ],
              if (_error != null) ...[const SizedBox(height: 14), Text(_error!, style: const TextStyle(color: Color(0xFFFF6B5E)))],
              const SizedBox(height: 18),
              const Text('Brood is not affiliated with Blizzard Entertainment.', style: TextStyle(fontSize: 11, color: _faint)),
            ],
          ),
        ),
      ),
    );
  }
}
