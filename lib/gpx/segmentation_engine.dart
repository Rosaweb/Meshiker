import 'dart:math';

import 'package:uuid/uuid.dart';

import '../models/enums.dart';
import '../models/gps_point.dart';
import '../models/point_of_interest.dart';
import '../models/segment.dart';
import '../models/trace.dart';
import '../models/trace_segment_entry.dart';
import '../search/text_normalizer.dart';
import '../utils/geo_utils.dart';
import 'gpx_models.dart';

const _uuid = Uuid();

/// Réglages du découpage.
///
/// Les valeurs par défaut suivent les ordres de grandeur du brief (buffer
/// de fusion "5 à 10 mètres") : [intersectionBufferMeters] vaut 8 m par
/// défaut, cohérent avec le buffer spatial qu'utilisera plus tard la
/// fusion PostGIS côté serveur — la logique locale d'aujourd'hui préfigure
/// volontairement la logique serveur de demain.
class SegmentationConfig {
  const SegmentationConfig({
    this.minPointSpacingMeters = 3.0,
    this.intersectionBufferMeters = 8.0,
    this.poiDedupBufferMeters = 25.0,
    this.poiCutBufferMeters = 25.0,
    this.enablePauseDetection = true,
    this.stopGapDuration = const Duration(minutes: 3),
    this.minSegmentPoints = 3,
    this.matchCoverageThreshold = 0.75,
    this.partialRoutedThreshold = 0.3,
    this.matchLengthToleranceRatio = 0.3,
    this.elevationNoiseThresholdMeters = 2.0,
  });

  /// Distance minimale (m) entre deux points gardes lors du nettoyage
  /// anti-bruit GPS. Les points marquant une rupture de segment GPX sont
  /// toujours conserves, quelle que soit leur distance au point precedent.
  final double minPointSpacingMeters;

  /// Rayon (m) en-deca duquel un point de la nouvelle trace est considere
  /// comme "touchant" un segment deja connu localement.
  final double intersectionBufferMeters;

  /// Rayon (m) pour dedoublonner un waypoint GPX avec un POI deja
  /// enregistre localement (ou avec un autre waypoint du meme fichier).
  final double poiDedupBufferMeters;

  /// Rayon (m) pour decider qu'un point de la trace passe par un POI,
  /// donc qu'il constitue un point de coupure, qu'il soit nouveau ou deja
  /// connu localement.
  final double poiCutBufferMeters;

  /// Active la detection d'arrets prolonges comme points de coupure
  /// implicites (ex : pause dejeuner a un col non balise par un
  /// waypoint). Heuristique qui va au-dela du brief initial
  /// ("intersection ou point d'interet majeur") mais qui ameliore
  /// nettement la qualite du decoupage sur des GPX reels, souvent
  /// depourvus de waypoints explicites.
  final bool enablePauseDetection;
  final Duration stopGapDuration;

  /// Nombre minimal de points entre deux coupures : en-dessous, les
  /// coupures trop rapprochees sont fusionnees pour eviter des
  /// micro-segments degeneres (quelques metres de long).
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
/// frequentation --, les POI a upserter) ainsi que quelques compteurs
/// utiles pour informer l'utilisateur ("6 segments deja connus, 3
/// nouveaux, 2 points d'interet ajoutes").
class SegmentationResult {
  SegmentationResult({
    required this.trace,
    required this.segmentsToUpsert,
    required this.poisToUpsert,
    required this.newSegmentsCount,
    required this.reusedSegmentsCount,
    required this.newPoisCount,
    required this.reusedPoisCount,
  });

  final Trace trace;
  final List<Segment> segmentsToUpsert;
  final List<PointOfInterest> poisToUpsert;
  final int newSegmentsCount;
  final int reusedSegmentsCount;
  final int newPoisCount;
  final int reusedPoisCount;
}

/// Decoupe une trace GPX en segments elementaires, en s'appuyant sur la
/// toile locale deja connue (segments et POI deja enregistres sur
/// l'appareil) pour eviter de dupliquer un chemin deja emprunte.
///
/// Points de coupure retenus, par ordre de priorite :
/// 1. bornes de la trace (premier/dernier point) ;
/// 2. rupture entre deux segments GPX distincts (perte GPS reelle) ;
/// 3. proximite d'un waypoint GPX (POI, nouveau ou deja connu) ;
/// 4. arret prolonge, si SegmentationConfig.enablePauseDetection ;
/// 5. changement de bascule aimant manuelle en cours d'enregistrement
///    (voir ModeOverride, alimente par RecordingService, etape 3).
///
/// Cette classe est volontairement PURE : aucun acces a Isar. C'est
/// l'appelant (voir GpxImportService) qui fournit les segments/POI deja
/// charges depuis la base pour la zone concernee, ce qui rend le moteur
/// facilement testable unitairement, sans base de donnees.
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

  SegmentationResult segment({
    required GpxParseResult gpx,
    required List<Segment> nearbyExistingSegments,
    required List<PointOfInterest> nearbyExistingPois,
    required String ownerUuid,
    String? traceNameOverride,
    ActivityType activityType = ActivityType.hiking,
    List<ModeOverride> modeOverrides = const [],
  }) {
    final cleaned = _cleanPoints(gpx.trackPoints);
    if (cleaned.length < 2) {
      throw ArgumentError(
        'GPX trop court ou entierement filtre : au moins 2 points valides sont requis.',
      );
    }

    final sortedOverrides = List<ModeOverride>.of(modeOverrides)
      ..sort((a, b) => a.at.compareTo(b.at));

    final poiResolutions = <_PoiResolution>[];
    for (final wpt in gpx.waypoints) {
      poiResolutions.add(
        _resolvePoi(wpt, nearbyExistingPois, poiResolutions, ownerUuid),
      );
    }

    final cutIndices = _findForcedCutIndices(cleaned, poiResolutions, sortedOverrides);
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
      final built = _buildSegmentForSlice(
        slice,
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

      traceEntries.add(TraceSegmentEntry.create(
        segmentUuid: built.segment.localUuid,
        orderIndex: i,
        traveledForward: built.traveledForward,
        enteredAt: slice.first.time,
        exitedAt: slice.last.time,
      ));
    }

    final poisToUpsert = poiResolutions.map((r) => r.poi).toList();
    final newPoisCount = poiResolutions.where((r) => !r.reusedExisting).length;
    final reusedPoisCount = poiResolutions.length - newPoisCount;

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
      poisToUpsert: poisToUpsert,
      newSegmentsCount: newSegmentsCount,
      reusedSegmentsCount: reusedSegmentsCount,
      newPoisCount: newPoisCount,
      reusedPoisCount: reusedPoisCount,
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

  Set<int> _findForcedCutIndices(
    List<GpxTrackPoint> points,
    List<_PoiResolution> poiResolutions,
    List<ModeOverride> sortedOverrides,
  ) {
    final cuts = <int>{0, points.length - 1};

    for (var i = 1; i < points.length; i++) {
      if (points[i].startsNewSegment) cuts.add(i);
    }

    for (final poi in poiResolutions) {
      final idx = _nearestPointIndex(
        points,
        poi.poi.latitude,
        poi.poi.longitude,
        config.poiCutBufferMeters,
      );
      if (idx != null) cuts.add(idx);
    }

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

    // Un changement de bascule aimant (routé <-> hors-piste) en cours
    // d'enregistrement (étape 3, RecordingService) force une coupure : un
    // même Segment ne peut pas être moitié routé, moitié hors-piste.
    if (sortedOverrides.isNotEmpty) {
      for (var i = 1; i < points.length; i++) {
        final prevTime = points[i - 1].time;
        final time = points[i].time;
        if (prevTime == null || time == null) continue;
        final prevMode = _activeOverrideMode(prevTime, sortedOverrides);
        final mode = _activeOverrideMode(time, sortedOverrides);
        if (prevMode != mode) cuts.add(i);
      }
    }

    return _mergeCloseCuts(cuts, points.length);
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
  /// maxDistanceMeters. Cout O(n) par POI : acceptable pour les tailles
  /// de fichiers GPX de randonnee habituelles (quelques milliers de
  /// points, quelques dizaines de waypoints) ; a optimiser avec un index
  /// spatial dedie si des imports massifs (multi-jours) le justifient.
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
  /// SegmentationConfig.intersectionBufferMeters du polyligne du segment
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
      if (d <= config.intersectionBufferMeters) close++;
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
  // Points d'interet
  // -----------------------------------------------------------------

  _PoiResolution _resolvePoi(
    GpxWaypoint wpt,
    List<PointOfInterest> nearbyExistingPois,
    List<_PoiResolution> alreadyResolvedInThisImport,
    String ownerUuid,
  ) {
    for (final existing in nearbyExistingPois) {
      final d = GeoUtils.haversineMeters(
        wpt.latitude,
        wpt.longitude,
        existing.latitude,
        existing.longitude,
      );
      if (d <= config.poiDedupBufferMeters) {
        existing.timesReferenced += 1;
        existing.updatedAt = DateTime.now();
        return _PoiResolution(poi: existing, reusedExisting: true);
      }
    }
    // Dedoublonnage egalement au sein du meme fichier (deux waypoints
    // tres proches l'un de l'autre dans le meme import).
    for (final resolved in alreadyResolvedInThisImport) {
      final d = GeoUtils.haversineMeters(
        wpt.latitude,
        wpt.longitude,
        resolved.poi.latitude,
        resolved.poi.longitude,
      );
      if (d <= config.poiDedupBufferMeters) {
        resolved.poi.timesReferenced += 1;
        return _PoiResolution(poi: resolved.poi, reusedExisting: true);
      }
    }

    final poi = PointOfInterest()
      ..localUuid = _uuid.v4()
      ..name = wpt.name ?? "Point d'interet"
      ..description = wpt.description
      ..type = _classifyPoiType(wpt.rawType, wpt.name)
      ..location = PointGPS.create(
        latitude: wpt.latitude,
        longitude: wpt.longitude,
        altitude: wpt.elevation,
        timestamp: DateTime.now(),
      )
      ..latitude = wpt.latitude
      ..longitude = wpt.longitude
      ..geohashPrefix = GeoUtils.geohash(wpt.latitude, wpt.longitude)
      ..timesReferenced = 1
      ..authorUuid = ownerUuid
      ..syncStatus = SyncStatus.pending
      ..createdAt = DateTime.now()
      ..updatedAt = DateTime.now();

    return _PoiResolution(poi: poi, reusedExisting: false);
  }

  /// Classification best-effort a partir du champ type (ou, a defaut, du
  /// nom) du waypoint GPX. Mapping volontairement simple par mots-cles
  /// francais/anglais ; a affiner avec des exemples reels (exports
  /// Garmin/OsmAnd/IGN Rando notamment) avant mise en production.
  POIType _classifyPoiType(String? rawType, String? name) {
    final haystack = TextNormalizer.normalize('${rawType ?? ''} ${name ?? ''}');
    if (haystack.contains('sommet') ||
        haystack.contains('summit') ||
        haystack.contains('peak')) {
      return POIType.summit;
    }
    if (haystack.contains('vue') ||
        haystack.contains('viewpoint') ||
        haystack.contains('panorama')) {
      return POIType.viewpoint;
    }
    if (haystack.contains('eau') ||
        haystack.contains('source') ||
        haystack.contains('water')) {
      return POIType.waterSource;
    }
    if (haystack.contains('camp') || haystack.contains('bivouac')) {
      return POIType.campsite;
    }
    if (haystack.contains('refuge') ||
        haystack.contains('abri') ||
        haystack.contains('shelter')) {
      return POIType.shelter;
    }
    if (haystack.contains('parking')) {
      return POIType.parking;
    }
    if (haystack.contains('danger') || haystack.contains('risque')) {
      return POIType.danger;
    }
    return POIType.other;
  }

  String _formatDate(DateTime date) {
    final d = date.day.toString().padLeft(2, '0');
    final m = date.month.toString().padLeft(2, '0');
    return '$d/$m/${date.year}';
  }
}

class _PoiResolution {
  _PoiResolution({required this.poi, required this.reusedExisting});
  final PointOfInterest poi;
  final bool reusedExisting;
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
