import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class PhotoScannerService {
  /// Canal partagé avec [PhotoCaptureService] pour le lancement de l'appli
  /// caméra système et l'indexation MediaStore (voir MainActivity.kt).
  static const _channel = MethodChannel('meshiker/photo_capture');

  Future<String> getPublicMeshikerPath() async {
    if (Platform.isAndroid) {
      // Sur Android, on essaie d'aller dans /storage/emulated/0/Pictures/Meshiker
      // Mais avec le scoped storage, c'est compliqué sans permissions spéciales.
      // On utilise le répertoire d'images externe s'il existe.
      final directory = await getExternalStorageDirectory();
      if (directory != null) {
        final picturesPath = p.join(directory.parent.parent.parent.parent.path, 'Pictures', 'Meshiker');
        return picturesPath;
      }
    }

    // Fallback sur le dossier documents de l'app si on ne peut pas faire mieux
    final directory = await getApplicationDocumentsDirectory();
    return p.join(directory.path, 'Photos');
  }

  Future<List<File>> scanPhotos() async {
    final path = await getPublicMeshikerPath();
    final dir = Directory(path);
    if (!await dir.exists()) return [];

    final files = await dir.list().where((f) => f is File && _isImage(f.path)).cast<File>().toList();
    // Trier par date
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  /// Photos du dossier public Meshiker modifiées dans la fenêtre [since]..[until]
  /// — sert de filet de rattrapage à [PhotoCaptureService] : une photo écrite
  /// sur disque pendant une session multi-photos mais non captée en temps réel
  /// (process tué par l'OS) est récupérée ici au retour au premier plan
  /// (spec-photos-geolocalisees.md §3.3).
  Future<List<File>> scanPhotosBetween(DateTime since, DateTime until) async {
    final all = await scanPhotos();
    return all.where((f) {
      final m = f.lastModifiedSync();
      return !m.isBefore(since) && !m.isAfter(until);
    }).toList();
  }

  bool _isImage(String path) {
    final ext = p.extension(path).toLowerCase();
    return ['.jpg', '.jpeg', '.png'].contains(ext);
  }

  /// Indique au MediaStore Android de (ré)indexer [filePath] pour qu'il
  /// apparaisse immédiatement dans la galerie système (implémenté nativement
  /// via MediaScannerConnection, voir MainActivity.kt). No-op hors Android.
  Future<void> scanFileForGallery(String filePath) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('scanFile', {'path': filePath});
    } catch (e) {
      debugPrint('scanFileForGallery failed for $filePath: $e');
    }
  }
}
