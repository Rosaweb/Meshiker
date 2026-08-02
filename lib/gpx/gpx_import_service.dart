import 'dart:io';

import 'package:isar_community/isar.dart';
import 'package:uuid/uuid.dart';
import '../database/isar_service.dart';
import '../models/enums.dart';
import '../models/trace.dart';
import '../models/waypoint.dart';
import '../search/local_search_engine.dart';
import 'gpx_models.dart';
import 'gpx_parser.dart';
import 'kml_parser.dart';
import 'segmentation_engine.dart';
import 'segmentation_persistence.dart';

/// Orchestration complete d'un import GPX ou KML : lecture du fichier,
/// parsing, decoupage en segments (en s'appuyant sur la toile locale deja
/// connue), persistance dans Isar, puis mise a jour incrementale du moteur
/// de recherche local.
///
/// C'est le point d'entree a appeler depuis l'UI ("Importer un fichier
/// GPX/KML"). Toute la logique metier reste dans SegmentationEngine (pur,
/// testable sans base de donnees) ; cette classe ne fait que la plomberie
/// IO + Isar + index de recherche autour. GpxParser et KmlParser produisent
/// tous deux le meme GpxParseResult, donc tout ce qui suit le parsing est
/// identique pour les deux formats.
class GpxImportService {
  GpxImportService({
    required this.isarService,
    required this.searchEngine,
    this.engine = const SegmentationEngine(),
  });

  final IsarService isarService;
  final LocalSearchEngine searchEngine;
  final SegmentationEngine engine;

  /// Marge (en degres) ajoutee autour de la bounding box du fichier GPX
  /// pour charger les segments/waypoints locaux potentiellement concernes.
  /// ~0.01 degre correspond a environ 1 km, une marge large et peu
  /// couteuse (peu de segments/waypoints a cette echelle sur un appareil
  /// individuel) qui evite de rater une correspondance juste en dehors
  /// de la trace stricte.
  static const _viewportMarginDegrees = 0.01;

  Future<SegmentationResult?> importFile(
    File gpxFile, {
    required String ownerUuid,
    String? traceNameOverride,
    ActivityType activityType = ActivityType.hiking,
  }) async {
    final content = await gpxFile.readAsString();
    final isKml = gpxFile.path.toLowerCase().endsWith('.kml');
    return _importContent(
      content,
      isKml: isKml,
      ownerUuid: ownerUuid,
      traceNameOverride: traceNameOverride,
      activityType: activityType,
    );
  }

  Future<SegmentationResult?> importXmlString(
    String xmlContent, {
    required String ownerUuid,
    String? traceNameOverride,
    ActivityType activityType = ActivityType.hiking,
  }) {
    return _importContent(
      xmlContent,
      isKml: false,
      ownerUuid: ownerUuid,
      traceNameOverride: traceNameOverride,
      activityType: activityType,
    );
  }

  Future<SegmentationResult?> importKmlString(
    String kmlContent, {
    required String ownerUuid,
    String? traceNameOverride,
    ActivityType activityType = ActivityType.hiking,
  }) {
    return _importContent(
      kmlContent,
      isKml: true,
      ownerUuid: ownerUuid,
      traceNameOverride: traceNameOverride,
      activityType: activityType,
    );
  }

  Future<SegmentationResult?> _importContent(
    String content, {
    required bool isKml,
    required String ownerUuid,
    String? traceNameOverride,
    ActivityType activityType = ActivityType.hiking,
  }) async {
    final parsed = isKml ? KmlParser.parseString(content) : GpxParser.parseString(content);
    if (parsed.trackPoints.isEmpty) {
      return null; // On laisse le scanner gérer les waypoints seuls
    }

    final lats = parsed.trackPoints.map((p) => p.latitude);
    final lons = parsed.trackPoints.map((p) => p.longitude);
    final minLat = lats.reduce((a, b) => a < b ? a : b) - _viewportMarginDegrees;
    final maxLat = lats.reduce((a, b) => a > b ? a : b) + _viewportMarginDegrees;
    final minLon = lons.reduce((a, b) => a < b ? a : b) - _viewportMarginDegrees;
    final maxLon = lons.reduce((a, b) => a > b ? a : b) + _viewportMarginDegrees;

    // Pre-chargement cible : seuls les segments/waypoints de la zone
    // concernee sont charges depuis Isar, jamais toute la base (voir
    // IsarService.segmentsInViewport / searchWaypoints, indexes).
    final nearbySegments = await isarService.segmentsInViewport(
      minLat: minLat,
      maxLat: maxLat,
      minLon: minLon,
      maxLon: maxLon,
    );
    final nearbyWaypoints = await isarService.searchWaypoints(
      minLat: minLat,
      maxLat: maxLat,
      minLon: minLon,
      maxLon: maxLon,
    );

    final result = await engine.segment(
      gpx: parsed,
      nearbyExistingSegments: nearbySegments,
      nearbyExistingWaypoints: nearbyWaypoints,
      ownerUuid: ownerUuid,
      traceNameOverride: traceNameOverride,
      activityType: activityType,
    );

    // Persistance atomique + mise à jour de l'index de recherche,
    // factorisées dans SegmentationPersistence (voir sa doc : trois
    // chemins produisent désormais un SegmentationResult à persister).
    await SegmentationPersistence.persist(
      isarService: isarService,
      result: result,
      searchEngine: searchEngine,
    );

    if (parsed.waypoints.isNotEmpty) {
      await _persistWaypoints(parsed.waypoints, associatedGpxName: result.trace.name);
    }

    return result;
  }

  /// Persiste les waypoints d'un GPX/KML importé, rattachés à la trace via
  /// [Waypoint.associatedGpxName] (même convention que
  /// GpxScannerService._processFile, dédoublonnage identique par
  /// nom+latitude+longitude+associatedGpxName — appeler cette méthode deux
  /// fois pour le même fichier est donc sans effet la seconde fois).
  Future<void> _persistWaypoints(
    List<GpxWaypoint> waypoints, {
    required String associatedGpxName,
  }) async {
    // indexWaypoint() lit waypoint.category.value, un IsarLink dont le
    // chargement est synchrone -- interdit à l'intérieur d'une transaction
    // asynchrone active ("Isar does not support nesting transactions").
    // On collecte donc les waypoints créés pour les indexer APRÈS la fin
    // de la transaction, comme le fait déjà SegmentationPersistence.persist
    // pour indexTrace().
    final created = <Waypoint>[];
    await isarService.isar.writeTxn(() async {
      for (final gpxWp in waypoints) {
        final wpName = gpxWp.name ?? 'Point sans nom';
        final exists = await isarService.isar.waypoints
            .filter()
            .nameEqualTo(wpName)
            .latitudeEqualTo(gpxWp.latitude)
            .longitudeEqualTo(gpxWp.longitude)
            .associatedGpxNameEqualTo(associatedGpxName)
            .findFirst();
        if (exists == null) {
          final wp = Waypoint()
            ..localUuid = const Uuid().v4()
            ..name = wpName
            ..description = gpxWp.description
            ..latitude = gpxWp.latitude
            ..longitude = gpxWp.longitude
            ..associatedGpxName = associatedGpxName
            ..updatedAt = DateTime.now();
          await isarService.isar.waypoints.put(wp);
          created.add(wp);
        }
      }
    });
    for (final wp in created) {
      searchEngine.indexWaypoint(wp);
    }
  }

  /// Refait le découpage de TOUTES les traces existantes.
  Future<void> resegmentAll() async {
    final traces = await isarService.isar.traces.where().findAll();
    
    for (final trace in traces) {
      final trackPoints = await isarService.getTraceTrackPoints(trace);
      if (trackPoints.length < 2) continue;

      final lats = trackPoints.map((p) => p.latitude);
      final lons = trackPoints.map((p) => p.longitude);
      final minLat = lats.reduce((a, b) => a < b ? a : b) - _viewportMarginDegrees;
      final maxLat = lats.reduce((a, b) => a > b ? a : b) + _viewportMarginDegrees;
      final minLon = lons.reduce((a, b) => a < b ? a : b) - _viewportMarginDegrees;
      final maxLon = lons.reduce((a, b) => a > b ? a : b) + _viewportMarginDegrees;

      final nearbySegments = await isarService.segmentsInViewport(
        minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon,
      );

      // On simule un import pour cette trace existante
      final result = await engine.segment(
        gpx: GpxParseResult(trackPoints: trackPoints, waypoints: [], traceName: trace.name),
        nearbyExistingSegments: nearbySegments.where((s) => !trace.segments.any((e) => e.segmentUuid == s.localUuid)).toList(),
        nearbyExistingWaypoints: const [],
        ownerUuid: trace.ownerUuid,
        activityType: trace.activityType,
      );

      // On met à jour l'objet trace existant au lieu d'en créer un nouveau si possible
      // Mais SegmentationEngine crée une nouvelle Trace. On va donc copier les données.
      trace.segments = result.trace.segments;
      trace.totalDistanceMeters = result.trace.totalDistanceMeters;
      trace.totalElevationGainMeters = result.trace.totalElevationGainMeters;
      trace.totalElevationLossMeters = result.trace.totalElevationLossMeters;
      trace.updatedAt = DateTime.now();

      await SegmentationPersistence.persist(
        isarService: isarService,
        result: SegmentationResult(
          trace: trace,
          segmentsToUpsert: result.segmentsToUpsert,
          newSegmentsCount: result.newSegmentsCount,
          reusedSegmentsCount: result.reusedSegmentsCount,
        ),
        searchEngine: searchEngine,
      );
    }
  }
}
