import 'package:uuid/uuid.dart';

import '../gpx/segmentation_engine.dart';
import '../models/enums.dart';
import '../models/gps_point.dart';
import '../models/segment.dart';
import '../models/trace.dart';
import '../models/trace_segment_entry.dart';
import '../utils/geo_utils.dart';
import 'location_share_models.dart';

const _uuid = Uuid();

/// Construit une [Trace] LOCALE UNIQUEMENT à partir de l'historique d'un
/// partage de position (voir spec-partage-position-live-tracking.md §8.1),
/// sans jamais passer par [SegmentationEngine] : pas de map-matching
/// Valhalla, pas de dédoublonnage contre des segments existants — un
/// partage de position n'a rien à voir avec la toile d'araignée
/// communautaire (§8.4 : une battue ou une sortie hors-piste ne doit
/// jamais transiter par le pipeline standard, qui rendrait le tracé
/// public via `segments` indépendamment de la visibilité de la [Trace]).
///
/// Le [SegmentationResult] produit est persisté via
/// `SegmentationPersistence.persist(...)`, inchangée : cette dernière
/// n'effectue que des écritures Isar + indexation recherche, aucun appel
/// réseau — elle est donc réutilisable telle quelle ici.
class LocationShareTraceBuilder {
  const LocationShareTraceBuilder._();

  /// [pings] doit contenir les points d'UN SEUL utilisateur, triés par
  /// [LocationPing.recordedAt] croissant.
  static SegmentationResult buildLocalOnly({
    required List<LocationPing> pings,
    required String ownerUuid,
    required String traceName,
    ActivityType activityType = ActivityType.hiking,
  }) {
    if (pings.length < 2) {
      throw ArgumentError('Au moins 2 points sont nécessaires pour former une trace.');
    }

    final points = pings
        .map((p) => PointGPS.create(
              latitude: p.lat,
              longitude: p.lng,
              altitude: p.altitude,
              timestamp: p.recordedAt,
              accuracyMeters: p.accuracy,
              speedMps: p.speed,
            ))
        .toList();

    double distance = 0;
    for (var i = 1; i < points.length; i++) {
      distance += GeoUtils.haversineMeters(
        points[i - 1].latitude,
        points[i - 1].longitude,
        points[i].latitude,
        points[i].longitude,
      );
    }
    final elevResult = GeoUtils.elevationGainLoss(points.map((p) => p.altitude).toList());
    // Certains appareils/points n'ont pas d'altitude (indoor, capteur bas
    // de gamme) — moyenne sur les seules valeurs connues plutôt qu'un
    // `.average()` qui lèverait sur une liste vide de non-nuls.
    final knownAltitudes = points.map((p) => p.altitude).whereType<double>().toList();
    final avgAlt = knownAltitudes.isEmpty
        ? 0.0
        : knownAltitudes.reduce((a, b) => a + b) / knownAltitudes.length;
    final bbox = GeoUtils.boundingBox(points.map((p) => (lat: p.latitude, lon: p.longitude)))!;

    final now = DateTime.now();
    final segment = Segment()
      ..localUuid = _uuid.v4()
      ..authorUuid = ownerUuid
      ..points = points
      // Jamais aimanté : ce tracé n'est jamais passé par le map-matching
      // Valhalla (aucun réseau pendant la construction de cette trace).
      ..mode = SegmentMode.offPath
      ..isOffRoad = true
      ..avgAltitude = avgAlt
      ..distanceMeters = distance
      ..elevationGainMeters = elevResult.gain
      ..elevationLossMeters = elevResult.loss
      ..passageCount = 1
      ..lastPassageAt = pings.last.recordedAt
      ..minLat = bbox.minLat
      ..maxLat = bbox.maxLat
      ..minLon = bbox.minLon
      ..maxLon = bbox.maxLon
      ..geohashPrefix = GeoUtils.geohash(points.first.latitude, points.first.longitude)
      // Cœur de l'exclusion §8.4 : jamais poussé, jamais tiré, quel que
      // soit l'état de `SyncEngine` — voir enums.dart.
      ..syncStatus = SyncStatus.excluded
      ..createdAt = now
      ..updatedAt = now;

    final trace = Trace()
      ..localUuid = _uuid.v4()
      ..ownerUuid = ownerUuid
      ..name = traceName
      ..segments = [
        TraceSegmentEntry.create(
          segmentUuid: segment.localUuid,
          orderIndex: 0,
          enteredAt: pings.first.recordedAt,
          exitedAt: pings.last.recordedAt,
        ),
      ]
      ..totalDistanceMeters = distance
      ..totalElevationGainMeters = elevResult.gain
      ..totalElevationLossMeters = elevResult.loss
      ..activityType = activityType
      // Redondant avec `syncStatus = excluded` ci-dessus (qui suffit à lui
      // seul à garantir l'exclusion du sync), mais gardé en ceinture et
      // bretelles : une trace de partage de position n'a de toute façon
      // aucune raison d'être autre chose que privée.
      ..visibility = TraceVisibility.private
      ..startedAt = pings.first.recordedAt
      ..endedAt = pings.last.recordedAt
      ..processingStatus = TraceProcessingStatus.ready
      ..syncStatus = SyncStatus.excluded
      ..createdAt = now
      ..updatedAt = now;

    return SegmentationResult(
      trace: trace,
      segmentsToUpsert: [segment],
      newSegmentsCount: 1,
      reusedSegmentsCount: 0,
    );
  }
}
