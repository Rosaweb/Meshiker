import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class PhotoScannerService {
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

  bool _isImage(String path) {
    final ext = p.extension(path).toLowerCase();
    return ['.jpg', '.jpeg', '.png'].contains(ext);
  }

  /// Indique au système Android de scanner un nouveau fichier pour qu'il apparaisse dans la galerie
  Future<void> scanFileForGallery(String filePath) async {
    if (Platform.isAndroid) {
      // On pourrait utiliser un package comme 'media_scanner' ici
      // Pour l'instant on log l'intention
      debugPrint('Scanning file for gallery: $filePath');
    }
  }
}
