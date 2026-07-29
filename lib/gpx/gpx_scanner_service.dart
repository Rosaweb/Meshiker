import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:isar_community/isar.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:path/path.dart' as p;
import '../database/isar_service.dart';
import '../models/trace.dart';
import '../models/enums.dart';
import 'gpx_import_service.dart';

import 'package:uuid/uuid.dart';
import '../models/waypoint.dart';
import 'gpx_models.dart';
import 'gpx_parser.dart';
import 'kml_parser.dart';

/// Résultat d'un [GpxScannerService.scanFolder], pour que l'écran appelant
/// puisse informer l'utilisateur d'un échec silencieux (dossier
/// introuvable, permission refusée) plutôt que de laisser croire que
/// l'absence de traces trouvées signifie "dossier vide".
enum GpxScanResult { ok, directoryNotFound, permissionDenied }

class GpxScannerService extends ChangeNotifier {
  final IsarService isarService;
  final GpxImportService importService;
  final String ownerUuid;

  GpxScannerService({
    required this.isarService,
    required this.importService,
    required this.ownerUuid,
  });

  bool _isScanning = false;
  bool get isScanning => _isScanning;

  Future<GpxScanResult> scanFolder(String path) async {
    if (_isScanning) return GpxScanResult.ok;
    _isScanning = true;
    notifyListeners();

    try {
      final normalizedPath = p.canonicalize(path);
      debugPrint('GpxScannerService: Starting scan in $normalizedPath');
      final dir = Directory(normalizedPath);
      if (!await dir.exists()) {
        debugPrint('GpxScannerService: Directory does not exist');
        return GpxScanResult.directoryNotFound;
      }

      // Accès en lecture au stockage (Android). Le sélecteur de dossier
      // (SAF) ne suffit pas : dart:io lit ensuite le chemin brut, ce qui
      // exige la permission "Tous les fichiers" côté OS. Sans ce contrôle
      // explicite, un refus (ou une révocation automatique par l'OS après
      // une période d'inactivité) fait échouer le scan silencieusement --
      // aucun fichier trouvé, sans qu'aucune erreur ne remonte à
      // l'utilisateur.
      if (Platform.isAndroid) {
        var granted = (await ph.Permission.manageExternalStorage.status).isGranted;
        if (!granted) {
          debugPrint('GpxScannerService: Requesting manageExternalStorage permission');
          granted = (await ph.Permission.manageExternalStorage.request()).isGranted;
        }
        if (!granted) {
          // Repli pour les appareils/versions où la permission spéciale
          // n'est pas proposée (l'OS l'ignore silencieusement au-delà de
          // l'API 32, cf. maxSdkVersion dans AndroidManifest.xml).
          granted = (await ph.Permission.storage.request()).isGranted;
        }
        if (!granted) {
          debugPrint('GpxScannerService: Storage permission denied, aborting scan');
          return GpxScanResult.permissionDenied;
        }
      }

      await _scanRecursive(dir);

      // Après le scan rapide, la segmentation se poursuit en tâche de fond.
      // On l'attend ici pour que isScanning (et donc le chargement affiché)
      // couvre toute la durée du traitement, pas seulement l'indexation rapide.
      await _processPendingSegmentations();
      return GpxScanResult.ok;
    } catch (e) {
      debugPrint('GpxScannerService: Scan error: $e');
      return GpxScanResult.permissionDenied;
    } finally {
      _isScanning = false;
      notifyListeners();
    }
  }

  Future<void> _processPendingSegmentations() async {
    // Note: On utilise un filtrage manuel pour éviter les erreurs de compilation 
    // tant que build_runner n'a pas régénéré les fichiers trace.g.dart
    final allTraces = await isarService.isar.traces.where().findAll();
    final pending = allTraces.where((t) => t.processingStatus == TraceProcessingStatus.pending).toList();
    
    if (pending.isEmpty) return;
    debugPrint('GpxScannerService: Starting background segmentation for ${pending.length} tracks');

    for (final trace in pending) {
      try {
        final file = File(trace.sourceFilePath!);
        if (!await file.exists()) continue;

        await isarService.isar.writeTxn(() async {
          trace.processingStatus = TraceProcessingStatus.processing;
          await isarService.isar.traces.put(trace);
        });
        notifyListeners();

        final result = await importService.importFile(
          file, 
          ownerUuid: ownerUuid,
          traceNameOverride: trace.name,
        );

        if (result != null) {
          // On met à jour la trace existante au lieu d'en créer une nouvelle
          await isarService.isar.writeTxn(() async {
            trace.segments = result.trace.segments;
            trace.totalDistanceMeters = result.trace.totalDistanceMeters;
            trace.totalElevationGainMeters = result.trace.totalElevationGainMeters;
            trace.totalElevationLossMeters = result.trace.totalElevationLossMeters;
            trace.processingStatus = TraceProcessingStatus.ready;
            trace.updatedAt = DateTime.now();
            await isarService.isar.traces.put(trace);
          });
          // Supprimer la trace temporaire créée par importService (car il crée un nouvel objet)
          await isarService.isar.writeTxn(() async {
            await isarService.isar.traces.delete(result.trace.id);
          });
        }
      } catch (e) {
        debugPrint('GpxScannerService: Error processing background segmentation: $e');
        await isarService.isar.writeTxn(() async {
          trace.processingStatus = TraceProcessingStatus.error;
          await isarService.isar.traces.put(trace);
        });
      }
      notifyListeners();
    }
  }

  Future<void> _scanRecursive(Directory dir) async {
    try {
      final List<FileSystemEntity> entities = await dir.list(recursive: false, followLinks: false).toList();
      debugPrint('GpxScannerService: Found ${entities.length} entities in ${dir.path}');
      
      for (final entity in entities) {
        final normalizedPath = p.canonicalize(entity.path);
        
        final lowerPath = normalizedPath.toLowerCase();
        if (entity is File && (lowerPath.endsWith('.gpx') || lowerPath.endsWith('.kml'))) {
          debugPrint('GpxScannerService: Found track file: $normalizedPath');
          await _processFile(entity);
          notifyListeners(); // Update UI periodically
        } else if (entity is Directory) {
          // On ignore les dossiers système ou cachés
          if (!p.basename(normalizedPath).startsWith('.')) {
            await _scanRecursive(entity);
          }
        }
      }
    } catch (e) {
      debugPrint('GpxScannerService: Error listing ${dir.path}: $e');
    }
  }

  Future<void> _processFile(File file) async {
    final normalizedPath = p.canonicalize(file.path);
    final fileName = p.basenameWithoutExtension(file.path);
    debugPrint('GpxScannerService: Processing $normalizedPath');

    try {
      final content = await file.readAsString();
      final GpxParseResult parsed = normalizedPath.toLowerCase().endsWith('.kml')
          ? KmlParser.parseString(content)
          : GpxParser.parseString(content);

      // 1. Création rapide de la trace (sans segmentation lourde)
      Trace? trace;
      if (parsed.trackPoints.isNotEmpty) {
        final existingTrace = await isarService.isar.traces
            .filter()
            .sourceFilePathEqualTo(normalizedPath)
            .findFirst();

        if (existingTrace == null) {
          debugPrint('GpxScannerService: Quick indexing new trace: $normalizedPath');
          
          // On crée une trace "fantôme" immédiatement visible
          trace = Trace()
            ..localUuid = const Uuid().v4()
            ..ownerUuid = ownerUuid
            ..name = fileName
            ..sourceFilePath = normalizedPath
            ..processingStatus = TraceProcessingStatus.pending // Indique qu'il faut segmenter plus tard
            ..totalDistanceMeters = 0 // Sera mis à jour après segmentation
            ..updatedAt = DateTime.now();
          
          await isarService.saveTrace(trace);
        } else {
          trace = existingTrace;
          debugPrint('GpxScannerService: Trace already exists: $normalizedPath');
        }
      }

      // 2. Gérer les waypoints immédiatement (toujours rapide)
      if (parsed.waypoints.isNotEmpty) {
        final associatedName = trace?.name ?? fileName;
        await isarService.isar.writeTxn(() async {
          for (final gpxWp in parsed.waypoints) {
            final wpName = gpxWp.name ?? 'Point sans nom';
            
            // Éviter les doublons par nom et position dans le même GPX
            final exists = await isarService.isar.waypoints
                .filter()
                .nameEqualTo(wpName)
                .latitudeEqualTo(gpxWp.latitude)
                .longitudeEqualTo(gpxWp.longitude)
                .associatedGpxNameEqualTo(associatedName)
                .findFirst();
            
            if (exists == null) {
              final wp = Waypoint()
                ..localUuid = const Uuid().v4()
                ..name = wpName
                ..latitude = gpxWp.latitude
                ..longitude = gpxWp.longitude
                ..associatedGpxName = associatedName
                ..updatedAt = DateTime.now();
              await isarService.isar.waypoints.put(wp);
              importService.searchEngine.indexWaypoint(wp);
            }
          }
        });
      }
    } catch (e) {
      debugPrint('Error processing GPX $normalizedPath: $e');
    }
  }
}
