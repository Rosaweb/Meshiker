import 'dart:math';

import 'package:flutter/foundation.dart';

import '../database/isar_service.dart';
import '../gpx/gpx_models.dart';
import '../models/trace.dart';
import '../utils/elevation_fallback_service.dart';
import '../utils/geo_utils.dart';
import 'terrain_overpass_service.dart';

/// Un objet OSM déjà classé géométriquement par rapport à la trace
/// (croisement/longement/point proche), avec sa position le long du
/// parcours — brique interne utilisée pour construire à la fois les
/// segments quantifiés, la portion `preview` et les listes
/// `points_interet`/`points_eau` renvoyées par [TerrainAnalysisService].
/// Public (pas `_`-préfixée) uniquement pour rester testable depuis
/// `test/assistant/terrain_analysis_service_test.dart` — cf.
/// [TerrainAnalysisService.classifyElements].
class ClassifiedTerrainElement {
  ClassifiedTerrainElement({
    required this.element,
    required this.relation,
    required this.distanceM,
    this.side,
    this.lengthM,
    this.runStartM,
    this.runEndM,
    this.name,
  });

  final TerrainOsmElement element;

  /// `'croisement'`, `'longement'` ou `'point_proche'`.
  final String relation;

  /// Distance le long de la ROUTE (m, relative au début de la fenêtre
  /// analysée) — pour `'longement'`, le milieu du tronçon longé.
  final double distanceM;

  /// `'gauche'`/`'droite'` — uniquement pour `point_proche` (et les
  /// croisements ponctuels de node), jamais recalculé côté Gemini (cf.
  /// guardrail §4 de la spec).
  final String? side;

  final double? lengthM;
  final double? runStartM;
  final double? runEndM;
  final String? name;
}

/// Lecture géographique de la trace active du roadmap, enrichie par
/// OpenStreetMap (Overpass), pour l'assistant IA conversationnel —
/// implémentation de `spec-assistant-terrain-topo.md` (Desktop\Meshiker).
///
/// Calcul strictement à la demande (jamais au moment de l'import, cf. §2 de
/// la spec) : appelé uniquement depuis le tool-calling de `AssistantService`
/// quand une question porte sur le terrain/l'itinéraire. Fournit des FAITS
/// STRUCTURÉS ; c'est Gemini qui rédige la description en langage naturel
/// (§2, §4 de la spec) — cette classe ne produit jamais de phrase toute
/// faite.
///
/// Deux écarts assumés par rapport au schéma JSON illustratif de la spec
/// (§3.6), documentés dans le commit qui introduit ce fichier :
/// - `landcover_tags` renvoie le(s) tag(s) OSM bruts dominants (ex.
///   `"natural=wood"`) plutôt qu'un nom déjà traduit en français
///   (`"forêt"`) — cohérent avec le principe même de la spec ("l'app ne
///   maintient pas de table tag → phrase, Gemini connaît déjà le sens des
///   tags").
/// - `preview` renvoie une tendance qualitative + une liste de noms
///   d'éléments notables, pas une phrase pré-rédigée — même raison, c'est
///   à Gemini de formuler.
class TerrainAnalysisService {
  TerrainAnalysisService({required this.isarService});

  final IsarService isarService;

  static const double defaultMaxDistanceM = 45000;
  static const double defaultDetailedLimitM = 25000;

  static const double _bufferMeters = 40;
  static const double _simplifyToleranceMeters = 15;
  static const double _crossingDistanceMeters = 15;
  static const double _parallelMinRunMeters = 150;
  static const int _maxPointsOfInterest = 40;
  static const double _resampleStepMeters = 200;
  static const double _elevationNoiseThresholdMeters = 4; // par pas de rééchantillonnage (~200 m)
  static const double _minTerrainSegmentMeters = 1000;
  static const double _rawElevationCoverageThreshold = 0.8;

  /// Clés considérées comme "nature du terrain traversé" pour
  /// `landcover_tags` — sous-ensemble de [kTerrainOverpassKeys] : les
  /// autres clés (historic, tourism, leisure, barrier, bridge, tunnel,
  /// ford, man_made, railway) décrivent plutôt des points d'intérêt
  /// ponctuels ou des croisements que le terrain "de fond".
  static const _landcoverKeys = {'natural', 'landuse', 'highway', 'waterway'};

  /// Liste noire courte de tags bruyants (§3.4 de la spec) — volontairement
  /// courte plutôt qu'une liste blanche condamnée à devenir obsolète.
  static const _blacklist = <(String, String)>[
    ('barrier', 'fence'),
    ('natural', 'tree'),
  ];

  /// Tags identifiant un point d'eau exploitable par un randonneur —
  /// catégorisation factuelle bornée (pas une table tag → phrase), utilisée
  /// uniquement pour router ces éléments vers `points_eau` plutôt que
  /// `points_interet`. `amenity` n'est pas dans [kTerrainOverpassKeys] (la
  /// spec ne le liste pas) mais `amenity=drinking_water` est le tag le plus
  /// courant pour un point d'eau potable en randonnée — l'omettre viderait
  /// `points_eau` de son cas d'usage principal.
  static const _waterTags = <(String, String)>[
    ('natural', 'spring'),
    ('man_made', 'water_well'),
    ('man_made', 'water_tap'),
    ('amenity', 'drinking_water'),
    ('amenity', 'water_point'),
  ];

  /// Cache mémoire, clé = trace + version (`updatedAt`) + fenêtre demandée
  /// (§3.7 de la spec — emplacement Isar vs Supabase laissé en point ouvert
  /// §8.4 ; mémoire seule en v1, même choix que `OsmPoiCache` pour Overpass
  /// POI carte : pas de multi-device à couvrir pour l'instant, et
  /// `updatedAt` est déjà le signal de version utilisé ailleurs dans le
  /// code pour la sync — invalide automatiquement le cache à la
  /// modification/inversion de la trace sans logique dédiée).
  final Map<String, Map<String, dynamic>> _cache = {};

  Future<Map<String, dynamic>> describeRouteSegment({
    required Trace trace,
    required double fromDistanceM,
    double? maxDistanceM,
    double? detailedLimitM,
  }) async {
    final maxDist = (maxDistanceM ?? defaultMaxDistanceM).clamp(1000, 100000).toDouble();
    final detailedLimit = (detailedLimitM ?? defaultDetailedLimitM).clamp(500, maxDist).toDouble();

    final cacheKey = '${trace.localUuid}|${trace.updatedAt.millisecondsSinceEpoch}|'
        '${fromDistanceM.round()}|${maxDist.round()}|${detailedLimit.round()}';
    final cached = _cache[cacheKey];
    if (cached != null) return cached;

    final result = await _compute(trace, fromDistanceM, maxDist, detailedLimit);
    _cache[cacheKey] = result;
    return result;
  }

  Future<Map<String, dynamic>> _compute(
    Trace trace,
    double fromDistanceM,
    double maxDistanceM,
    double detailedLimitM,
  ) async {
    final trackPoints = await isarService.getTraceTrackPoints(trace);
    if (trackPoints.length < 2) {
      return {
        'itineraire_disponible': false,
        'message': "Trace introuvable ou trop courte pour être analysée.",
      };
    }

    final cum = List<double>.filled(trackPoints.length, 0);
    for (var i = 1; i < trackPoints.length; i++) {
      cum[i] = cum[i - 1] +
          GeoUtils.haversineMeters(
            trackPoints[i - 1].latitude,
            trackPoints[i - 1].longitude,
            trackPoints[i].latitude,
            trackPoints[i].longitude,
          );
    }
    final totalDistanceM = cum.last;

    final windowStart = fromDistanceM.clamp(0, totalDistanceM).toDouble();
    final windowEnd = (windowStart + maxDistanceM).clamp(0, totalDistanceM).toDouble();
    if (windowEnd - windowStart < 50) {
      return {
        'itineraire_disponible': false,
        'message': "Il reste moins de 50 m avant la fin de l'itinéraire : rien de significatif à décrire.",
      };
    }
    final windowEndRel = windowEnd - windowStart;
    final detailedEndRel = detailedLimitM.clamp(0, windowEndRel).toDouble();

    final startIdx = _lastIndexAtOrBefore(cum, windowStart);
    final endIdx = _firstIndexAtOrAfter(cum, windowEnd);
    final windowPoints = trackPoints.sublist(startIdx, endIdx + 1);
    final windowCum = [
      for (final d in cum.sublist(startIdx, endIdx + 1)) max(0.0, d - windowStart),
    ];
    if (windowPoints.length < 2) {
      return {
        'itineraire_disponible': false,
        'message': "Il reste moins de 50 m avant la fin de l'itinéraire : rien de significatif à décrire.",
      };
    }

    final profile = await _buildElevationProfile(windowPoints, windowCum, windowEndRel);

    final routePolyline = [for (final p in windowPoints) (lat: p.latitude, lon: p.longitude)];
    final simplified = GeoUtils.simplifyDouglasPeucker(routePolyline, _simplifyToleranceMeters);
    final rawElements = await TerrainOverpassService.fetchElementsAroundPath(
      simplifiedPolyline: simplified,
      bufferMeters: _bufferMeters,
    );
    final classified = TerrainAnalysisService.classifyElements(rawElements, routePolyline);

    final waterElements = classified.where((c) => _isWaterElement(c.element.tags)).toList();
    final poiElements = classified.where((c) => !_isWaterElement(c.element.tags)).toList()
      ..sort((a, b) {
        final aNamed = a.name != null ? 0 : 1;
        final bNamed = b.name != null ? 0 : 1;
        if (aNamed != bNamed) return aNamed - bNamed;
        return a.distanceM.compareTo(b.distanceM);
      });
    final cappedPoi = poiElements.take(_maxPointsOfInterest).toList();

    final segments = _buildTerrainSegments(profile.distances, profile.smoothed, detailedEndRel, classified);
    final preview = windowEndRel - detailedEndRel >= 500
        ? _buildPreview(profile.distances, profile.smoothed, detailedEndRel, windowEndRel, classified)
        : null;

    return {
      'itineraire_disponible': true,
      'analysis_window_m': windowEndRel.round(),
      'detailed_limit_m': detailedEndRel.round(),
      'altitude_source': profile.usedFallback ? 'estimee' : 'mesuree',
      'segments': segments,
      if (preview != null) 'preview': preview,
      'points_interet': cappedPoi.map(_poiToJson).toList(),
      'points_eau': waterElements.map(_waterToJson).toList(),
    };
  }

  // --- Étape 1 : profil altimétrique (rééchantillonné + lissé) ---

  Future<({List<double> distances, List<double> smoothed, bool usedFallback})> _buildElevationProfile(
    List<GpxTrackPoint> windowPoints,
    List<double> windowCum,
    double windowEndRel,
  ) async {
    final stepCount = (windowEndRel / _resampleStepMeters).ceil() + 1;
    final distances = [for (var i = 0; i < stepCount; i++) min(i * _resampleStepMeters, windowEndRel)];

    final rawSamples = <({double lat, double lon, double? elevation})>[];
    var segIdx = 0;
    for (final d in distances) {
      while (segIdx < windowCum.length - 2 && windowCum[segIdx + 1] < d) {
        segIdx++;
      }
      final d0 = windowCum[segIdx];
      final d1 = windowCum[segIdx + 1];
      final t = (d1 - d0) <= 0 ? 0.0 : ((d - d0) / (d1 - d0)).clamp(0.0, 1.0);
      final p0 = windowPoints[segIdx];
      final p1 = windowPoints[segIdx + 1];
      final lat = p0.latitude + t * (p1.latitude - p0.latitude);
      final lon = p0.longitude + t * (p1.longitude - p0.longitude);
      double? elevation;
      if (p0.elevation != null && p1.elevation != null) {
        elevation = p0.elevation! + t * (p1.elevation! - p0.elevation!);
      } else if (t < 0.5 && p0.elevation != null) {
        elevation = p0.elevation;
      } else if (t >= 0.5 && p1.elevation != null) {
        elevation = p1.elevation;
      }
      rawSamples.add((lat: lat, lon: lon, elevation: elevation));
    }

    final knownCount = rawSamples.where((s) => s.elevation != null).length;
    var usedFallback = false;
    var elevations = rawSamples.map((s) => s.elevation).toList();

    if (rawSamples.isNotEmpty && knownCount / rawSamples.length < _rawElevationCoverageThreshold) {
      final fallback = await ElevationFallbackService.fetchElevations(
        rawSamples.map((s) => (lat: s.lat, lon: s.lon)).toList(),
      );
      if (fallback.any((e) => e != null)) {
        usedFallback = true;
        elevations = [for (var i = 0; i < elevations.length; i++) elevations[i] ?? fallback[i]];
      }
    }

    final filled = _fillGaps(elevations);
    final smoothed = _movingAverage(filled, windowRadius: 1);
    return (distances: distances, smoothed: smoothed, usedFallback: usedFallback);
  }

  static List<double> _fillGaps(List<double?> values) {
    final n = values.length;
    final result = List<double>.filled(n, 0);
    final knownIdx = [for (var i = 0; i < n; i++) if (values[i] != null) i];
    if (knownIdx.isEmpty) return result; // aucune altitude nulle part : profil plat par défaut

    for (var i = 0; i <= knownIdx.first; i++) {
      result[i] = values[knownIdx.first]!;
    }
    for (var k = 0; k < knownIdx.length - 1; k++) {
      final i0 = knownIdx[k];
      final i1 = knownIdx[k + 1];
      final v0 = values[i0]!;
      final v1 = values[i1]!;
      for (var i = i0; i <= i1; i++) {
        final t = i1 == i0 ? 0.0 : (i - i0) / (i1 - i0);
        result[i] = v0 + t * (v1 - v0);
      }
    }
    for (var i = knownIdx.last; i < n; i++) {
      result[i] = values[knownIdx.last]!;
    }
    return result;
  }

  static List<double> _movingAverage(List<double> values, {required int windowRadius}) {
    final n = values.length;
    final result = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final lo = max(0, i - windowRadius);
      final hi = min(n - 1, i + windowRadius);
      var sum = 0.0;
      for (var j = lo; j <= hi; j++) {
        sum += values[j];
      }
      result[i] = sum / (hi - lo + 1);
    }
    return result;
  }

  // --- Étape 2/3/4 : requête Overpass déjà faite par l'appelant, ici le
  // filtrage de pertinence + la classification géométrique (§3.4/§3.5) ---

  /// Public et `@visibleForTesting` uniquement : la classification
  /// géométrique (croisement/longement/point proche + côté gauche/droite)
  /// est la partie la plus délicate de ce pipeline — testée directement
  /// dans `test/assistant/terrain_analysis_service_test.dart` sans dépendre
  /// d'Isar ni du réseau (Overpass), qui alimentent [describeRouteSegment]
  /// mais ne sont pas nécessaires pour valider la géométrie elle-même.
  @visibleForTesting
  static List<ClassifiedTerrainElement> classifyElements(
    List<TerrainOsmElement> elements,
    List<({double lat, double lon})> routePolyline,
  ) {
    final result = <ClassifiedTerrainElement>[];
    for (final el in elements) {
      if (_isBlacklisted(el.tags)) continue;
      final name = el.tags['name'];

      if (!el.isWay) {
        final p = el.geometry.first;
        final snap = GeoUtils.snapToPolyline(p.lat, p.lon, routePolyline, _bufferMeters * 3);
        if (snap == null) continue;
        final distM = GeoUtils.distanceToSnapMeters(routePolyline, snap);
        final actualDist = GeoUtils.haversineMeters(p.lat, p.lon, snap.lat, snap.lon);
        final relation = actualDist <= _crossingDistanceMeters ? 'croisement' : 'point_proche';
        final side = relation == 'point_proche' ? _sideOf(routePolyline, snap, p) : null;
        result.add(ClassifiedTerrainElement(element: el, relation: relation, distanceM: distM, side: side, name: name));
        continue;
      }

      final classifiedWay = _classifyWay(el, routePolyline, name);
      if (classifiedWay != null) result.add(classifiedWay);
    }
    return result;
  }

  static ClassifiedTerrainElement? _classifyWay(
    TerrainOsmElement el,
    List<({double lat, double lon})> routePolyline,
    String? name,
  ) {
    // Croisement : échantillonnage de chaque arête du way (pas seulement
    // ses sommets, potentiellement espacés de plusieurs dizaines de mètres)
    // à la recherche d'un point tombant très près de la route.
    for (var i = 0; i < el.geometry.length - 1; i++) {
      final a = el.geometry[i];
      final b = el.geometry[i + 1];
      for (var s = 0; s <= 4; s++) {
        final t = s / 4;
        final lat = a.lat + t * (b.lat - a.lat);
        final lon = a.lon + t * (b.lon - a.lon);
        if (GeoUtils.distancePointToPolylineMeters(lat, lon, routePolyline) <= _crossingDistanceMeters) {
          final snap = GeoUtils.snapToPolyline(lat, lon, routePolyline, _bufferMeters * 3);
          if (snap != null) {
            final distM = GeoUtils.distanceToSnapMeters(routePolyline, snap);
            return ClassifiedTerrainElement(element: el, relation: 'croisement', distanceM: distM, name: name);
          }
        }
      }
    }

    // Longement : plus long tronçon consécutif de sommets du way restés à
    // moins de `_bufferMeters` de la route.
    final vertexDistances =
        el.geometry.map((v) => GeoUtils.distancePointToPolylineMeters(v.lat, v.lon, routePolyline)).toList();
    var bestStart = -1, bestEnd = -1, curStart = -1;
    for (var i = 0; i < vertexDistances.length; i++) {
      if (vertexDistances[i] <= _bufferMeters) {
        curStart = curStart == -1 ? i : curStart;
      } else if (curStart != -1) {
        if (bestStart == -1 || (i - 1 - curStart) > (bestEnd - bestStart)) {
          bestStart = curStart;
          bestEnd = i - 1;
        }
        curStart = -1;
      }
    }
    if (curStart != -1) {
      final end = vertexDistances.length - 1;
      if (bestStart == -1 || (end - curStart) > (bestEnd - bestStart)) {
        bestStart = curStart;
        bestEnd = end;
      }
    }

    if (bestStart != -1 && bestEnd > bestStart) {
      final runVertices = el.geometry.sublist(bestStart, bestEnd + 1);
      final runLength = GeoUtils.polylineLengthMeters(runVertices);
      if (runLength >= _parallelMinRunMeters) {
        final mid = runVertices[runVertices.length ~/ 2];
        final midSnap = GeoUtils.snapToPolyline(mid.lat, mid.lon, routePolyline, _bufferMeters * 3);
        if (midSnap != null) {
          final distM = GeoUtils.distanceToSnapMeters(routePolyline, midSnap);
          final startSnap =
              GeoUtils.snapToPolyline(runVertices.first.lat, runVertices.first.lon, routePolyline, _bufferMeters * 3);
          final endSnap =
              GeoUtils.snapToPolyline(runVertices.last.lat, runVertices.last.lon, routePolyline, _bufferMeters * 3);
          final runStartM =
              startSnap != null ? GeoUtils.distanceToSnapMeters(routePolyline, startSnap) : distM;
          final runEndM = endSnap != null ? GeoUtils.distanceToSnapMeters(routePolyline, endSnap) : distM;
          return ClassifiedTerrainElement(
            element: el,
            relation: 'longement',
            distanceM: distM,
            lengthM: runLength,
            runStartM: min(runStartM, runEndM),
            runEndM: max(runStartM, runEndM),
            name: name,
          );
        }
      }
    }

    // Repli : point le plus proche du way, s'il reste raisonnablement près
    // du corridor (le buffer Overpass est géodésique, la simplification
    // Douglas-Peucker a pu légèrement en décaler les bords).
    var nearestIdx = 0;
    var nearestDist = double.infinity;
    for (var i = 0; i < vertexDistances.length; i++) {
      if (vertexDistances[i] < nearestDist) {
        nearestDist = vertexDistances[i];
        nearestIdx = i;
      }
    }
    if (nearestDist > _bufferMeters * 1.5) return null;
    final nearest = el.geometry[nearestIdx];
    final snap = GeoUtils.snapToPolyline(nearest.lat, nearest.lon, routePolyline, _bufferMeters * 3);
    if (snap == null) return null;
    final distM = GeoUtils.distanceToSnapMeters(routePolyline, snap);
    final side = _sideOf(routePolyline, snap, nearest);
    return ClassifiedTerrainElement(element: el, relation: 'point_proche', distanceM: distM, side: side, name: name);
  }

  static String _sideOf(
    List<({double lat, double lon})> routePolyline,
    ({double lat, double lon, int segmentIndex, double t}) snap,
    ({double lat, double lon}) target,
  ) {
    final a = routePolyline[snap.segmentIndex];
    final b = routePolyline[min(snap.segmentIndex + 1, routePolyline.length - 1)];
    final heading = GeoUtils.bearingDegrees(a.lat, a.lon, b.lat, b.lon);
    final toTarget = GeoUtils.bearingDegrees(snap.lat, snap.lon, target.lat, target.lon);
    final delta = ((toTarget - heading + 540) % 360) - 180;
    return delta > 0 ? 'droite' : 'gauche';
  }

  static bool _isBlacklisted(Map<String, String> tags) {
    for (final (k, v) in _blacklist) {
      if (tags[k] == v) return true;
    }
    return false;
  }

  static bool _isWaterElement(Map<String, String> tags) {
    for (final (k, v) in _waterTags) {
      if (tags[k] == v) return true;
    }
    return false;
  }

  // --- Étape 5 : structuration pour function calling (§3.6) ---

  List<Map<String, dynamic>> _buildTerrainSegments(
    List<double> distances,
    List<double> smoothed,
    double detailedEndRel,
    List<ClassifiedTerrainElement> classified,
  ) {
    final lastIdx = () {
      final idx = distances.indexWhere((d) => d >= detailedEndRel - 1e-6);
      return idx == -1 ? distances.length - 1 : idx;
    }();
    if (lastIdx < 1) return const [];

    final labels = <String>[];
    for (var i = 0; i < lastIdx; i++) {
      final delta = smoothed[i + 1] - smoothed[i];
      if (delta > _elevationNoiseThresholdMeters) {
        labels.add('montee');
      } else if (delta < -_elevationNoiseThresholdMeters) {
        labels.add('descente');
      } else {
        labels.add('plat');
      }
    }

    final rawSegments = <(int, int, String)>[];
    var segStart = 0;
    for (var i = 1; i <= labels.length; i++) {
      if (i == labels.length || labels[i] != labels[segStart]) {
        rawSegments.add((segStart, i, labels[segStart]));
        segStart = i;
      }
    }

    final merged = <(int, int, String)>[];
    for (final seg in rawSegments) {
      final length = distances[seg.$2] - distances[seg.$1];
      if (length < _minTerrainSegmentMeters && merged.isNotEmpty) {
        final prev = merged.removeLast();
        merged.add((prev.$1, seg.$2, prev.$3));
      } else {
        merged.add(seg);
      }
    }
    if (merged.length > 1) {
      final first = merged.first;
      if (distances[first.$2] - distances[first.$1] < _minTerrainSegmentMeters) {
        final second = merged[1];
        merged[0] = (first.$1, second.$2, second.$3);
        merged.removeAt(1);
      }
    }

    return [
      for (final seg in merged) _segmentToJson(seg.$1, seg.$2, seg.$3, distances, smoothed, classified),
    ];
  }

  Map<String, dynamic> _segmentToJson(
    int startIdx,
    int endIdx,
    String label,
    List<double> distances,
    List<double> smoothed,
    List<ClassifiedTerrainElement> classified,
  ) {
    final startM = distances[startIdx];
    final endM = distances[endIdx];

    double gain = 0, loss = 0;
    for (var i = startIdx; i < endIdx; i++) {
      final delta = smoothed[i + 1] - smoothed[i];
      if (delta > 0) {
        gain += delta;
      } else {
        loss += -delta;
      }
    }

    final weights = <String, double>{};
    for (final c in classified) {
      final key = c.element.tags.keys.firstWhere((k) => _landcoverKeys.contains(k), orElse: () => '');
      if (key.isEmpty) continue;
      final overlaps = c.relation == 'longement'
          ? (c.runStartM! < endM && c.runEndM! > startM)
          : (c.distanceM >= startM && c.distanceM < endM);
      if (!overlaps) continue;
      final tagStr = '$key=${c.element.tags[key]}';
      final weight = c.relation == 'longement' ? (c.lengthM ?? 1) : 1.0;
      weights[tagStr] = (weights[tagStr] ?? 0) + weight;
    }
    final landcoverTags = (weights.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .take(2)
        .map((e) => e.key)
        .toList();

    return {
      'distance_start_m': startM.round(),
      'distance_end_m': endM.round(),
      'terrain': label,
      'landcover_tags': landcoverTags,
      'elevation_gain_m': gain.round(),
      'elevation_loss_m': loss.round(),
    };
  }

  /// Portion au-delà de `detailed_limit_m`, résumée qualitativement (§3.6) —
  /// jamais de distance/dénivelé chiffré, cf. guardrail §4.
  Map<String, dynamic>? _buildPreview(
    List<double> distances,
    List<double> smoothed,
    double detailedEndRel,
    double windowEndRel,
    List<ClassifiedTerrainElement> classified,
  ) {
    final startIdx = distances.indexWhere((d) => d >= detailedEndRel - 1e-6);
    if (startIdx == -1 || startIdx >= distances.length - 1) return null;

    double gain = 0, loss = 0;
    for (var i = startIdx; i < distances.length - 1; i++) {
      final delta = smoothed[i + 1] - smoothed[i];
      if (delta > 0) {
        gain += delta;
      } else {
        loss += -delta;
      }
    }
    final span = windowEndRel - detailedEndRel;

    String tendance;
    if (gain > span * 0.04 && gain > loss * 1.5) {
      tendance = 'ascension_notable';
    } else if (loss > span * 0.04 && loss > gain * 1.5) {
      tendance = 'descente_notable';
    } else if (gain > span * 0.02 || loss > span * 0.02) {
      tendance = 'variee';
    } else {
      tendance = 'plat';
    }

    final noms = classified
        .where((c) => c.distanceM >= detailedEndRel && c.distanceM < windowEndRel && c.name != null)
        .map((c) => c.name!)
        .toSet()
        .take(3)
        .toList();

    return {
      'distance_start_m': detailedEndRel.round(),
      'distance_end_m': windowEndRel.round(),
      'tendance': tendance,
      'elements_notables': noms,
    };
  }

  Map<String, dynamic> _poiToJson(ClassifiedTerrainElement c) {
    final key = c.element.tags.keys.firstWhere(
      (k) => kTerrainOverpassKeys.contains(k) || k == 'amenity',
      orElse: () => c.element.tags.keys.first,
    );
    return {
      'distance_m': c.distanceM.round(),
      'type': key,
      'valeur': c.element.tags[key],
      'relation': c.relation,
      if (c.side != null) 'cote': c.side,
      if (c.lengthM != null) 'longueur_m': c.lengthM!.round(),
      if (c.name != null) 'nom': c.name,
    };
  }

  Map<String, dynamic> _waterToJson(ClassifiedTerrainElement c) {
    final match = _waterTags.firstWhere((t) => c.element.tags[t.$1] == t.$2, orElse: () => ('', ''));
    final key = match.$1.isEmpty ? c.element.tags.keys.first : match.$1;
    return {
      'distance_m': c.distanceM.round(),
      'type': key,
      'valeur': c.element.tags[key],
      if (c.name != null) 'nom': c.name,
    };
  }

  // --- Recherche par dichotomie sur la distance cumulée (croissante) ---

  static int _lastIndexAtOrBefore(List<double> cum, double target) {
    var lo = 0, hi = cum.length - 1;
    if (target <= cum[0]) return 0;
    if (target >= cum[hi]) return hi;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (cum[mid] <= target) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  static int _firstIndexAtOrAfter(List<double> cum, double target) {
    var lo = 0, hi = cum.length - 1;
    if (target <= cum[0]) return 0;
    if (target >= cum[hi]) return hi;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] >= target) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }
}
