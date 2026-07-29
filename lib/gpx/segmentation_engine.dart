import 'dart:math';

import 'package:uuid/uuid.dart';
import 'package:collection/collection.dart';

import '../models/enums.dart';
import '../models/gps_point.dart';
import '../models/segment.dart';
import '../models/trace.dart';
import '../models/trace_segment_entry.dart';
import '../models/waypoint.dart';
import '../utils/geo_utils.dart';
import 'gpx_models.dart';
import '../utils/valhalla_service.dart';

const _uuid = Uuid();

/// Réglages du découpage hybride.
class SegmentationConfig {
  const SegmentationConfig({
    this.minPointSpacingMeters = 3.0,
    this.offRoadSnapBufferMeters = 15.0,
    this.waypointAttachBufferMeters = 25.0,
    this.enablePauseDetection = true,
    this.stopGapDuration = const Duration(minutes: 3),
    this.minSegmentPoints = 3,
    this.matchCoverageThreshold = 0.75,
    this.partialRoutedThreshold = 0.3,
    this.matchLengthToleranceRatio = 0.3,
    this.altitudeFusionThresholdMeters = 15.0,
    this.elevationNoiseThresholdMeters = 2.0,
  });

  final double minPointSpacingMeters;

  /// Rayon (m) pour la fusion géométrique quand hors du réseau OSM.
  final double offRoadSnapBufferMeters;

  /// Rayon (m) pour rattacher un `<wpt>` GPX au [Waypoint] deja indexe
  /// localement pour ce meme point (voir GpxScannerService, indexation
  /// rapide) et au point de trace le plus proche, afin de determiner a
  /// quel segment issu du decoupage ce waypoint appartient.
  final double waypointAttachBufferMeters;

  /// Active la detection d'arrets prolonges comme points de coupure.
  final bool enablePauseDetection;
  final Duration stopGapDuration;

  /// Nombre minimal de points entre deux coupures.
  final int minSegmentPoints;

  /// Fraction minimale des points d'une tranche devant etre proches d'un
  /// segment existant pour considerer qu'il s'agit d'un repassage sur ce
  /// meme segment (reutilisation, aucun doublon cree).
  final double matchCoverageThreshold;

  /// Fraction minimale de recouvrement pour marquer un nouveau segment
  /// comme "route" meme sans correspondance locale suffisamment bonne
  /// pour une reutilisation complete.
  final double partialRoutedThreshold;

  /// Tolerance relative de longueur pour valider une reutilisation de
  /// segment existant (evite de confondre un aller-retour partiel avec
  /// le segment complet, par exemple).
  final double matchLengthToleranceRatio;

  /// Différence d'altitude maximale pour autoriser une fusion (protection falaises/ponts).
  final double altitudeFusionThresholdMeters;

  final double elevationNoiseThresholdMeters;
}

/// Bascule manuelle du mode routé/hors-piste ("aimant") décidée par
/// l'utilisateur PENDANT l'enregistrement (voir `RecordingService`, étape
/// 3) — par opposition au mode déduit automatiquement par recouvrement
/// avec la toile locale. Basé sur un horodatage (et non un index de
/// point) pour rester indépendant du nettoyage anti-bruit GPS, qui peut
/// supprimer des points et décaler les index.
///
/// Sans objet pour un import GPX classique (qui n'a pas cette notion) :
/// [SegmentationEngine.segment] accepte une liste vide par défaut.
class ModeOverride {
  const ModeOverride({required this.at, required this.mode});

  final DateTime at;
  final SegmentMode mode;
}

/// Resultat d'un decoupage : tout ce qu'il faut pour persister l'import
/// (la trace, les segments a upserter -- nouveaux ou juste mis a jour en
/// frequentation, waypoints GPX rattaches inclus --) ainsi que quelques
/// compteurs utiles pour informer l'utilisateur ("6 segments deja connus,
/// 3 nouveaux").
class SegmentationResult {
  SegmentationResult({
    required this.trace,
    required this.segmentsToUpsert,
    required this.newSegmentsCount,
    required this.reusedSegmentsCount,
  });

  final Trace trace;
  final List<Segment> segmentsToUpsert;
  final int newSegmentsCount;
  final int reusedSegmentsCount;
}

/// Decoupe une trace GPX en segments elementaires, en s'appuyant sur la
/// toile locale deja connue (segments deja enregistres sur l'appareil)
/// pour eviter de dupliquer un chemin deja emprunte.
///
/// Points de coupure retenus, par ordre de priorite :
/// 1. bornes de la trace (premier/dernier point) ;
/// 2. rupture entre deux segments GPX distincts (perte GPS reelle) ;
/// 3. arret prolonge, si SegmentationConfig.enablePauseDetection ;
/// 4. changement de bascule aimant manuelle en cours d'enregistrement
///    (voir ModeOverride, alimente par RecordingService, etape 3).
///
/// Les `<wpt>` GPX ne sont PAS un point de coupure : ils sont rattaches
/// (par UUID, voir [Segment.waypointUuids]) au segment issu du decoupage
/// qui contient leur point de trace le plus proche, comme s'ils etaient
/// ecrits "in-line" parmi les points de position. Le [Waypoint] lui-meme
/// n'est pas cree ici (voir GpxScannerService, indexation rapide) : ce
/// moteur se contente de retrouver, parmi [nearbyExistingWaypoints], celui
/// qui correspond a chaque `<wpt>` et de reference son UUID sur le
/// segment concerne.
///
/// Cette classe est volontairement PURE : aucun acces a Isar. C'est
/// l'appelant (voir GpxImportService) qui fournit les segments/waypoints
/// deja charges depuis la base pour la zone concernee, ce qui rend le
/// moteur facilement testable unitairement, sans base de donnees.
///
/// Limite assumee : si la nouvelle trace croise le MILIEU d'un segment
/// deja enregistre (une vraie nouvelle intersection), ce module ne
/// retro-decoupe PAS ce segment existant, il se contente de couper SA
/// PROPRE tranche a cet endroit. Scinder un segment existant, potentiellement
/// partage par d'autres traces, est une operation a portee communautaire
/// qui releve de la fusion serveur (PostGIS ST_Split), pas d'un import
/// local isole.
class SegmentationEngine {
  const SegmentationEngine({this.config = const SegmentationConfig()});

  final SegmentationConfig config;

  Future<SegmentationResult> segment({
    required GpxParseResult gpx,
    required List<Segment> nearbyExistingSegments,
    required List<Waypoint> nearbyExistingWaypoints,
    required String ownerUuid,
    String? traceNameOverride,
    ActivityType activityType = ActivityType.hiking,
    List<ModeOverride> modeOverrides = const [],
  }) async {
    final cleaned = _cleanPoints(gpx.trackPoints);
    if (cleaned.length < 2) {
      throw ArgumentError(
        'GPX trop court ou entierement filtre : au moins 2 points valides sont requis.',
      );
    }

    // 1. Appel au Map Matching Valhalla
    final matchedPoints = await ValhallaService.matchTrace(
      cleaned.map((p) => PointGPS.create(
        latitude: p.latitude,
        longitude: p.longitude,
        altitude: p.elevation,
        timestamp: p.time ?? DateTime.now(),
      )).toList()
    );

    final sortedOverrides = List<ModeOverride>.of(modeOverrides)
      ..sort((a, b) => a.at.compareTo(b.at));

    // Resolution des <wpt> vers leur Waypoint local deja indexe + leur
    // point de trace le plus proche, pour rattachement au segment
    // correspondant une fois le decoupage effectue plus bas.
    final wptResolutions = <_WaypointResolution>[];
    for (final wpt in gpx.waypoints) {
      final resolution = _resolveWaypointForAttachment(
        wpt,
        cleaned,
        nearbyExistingWaypoints,
      );
      if (resolution != null) wptResolutions.add(resolution);
    }

    // 2. Détermination des points de coupure (Hybride)
    final cutIndices = _findForcedCutIndicesHybrid(
      cleaned,
      matchedPoints,
      sortedOverrides,
      nearbyExistingSegments
    );
    final sortedCuts = cutIndices.toList()..sort();

    final segmentsToUpsert = <Segment>[];
    final traceEntries = <TraceSegmentEntry>[];
    var newSegmentsCount = 0;
    var reusedSegmentsCount = 0;
    double totalDistance = 0, totalGain = 0, totalLoss = 0;

    for (var i = 0; i < sortedCuts.length - 1; i++) {
      final start = sortedCuts[i];
      final end = sortedCuts[i + 1];
      if (end <= start) continue;

      final slice = cleaned.sublist(start, end + 1);
      final matchedSlice = matchedPoints.sublist(start, end + 1);

      final built = _buildSegmentForSliceHybrid(
        slice,
        matchedSlice,
        nearbyExistingSegments,
        ownerUuid,
        sortedOverrides,
      );

      if (built.reusedExisting) {
        reusedSegmentsCount++;
      } else {
        newSegmentsCount++;
      }
      segmentsToUpsert.add(built.segment);
      totalDistance += built.sliceDistanceMeters;
      totalGain += built.sliceElevationGainMeters;
      totalLoss += built.sliceElevationLossMeters;

      for (final wr in wptResolutions) {
        if (wr.pointIndex >= start &&
            wr.pointIndex <= end &&
            !built.segment.waypointUuids.contains(wr.waypointUuid)) {
          built.segment.waypointUuids.add(wr.waypointUuid);
        }
      }

      traceEntries.add(TraceSegmentEntry.create(
        segmentUuid: built.segment.localUuid,
        orderIndex: i,
        traveledForward: built.traveledForward,
        enteredAt: slice.first.time,
        exitedAt: slice.last.time,
      ));
    }

    final trace = Trace()
      ..localUuid = _uuid.v4()
      ..ownerUuid = ownerUuid
      ..name = traceNameOverride ??
          gpx.traceName ??
          'Randonnee du ${_formatDate(cleaned.first.time ?? DateTime.now())}'
      ..segments = traceEntries
      ..totalDistanceMeters = totalDistance
      ..totalElevationGainMeters = totalGain
      ..totalElevationLossMeters = totalLoss
      ..activityType = activityType
      ..visibility = TraceVisibility.private
      ..startedAt = cleaned.first.time ?? DateTime.now()
      ..endedAt = cleaned.last.time
      ..syncStatus = SyncStatus.pending
      ..createdAt = DateTime.now()
      ..updatedAt = DateTime.now();

    return SegmentationResult(
      trace: trace,
      segmentsToUpsert: segmentsToUpsert,
      newSegmentsCount: newSegmentsCount,
      reusedSegmentsCount: reusedSegmentsCount,
    );
  }

  // -----------------------------------------------------------------
  // Nettoyage
  // -----------------------------------------------------------------

  List<GpxTrackPoint> _cleanPoints(List<GpxTrackPoint> raw) {
    if (raw.isEmpty) return raw;
    final kept = <GpxTrackPoint>[raw.first];
    for (var i = 1; i < raw.length; i++) {
      final p = raw[i];
      if (p.startsNewSegment) {
        kept.add(p);
        continue;
      }
      final last = kept.last;
      final d = GeoUtils.haversineMeters(
        last.latitude,
        last.longitude,
        p.latitude,
        p.longitude,
      );
      if (d >= config.minPointSpacingMeters) {
        kept.add(p);
      }
    }
    return kept;
  }

  // -----------------------------------------------------------------
  // Points de coupure
  // -----------------------------------------------------------------

  // -----------------------------------------------------------------
  // Points de coupure (Hybride)
  // -----------------------------------------------------------------

  Set<int> _findForcedCutIndicesHybrid(
    List<GpxTrackPoint> points,
    List<MatchedPoint> matchedPoints,
    List<ModeOverride> sortedOverrides,
    List<Segment> nearbyExistingSegments,
  ) {
    final cuts = <int>{0, points.length - 1};

    // 1. Ruptures GPX (perte de signal)
    for (var i = 1; i < points.length; i++) {
      if (points[i].startsNewSegment) cuts.add(i);
    }

    // 2. Détection via Topologie OSM
    for (var i = 0; i < matchedPoints.length; i++) {
      final m = matchedPoints[i];
      if (m.isConfident) {
        // A. Nœud d'intersection OSM
        if (m.osmNodeId != null) cuts.add(i);
        
        // B. Changement de Way OSM (virage serré ou changement de rue)
        if (i > 0 && matchedPoints[i - 1].isConfident && 
            matchedPoints[i - 1].osmWayId != m.osmWayId) {
          cuts.add(i);
          cuts.add(i - 1);
        }
      }

      // C. Transition OSM <-> Hors-piste (Ghost Node)
      if (i > 0 && matchedPoints[i - 1].isConfident != m.isConfident) {
        cuts.add(i);
        cuts.add(i - 1);
      }
    }

    // 3. Fallback Géométrique (pour les zones hors-OSM)
    for (final segment in nearbyExistingSegments) {
      if (segment.osmWayId != null) continue; // On gère l'OSM via Meili au-dessus

      final polyline = segment.points.map((p) => (lat: p.latitude, lon: p.longitude)).toList();
      for (var i = 0; i < points.length; i++) {
        final p = points[i];
        final dToStart = GeoUtils.haversineMeters(p.latitude, p.longitude, polyline.first.lat, polyline.first.lon);
        final dToEnd = GeoUtils.haversineMeters(p.latitude, p.longitude, polyline.last.lat, polyline.last.lon);
        
        if (dToStart <= config.offRoadSnapBufferMeters || dToEnd <= config.offRoadSnapBufferMeters) {
          cuts.add(i);
        }
      }
    }

    // 4. Détection des pauses prolongées
    if (config.enablePauseDetection) {
      for (var i = 1; i < points.length; i++) {
        final prevTime = points[i - 1].time;
        final time = points[i].time;
        if (prevTime != null &&
            time != null &&
            time.difference(prevTime) >= config.stopGapDuration) {
          cuts.add(i);
        }
      }
    }

    return _mergeCloseCuts(cuts, points.length);
  }

  // -----------------------------------------------------------------
  // Construction d'un segment pour une tranche de points (Hybride)
  // -----------------------------------------------------------------

  _BuiltSegment _buildSegmentForSliceHybrid(
    List<GpxTrackPoint> slice,
    List<MatchedPoint> matchedSlice,
    List<Segment> nearbyExistingSegments,
    String ownerUuid,
    List<ModeOverride> sortedOverrides,
  ) {
    final points = slice
        .map((p) => PointGPS.create(
              latitude: p.latitude,
              longitude: p.longitude,
              altitude: p.elevation,
              timestamp: p.time ?? DateTime.now(),
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

    final elevResult = GeoUtils.elevationGainLoss(
      points.map((p) => p.altitude).toList(),
      noiseThresholdMeters: config.elevationNoiseThresholdMeters,
    );
    final avgAlt = points.map((p) => p.altitude).average();

    final bbox = GeoUtils.boundingBox(
      points.map((p) => (lat: p.latitude, lon: p.longitude)),
    )!;

    // Tentative de réutilisation (priorité topologie)
    Segment? bestMatch;
    
    // A. Match via OSM Way ID
    final confidentOsmId = matchedSlice.first.isConfident ? matchedSlice.first.osmWayId : null;
    if (confidentOsmId != null) {
      bestMatch = nearbyExistingSegments.firstWhereOrNull((s) => s.osmWayId == confidentOsmId);
    }

    // B. Fallback réutilisation géométrique (hors-piste)
    if (bestMatch == null) {
      for (final existing in nearbyExistingSegments) {
        if (existing.osmWayId != null) continue; // On ne mélange pas OSM et géométrie brute

        final coverage = _coverageRatio(points, existing);
        if (coverage > 0.75) {
          // Vérification altimétrique
          if ((existing.avgAltitude - avgAlt).abs() <= config.altitudeFusionThresholdMeters) {
            bestMatch = existing;
            break;
          }
        }
      }
    }

    if (bestMatch != null) {
      bestMatch.passageCount += 1;
      bestMatch.updatedAt = DateTime.now();

      return _BuiltSegment(
        segment: bestMatch,
        reusedExisting: true,
        traveledForward: _isTraveledForward(points, bestMatch.points),
        sliceDistanceMeters: distance,
        sliceElevationGainMeters: elevResult.gain,
        sliceElevationLossMeters: elevResult.loss,
      );
    }

    // Création d'un nouveau segment
    final isOffRoad = !matchedSlice.first.isConfident;
    final startNode = matchedSlice.first.osmNodeId ?? _uuid.v4();
    final endNode = matchedSlice.last.osmNodeId ?? _uuid.v4();

    final newSegment = Segment()
      ..localUuid = _uuid.v4()
      ..authorUuid = ownerUuid
      ..points = points
      ..mode = isOffRoad ? SegmentMode.offPath : SegmentMode.routed
      ..isOffRoad = isOffRoad
      ..osmWayId = isOffRoad ? null : matchedSlice.first.osmWayId
      ..startNodeId = startNode
      ..endNodeId = endNode
      ..avgAltitude = avgAlt
      ..distanceMeters = distance
      ..elevationGainMeters = elevResult.gain
      ..elevationLossMeters = elevResult.loss
      ..difficulty = _estimateDifficulty(distance, elevResult.gain)
      ..passageCount = 1
      ..lastPassageAt = slice.last.time
      ..minLat = bbox.minLat
      ..maxLat = bbox.maxLat
      ..minLon = bbox.minLon
      ..maxLon = bbox.maxLon
      ..geohashPrefix =
          GeoUtils.geohash(points.first.latitude, points.first.longitude)
      ..syncStatus = SyncStatus.pending
      ..createdAt = DateTime.now()
      ..updatedAt = DateTime.now();

    return _BuiltSegment(
      segment: newSegment,
      reusedExisting: false,
      traveledForward: true,
      sliceDistanceMeters: distance,
      sliceElevationGainMeters: elevResult.gain,
      sliceElevationLossMeters: elevResult.loss,
    );
  }

  /// Mode actif selon les bascules aimant à l'instant [time] (le dernier
  /// override dont l'horodatage est `<= time`), ou `null` si aucune
  /// bascule n'a encore eu lieu à ce moment (dans ce cas,
  /// `_buildSegmentForSlice` retombe sur l'heuristique de recouvrement
  /// habituelle).
  SegmentMode? _activeOverrideMode(DateTime time, List<ModeOverride> sortedOverrides) {
    SegmentMode? active;
    for (final o in sortedOverrides) {
      if (o.at.isAfter(time)) break;
      active = o.mode;
    }
    return active;
  }

  /// Index du point le plus proche de (lat, lon), si a moins de
  /// maxDistanceMeters. Cout O(n) par waypoint : acceptable pour les
  /// tailles de fichiers GPX de randonnee habituelles (quelques milliers
  /// de points, quelques dizaines de waypoints) ; a optimiser avec un
  /// index spatial dedie si des imports massifs (multi-jours) le
  /// justifient.
  int? _nearestPointIndex(
    List<GpxTrackPoint> points,
    double lat,
    double lon,
    double maxDistanceMeters,
  ) {
    int? bestIdx;
    var bestDist = double.infinity;
    for (var i = 0; i < points.length; i++) {
      final d = GeoUtils.haversineMeters(
        points[i].latitude,
        points[i].longitude,
        lat,
        lon,
      );
      if (d < bestDist) {
        bestDist = d;
        bestIdx = i;
      }
    }
    return (bestDist <= maxDistanceMeters) ? bestIdx : null;
  }

  Set<int> _mergeCloseCuts(Set<int> cuts, int pointCount) {
    final sorted = cuts.toList()..sort();
    final merged = <int>{sorted.first};
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i] - merged.last >= config.minSegmentPoints ||
          sorted[i] == pointCount - 1) {
        merged.add(sorted[i]);
      }
    }
    merged.add(pointCount - 1); // garantit toujours la borne finale
    return merged;
  }

  // -----------------------------------------------------------------
  // Construction d'un segment pour une tranche de points
  // -----------------------------------------------------------------

  _BuiltSegment _buildSegmentForSlice(
    List<GpxTrackPoint> slice,
    List<Segment> nearbyExistingSegments,
    String ownerUuid,
    List<ModeOverride> sortedOverrides,
  ) {
    final points = slice
        .map((p) => PointGPS.create(
              latitude: p.latitude,
              longitude: p.longitude,
              altitude: p.elevation,
              timestamp: p.time ?? DateTime.now(),
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

    final elevResult = GeoUtils.elevationGainLoss(
      points.map((p) => p.altitude).toList(),
      noiseThresholdMeters: config.elevationNoiseThresholdMeters,
    );

    final bbox = GeoUtils.boundingBox(
      points.map((p) => (lat: p.latitude, lon: p.longitude)),
    )!;

    Segment? bestMatch;
    double bestCoverage = 0;
    for (final existing in nearbyExistingSegments) {
      final coverage = _coverageRatio(points, existing);
      if (coverage > bestCoverage) {
        bestCoverage = coverage;
        bestMatch = existing;
      }
    }

    if (bestMatch != null && bestCoverage >= config.matchCoverageThreshold) {
      final lengthRatio = distance / max(bestMatch.distanceMeters, 1);
      final withinLengthTolerance =
          (lengthRatio - 1).abs() <= config.matchLengthToleranceRatio;
      if (withinLengthTolerance) {
        // Reutilisation : la geometrie stockee ne change pas (le
        // premier enregistrement local reste la reference), seules les
        // metadonnees de frequentation evoluent.
        bestMatch.passageCount += 1;
        final sliceEnd = slice.last.time;
        if (sliceEnd != null &&
            (bestMatch.lastPassageAt == null ||
                sliceEnd.isAfter(bestMatch.lastPassageAt!))) {
          bestMatch.lastPassageAt = sliceEnd;
        }
        bestMatch.updatedAt = DateTime.now();

        return _BuiltSegment(
          segment: bestMatch,
          reusedExisting: true,
          traveledForward: _isTraveledForward(points, bestMatch.points),
          sliceDistanceMeters: distance,
          sliceElevationGainMeters: elevResult.gain,
          sliceElevationLossMeters: elevResult.loss,
        );
      }
    }

    final mode = _activeOverrideMode(slice.first.time ?? DateTime.now(), sortedOverrides) ??
        (bestCoverage >= config.partialRoutedThreshold
            ? SegmentMode.routed
            : SegmentMode.offPath);

    final newSegment = Segment()
      ..localUuid = _uuid.v4()
      ..authorUuid = ownerUuid
      ..points = points
      ..mode = mode
      ..distanceMeters = distance
      ..elevationGainMeters = elevResult.gain
      ..elevationLossMeters = elevResult.loss
      ..difficulty = _estimateDifficulty(distance, elevResult.gain)
      ..passageCount = 1
      ..lastPassageAt = slice.last.time
      ..minLat = bbox.minLat
      ..maxLat = bbox.maxLat
      ..minLon = bbox.minLon
      ..maxLon = bbox.maxLon
      ..geohashPrefix =
          GeoUtils.geohash(points.first.latitude, points.first.longitude)
      ..syncStatus = SyncStatus.pending
      ..createdAt = DateTime.now()
      ..updatedAt = DateTime.now();

    return _BuiltSegment(
      segment: newSegment,
      reusedExisting: false,
      traveledForward: true,
      sliceDistanceMeters: distance,
      sliceElevationGainMeters: elevResult.gain,
      sliceElevationLossMeters: elevResult.loss,
    );
  }

  /// Fraction des points de [points] situes a moins de
  /// SegmentationConfig.intersectionBufferMeters (ou parallelBufferMeters) du polyligne du segment
  /// [existing].
  double _coverageRatio(List<PointGPS> points, Segment existing) {
    if (points.isEmpty || existing.points.isEmpty) return 0;
    final polyline =
        existing.points.map((p) => (lat: p.latitude, lon: p.longitude)).toList();
    var close = 0;
    for (final p in points) {
      final d = GeoUtils.distancePointToPolylineMeters(
        p.latitude,
        p.longitude,
        polyline,
      );
      
      // On utilise le buffer offRoad pour la fusion géométrique.
      if (d <= config.offRoadSnapBufferMeters) close++;
    }
    return close / points.length;
  }

  bool _isTraveledForward(
    List<PointGPS> newPoints,
    List<PointGPS> existingPoints,
  ) {
    final newStart = newPoints.first;
    final existingStart = existingPoints.first;
    final existingEnd = existingPoints.last;
    final dToStart = GeoUtils.haversineMeters(
      newStart.latitude,
      newStart.longitude,
      existingStart.latitude,
      existingStart.longitude,
    );
    final dToEnd = GeoUtils.haversineMeters(
      newStart.latitude,
      newStart.longitude,
      existingEnd.latitude,
      existingEnd.longitude,
    );
    return dToStart <= dToEnd;
  }

  /// Estimation naive de la difficulte a partir de la pente moyenne
  /// (denivele positif / distance). Volontairement simple : ne prend pas
  /// en compte l'exposition, la nature du terrain (eboulis, neve...) ni
  /// la technicite, et n'a pas vocation a remplacer une evaluation
  /// communautaire ou experte affinee cote serveur.
  DifficultyLevel _estimateDifficulty(double distanceMeters, double gainMeters) {
    if (distanceMeters <= 0) return DifficultyLevel.easy;
    final grade = gainMeters / distanceMeters;
    if (grade < 0.05) return DifficultyLevel.easy;
    if (grade < 0.10) return DifficultyLevel.moderate;
    if (grade < 0.15) return DifficultyLevel.difficult;
    if (grade < 0.25) return DifficultyLevel.veryDifficult;
    return DifficultyLevel.expert;
  }

  // -----------------------------------------------------------------
  // Rattachement des waypoints GPX aux segments
  // -----------------------------------------------------------------

  /// Retrouve, pour un `<wpt>` GPX donne, le [Waypoint] local deja indexe
  /// qui lui correspond (voir GpxScannerService, indexation rapide) ainsi
  /// que l'index du point de trace le plus proche, qui determine a quel
  /// segment issu du decoupage ce waypoint sera rattache. Retourne `null`
  /// si aucun Waypoint local ne correspond (indexation pas encore faite)
  /// ou si le point est trop loin de la trace : dans ce cas, ce `<wpt>`
  /// n'est simplement pas rattache, sans creer de doublon.
  _WaypointResolution? _resolveWaypointForAttachment(
    GpxWaypoint wpt,
    List<GpxTrackPoint> cleaned,
    List<Waypoint> nearbyExistingWaypoints,
  ) {
    Waypoint? match;
    var bestDist = double.infinity;
    for (final existing in nearbyExistingWaypoints) {
      final d = GeoUtils.haversineMeters(
        wpt.latitude,
        wpt.longitude,
        existing.latitude,
        existing.longitude,
      );
      if (d <= config.waypointAttachBufferMeters && d < bestDist) {
        bestDist = d;
        match = existing;
      }
    }
    if (match == null) return null;

    final pointIndex = _nearestPointIndex(
      cleaned,
      wpt.latitude,
      wpt.longitude,
      config.waypointAttachBufferMeters,
    );
    if (pointIndex == null) return null;

    return _WaypointResolution(waypointUuid: match.localUuid, pointIndex: pointIndex);
  }

  String _formatDate(DateTime date) {
    final d = date.day.toString().padLeft(2, '0');
    final m = date.month.toString().padLeft(2, '0');
    return '$d/$m/${date.year}';
  }
}

class _WaypointResolution {
  _WaypointResolution({required this.waypointUuid, required this.pointIndex});
  final String waypointUuid;
  final int pointIndex;
}

class _BuiltSegment {
  _BuiltSegment({
    required this.segment,
    required this.reusedExisting,
    required this.traveledForward,
    required this.sliceDistanceMeters,
    required this.sliceElevationGainMeters,
    required this.sliceElevationLossMeters,
  });

  final Segment segment;
  final bool reusedExisting;
  final bool traveledForward;

  /// Distance/denivele REELLEMENT mesures sur cette tranche precise, a
  /// utiliser pour les totaux de la Trace, y compris en cas de
  /// reutilisation d'un segment existant, dont les propres metadonnees
  /// (distanceMeters...) refletent son tout premier enregistrement et
  /// peuvent differer legerement de ce passage-ci (bruit GPS).
  final double sliceDistanceMeters;
  final double sliceElevationGainMeters;
  final double sliceElevationLossMeters;
}

extension _AverageList on Iterable<double?> {
  double average() {
    final list = whereType<double>().toList();
    if (list.isEmpty) return 0;
    return list.reduce((a, b) => a + b) / list.length;
  }
}
