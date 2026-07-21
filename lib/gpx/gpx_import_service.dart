import 'dart:io';

import 'package:isar_community/isar.dart';
import '../database/isar_service.dart';
import '../models/enums.dart';
import '../models/trace.dart';
import '../search/local_search_engine.dart';
import 'gpx_models.dart';
import 'gpx_parser.dart';
import 'segmentation_engine.dart';
import 'segmentation_persistence.dart';

/// Orchestration complete d'un import GPX : lecture du fichier, parsing,
/// decoupage en segments (en s'appuyant sur la toile locale deja connue),
/// persistance dans Isar, puis mise a jour incrementale du moteur de
/// recherche local.
///
/// C'est le point d'entree a appeler depuis l'UI ("Importer un fichier
/// GPX"). Toute la logique metier reste dans SegmentationEngine (pur, testable
/// sans base de donnees) ; cette classe ne fait que la plomberie
/// IO + Isar + index de recherche autour.
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
  /// pour charger les segments/POI locaux potentiellement concernes.
  /// ~0.01 degre correspond a environ 1 km, une marge large et peu
  /// couteuse (peu de segments/POI a cette echelle sur un appareil
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
    return importXmlString(
      content,
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
  }) async {
    final parsed = GpxParser.parseString(xmlContent);
    if (parsed.trackPoints.isEmpty) {
      return null; // On laisse le scanner gérer les waypoints seuls
    }

    final lats = parsed.trackPoints.map((p) => p.latitude);
    final lons = parsed.trackPoints.map((p) => p.longitude);
    final minLat = lats.reduce((a, b) => a < b ? a : b) - _viewportMarginDegrees;
    final maxLat = lats.reduce((a, b) => a > b ? a : b) + _viewportMarginDegrees;
    final minLon = lons.reduce((a, b) => a < b ? a : b) - _viewportMarginDegrees;
    final maxLon = lons.reduce((a, b) => a > b ? a : b) + _viewportMarginDegrees;

    // Pre-chargement cible : seuls les segments/POI de la zone concernee
    // sont charges depuis Isar, jamais toute la base (voir
    // IsarService.segmentsInViewport / poisInViewport, indexes).
    final nearbySegments = await isarService.segmentsInViewport(
      minLat: minLat,
      maxLat: maxLat,
      minLon: minLon,
      maxLon: maxLon,
    );
    final nearbyPois = await isarService.poisInViewport(
      minLat: minLat,
      maxLat: maxLat,
      minLon: minLon,
      maxLon: maxLon,
    );

    final result = await engine.segment(
      gpx: parsed,
      nearbyExistingSegments: nearbySegments,
      nearbyExistingPois: nearbyPois,
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

    return result;
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
      final nearbyPois = await isarService.poisInViewport(
        minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon,
      );

      // On simule un import pour cette trace existante
      final result = await engine.segment(
        gpx: GpxParseResult(trackPoints: trackPoints, waypoints: [], traceName: trace.name),
        nearbyExistingSegments: nearbySegments.where((s) => !trace.segments.any((e) => e.segmentUuid == s.localUuid)).toList(),
        nearbyExistingPois: nearbyPois,
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
          poisToUpsert: result.poisToUpsert,
          newSegmentsCount: result.newSegmentsCount,
          reusedSegmentsCount: result.reusedSegmentsCount,
          newPoisCount: result.newPoisCount,
          reusedPoisCount: result.reusedPoisCount,
        ),
        searchEngine: searchEngine,
      );
    }
  }
}
