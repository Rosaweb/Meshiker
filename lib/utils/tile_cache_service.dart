import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'settings_service.dart';

class TileCacheService extends ChangeNotifier {
  final SettingsService settingsService;
  double _currentSizeMb = 0.0;
  
  double get currentSizeMb => _currentSizeMb;

  TileCacheService({required this.settingsService});

  Future<void> init() async {
    await _calculateSize();
  }

  Future<void> _calculateSize() async {
    final dir = await getTemporaryDirectory();
    final cacheDir = Directory('${dir.path}/tile_cache');
    if (!await cacheDir.exists()) {
      _currentSizeMb = 0.0;
    } else {
      int totalSize = 0;
      await for (var file in cacheDir.list(recursive: true)) {
        if (file is File) {
          totalSize += await file.length();
        }
      }
      _currentSizeMb = totalSize / (1024 * 1024);
    }
    notifyListeners();
  }

  Future<void> checkAndEvict(context) async {
    await _calculateSize();
    if (_currentSizeMb > settingsService.tileCacheLimitMb) {
      // Logique simple : on vide les fichiers les plus anciens jusqu'à repasser sous la limite
      final dir = await getTemporaryDirectory();
      final cacheDir = Directory('${dir.path}/tile_cache');
      if (await cacheDir.exists()) {
        final files = await cacheDir.list(recursive: true).where((f) => f is File).cast<File>().toList();
        files.sort((a, b) => a.lastAccessedSync().compareTo(b.lastAccessedSync()));
        
        int i = 0;
        while (_currentSizeMb > settingsService.tileCacheLimitMb * 0.8 && i < files.length) {
          final size = await files[i].length();
          await files[i].delete();
          _currentSizeMb -= size / (1024 * 1024);
          i++;
        }
      }
      notifyListeners();
    }
  }

  Future<void> clearAll() async {
    final dir = await getTemporaryDirectory();
    final cacheDir = Directory('${dir.path}/tile_cache');
    if (await cacheDir.exists()) {
      await cacheDir.delete(recursive: true);
    }
    await _calculateSize();
  }
}
