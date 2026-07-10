import 'dart:io';

import '../database/isar_service.dart';
import '../models/enums.dart';
import '../search/local_search_engine.dart';
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

  Future<SegmentationResult> importFile(
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

  Future<SegmentationResult> importXmlString(
    String xmlContent, {
    required String ownerUuid,
    String? traceNameOverride,
    ActivityType activityType = ActivityType.hiking,
  }) async {
    final parsed = GpxParser.parseString(xmlContent);
    if (parsed.trackPoints.isEmpty) {
      throw ArgumentError('Le fichier GPX ne contient aucun point de trace exploitable.');
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

    final result = engine.segment(
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
}
