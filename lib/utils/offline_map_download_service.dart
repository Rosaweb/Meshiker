import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../database/isar_service.dart';
import '../models/offline_map/offline_map.dart';

/// Télécharge réellement les tuiles raster d'une zone/plage de zoom
/// (`OfflineMap.minLat/maxLat/minLon/maxLon/minZoom/maxZoom`) depuis
/// `urlTemplate`, et les stocke dans le répertoire documents de l'app
/// (persistant, contrairement au cache tuiles éphémère de
/// [TileCacheService] qui vit dans le dossier temporaire du système et peut
/// être purgé par l'OS à tout moment).
///
/// Reprise : les tuiles déjà présentes sur le disque sont ignorées, donc
/// relancer le téléchargement d'une carte interrompue (perte réseau, app
/// tuée) ne retélécharge que ce qui manque.
class OfflineMapDownloadService {
  OfflineMapDownloadService({required this.isarService});

  final IsarService isarService;

  // Un token par carte en cours de téléchargement, pour pouvoir
  // l'annuler (ex: suppression de la carte pendant le téléchargement)
  // sans avoir à traquer la Future elle-même.
  static final Map<String, bool> _cancelled = {};

  static void cancel(String mapUuid) => _cancelled[mapUuid] = true;

  Future<Directory> mapDirectory(String mapUuid) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/offline_maps/$mapUuid');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static File tileFile(Directory mapDir, int z, int x, int y) =>
      File('${mapDir.path}/$z/$x/$y.png');

  // Conversion lat/lon -> indices de tuile, projection Web Mercator
  // standard (identique à celle utilisée par flutter_map/OSM/xyz).
  static int lonToTileX(double lon, int z) =>
      ((lon + 180.0) / 360.0 * (1 << z)).floor().clamp(0, (1 << z) - 1);

  static int latToTileY(double lat, int z) {
    final latRad = lat.clamp(-85.05112878, 85.05112878) * pi / 180.0;
    final y = (1.0 - log(tan(latRad) + 1 / cos(latRad)) / pi) / 2.0 * (1 << z);
    return y.floor().clamp(0, (1 << z) - 1);
  }

  /// Nombre total de tuiles couvertes par [map], tous niveaux de zoom
  /// confondus -- utile pour prévenir l'utilisateur avant un téléchargement
  /// potentiellement lourd.
  static int tileCount(OfflineMap map) {
    var total = 0;
    for (var z = map.minZoom; z <= map.maxZoom; z++) {
      final xMin = lonToTileX(map.minLon, z);
      final xMax = lonToTileX(map.maxLon, z);
      final yMin = latToTileY(map.maxLat, z);
      final yMax = latToTileY(map.minLat, z);
      total += (xMax - xMin + 1) * (yMax - yMin + 1);
    }
    return total;
  }

  /// Télécharge (ou reprend) les tuiles de [map]. Met à jour
  /// `downloadProgress`/`sizeBytes`/`isDownloading`/`isError` en base au fil
  /// de l'avancement, pour que l'écran "Mes cartes > Hors ligne" (qui
  /// observe directement Isar) se mette à jour en direct.
  Future<void> download(OfflineMap map, {Map<String, String> headers = const {}}) async {
    _cancelled[map.localUuid] = false;
    final dir = await mapDirectory(map.localUuid);

    map.isDownloading = true;
    map.isError = false;
    map.localPath = dir.path;
    await isarService.saveOfflineMap(map);

    final tiles = <(int, int, int)>[];
    for (var z = map.minZoom; z <= map.maxZoom; z++) {
      final xMin = lonToTileX(map.minLon, z);
      final xMax = lonToTileX(map.maxLon, z);
      final yMin = latToTileY(map.maxLat, z);
      final yMax = latToTileY(map.minLat, z);
      for (var x = xMin; x <= xMax; x++) {
        for (var y = yMin; y <= yMax; y++) {
          tiles.add((z, x, y));
        }
      }
    }

    if (tiles.isEmpty) {
      map.isDownloading = false;
      map.isError = true;
      await isarService.saveOfflineMap(map);
      return;
    }

    var done = 0;
    var failures = 0;
    var lastPersistedProgress = -1.0;

    for (final (z, x, y) in tiles) {
      if (_cancelled[map.localUuid] == true) return;

      final file = tileFile(dir, z, x, y);
      if (!await file.exists()) {
        try {
          final url = map.urlTemplate
              .replaceAll('{z}', '$z')
              .replaceAll('{x}', '$x')
              .replaceAll('{y}', '$y');
          final response = await http.get(Uri.parse(url), headers: headers);
          if (response.statusCode == 200) {
            await file.parent.create(recursive: true);
            await file.writeAsBytes(response.bodyBytes);
          } else {
            failures++;
          }
        } catch (_) {
          failures++;
        }
      }

      done++;
      final progress = done / tiles.length;
      // On n'écrit en base qu'à chaque pourcent entier franchi : écrire à
      // chaque tuile (potentiellement des milliers) saturerait Isar pour un
      // gain d'affichage imperceptible.
      if (progress - lastPersistedProgress >= 0.01 || done == tiles.length) {
        lastPersistedProgress = progress;
        map.downloadProgress = progress;
        await isarService.saveOfflineMap(map);
      }
    }

    map.isDownloading = false;
    // Une majorité de tuiles manquantes (zone hors couverture, source
    // injoignable...) -> on signale l'erreur plutôt que de prétendre que la
    // carte est utilisable hors-ligne alors qu'elle est trouée.
    map.isError = failures > tiles.length * 0.2;
    map.sizeBytes = await _directorySizeBytes(dir);
    await isarService.saveOfflineMap(map);
  }

  Future<int> _directorySizeBytes(Directory dir) async {
    var total = 0;
    await for (final entry in dir.list(recursive: true)) {
      if (entry is File) total += await entry.length();
    }
    return total;
  }

  /// Supprime les tuiles déjà téléchargées pour [mapUuid] du stockage
  /// persistant. À appeler quand l'OfflineMap correspondante est supprimée
  /// de la base, sinon les fichiers restent orphelins sur le disque.
  Future<void> deleteFiles(String mapUuid) async {
    cancel(mapUuid);
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/offline_maps/$mapUuid');
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
