import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../database/isar_service.dart';
import '../gpx/gpx_models.dart';
import '../gpx/segmentation_engine.dart';
import '../gpx/segmentation_persistence.dart';
import '../models/enums.dart';
import '../models/segment.dart';
import '../search/local_search_engine.dart';
import '../utils/geo_utils.dart';

const _uuid = Uuid();

/// Un point du tracé en cours de planification.
class PlanPoint {
  const PlanPoint({
    required this.lat,
    required this.lon,
    required this.time,
    required this.snapped,
  });

  final double lat;
  final double lon;

  /// Horodatage SYNTHÉTIQUE (pas une vraie mesure GPS) : sert uniquement
  /// à ordonner les points et à dater les bascules aimant pour
  /// [SegmentationEngine], qui raisonne sur des horodatages plutôt que
  /// des index (voir `ModeOverride`).
  final DateTime time;

  /// `true` si ce point a été placé par accroche sur un segment déjà
  /// connu (aimant activé), `false` s'il a été posé librement.
  final bool snapped;
}

/// Réglages du mode planification.
class PlanningConfig {
  const PlanningConfig({
    this.snapRadiusMeters = 20.0,
    this.segmentationConfig = const SegmentationConfig(
      // Les taps de planification n'ont pas d'écart de temps réel
      // significatif entre eux : l'heuristique de détection de pause
      // (pensée pour un vrai enregistrement GPS) n'a pas de sens ici.
      enablePauseDetection: false,
    ),
  });

  /// Rayon (m) en-deçà duquel un point tapé s'accroche au segment connu
  /// le plus proche quand l'aimant est activé.
  final double snapRadiusMeters;

  final SegmentationConfig segmentationConfig;
}

/// Pilote le mode planification (dessiner un itinéraire sur la carte sans
/// le marcher, section 3 du brief : "En mode planification, un bouton
/// bascule (aimant activé/désactivé) permet de forcer le tracé
/// hors-piste").
///
/// Réutilise intégralement [SegmentationEngine] (le même moteur que
/// l'import GPX et l'enregistrement en direct) : un plan terminé est
/// simplement un [GpxParseResult] construit à partir des points tapés,
/// avec des [ModeOverride] pour chaque bascule aimant — exactement le
/// mécanisme déjà en place pour `RecordingService`.
///
/// Accroche ("aimant") : quand un point est tapé aimant activé, on le
/// projette sur le segment connu le plus proche ([GeoUtils.snapToPolyline]).
/// Si le point précédent était accroché AU MÊME segment, on insère aussi
/// les sommets intermédiaires du segment ([GeoUtils.subPolylineBetween])
/// pour que le tracé SUIVE la forme réelle du sentier plutôt qu'une ligne
/// droite entre deux taps espacés.
class PlanningController {
  PlanningController({this.config = const PlanningConfig()});

  final PlanningConfig config;

  final ValueNotifier<List<PlanPoint>> points = ValueNotifier(const []);
  final ValueNotifier<bool> magnetEnabled = ValueNotifier(true);

  List<Segment> _candidateSegments = const [];
  ({String segmentUuid, ({double lat, double lon, int segmentIndex, double t}) snap})?
      _lastSnap;
  final List<ModeOverride> _modeOverrides = [];
  final DateTime _baseTime = DateTime.now();

  /// À appeler par l'écran carte à chaque changement de viewport (les
  /// segments proches disponibles pour l'accroche évoluent avec la zone
  /// affichée). Voir `MapViewModel.segments`.
  void updateCandidateSegments(List<Segment> segments) {
    _candidateSegments = segments;
  }

  DateTime _nextTime() => _baseTime.add(Duration(milliseconds: points.value.length * 500));

  /// Bascule l'aimant. Enregistre un [ModeOverride] horodaté, consommé
  /// par [SegmentationEngine] à la finalisation pour forcer une coupure
  /// et le mode de la portion suivante du plan.
  void toggleMagnet() => setMagnetEnabled(!magnetEnabled.value);

  void setMagnetEnabled(bool enabled) {
    if (magnetEnabled.value == enabled) return;
    magnetEnabled.value = enabled;
    _modeOverrides.add(ModeOverride(
      at: _nextTime(),
      mode: enabled ? SegmentMode.routed : SegmentMode.offPath,
    ));
  }

  /// Ajoute un point tapé sur la carte au tracé en cours.
  void addTapPoint(double lat, double lon) {
    final time = _nextTime();

    if (!magnetEnabled.value) {
      _appendRawPoint(lat, lon, time, snapped: false);
      _lastSnap = null;
      return;
    }

    final snapResult = _bestSnap(lat, lon);
    if (snapResult == null) {
      _appendRawPoint(lat, lon, time, snapped: false);
      _lastSnap = null;
      return;
    }

    final (segmentUuid, snap) = snapResult;

    if (_lastSnap != null && _lastSnap!.segmentUuid == segmentUuid) {
      // Même segment que le point précédent : on fait suivre au tracé la
      // forme réelle du sentier entre les deux points projetés, plutôt
      // qu'une ligne droite.
      final existing = _candidateSegments.firstWhere((s) => s.localUuid == segmentUuid);
      final polyline =
          existing.points.map((p) => (lat: p.latitude, lon: p.longitude)).toList();
      final sub = GeoUtils.subPolylineBetween(polyline, _lastSnap!.snap, snap);
      // sub[0] correspond au point precedent, deja present : on l'ignore.
      final toAdd = sub.skip(1).toList();
      final updated = List<PlanPoint>.of(points.value);
      for (var i = 0; i < toAdd.length; i++) {
        updated.add(PlanPoint(
          lat: toAdd[i].lat,
          lon: toAdd[i].lon,
          time: _baseTime.add(Duration(milliseconds: (updated.length + i) * 500)),
          snapped: true,
        ));
      }
      points.value = updated;
    } else {
      _appendRawPoint(snap.lat, snap.lon, time, snapped: true);
    }

    _lastSnap = (segmentUuid: segmentUuid, snap: snap);
  }

  (String, ({double lat, double lon, int segmentIndex, double t}))? _bestSnap(
    double lat,
    double lon,
  ) {
    String? bestUuid;
    ({double lat, double lon, int segmentIndex, double t})? best;
    var bestDist = double.infinity;

    for (final segment in _candidateSegments) {
      final polyline =
          segment.points.map((p) => (lat: p.latitude, lon: p.longitude)).toList();
      final snap = GeoUtils.snapToPolyline(lat, lon, polyline, config.snapRadiusMeters);
      if (snap == null) continue;
      final d = GeoUtils.haversineMeters(lat, lon, snap.lat, snap.lon);
      if (d < bestDist) {
        bestDist = d;
        bestUuid = segment.localUuid;
        best = snap;
      }
    }

    if (bestUuid == null || best == null) return null;
    return (bestUuid, best);
  }

  void _appendRawPoint(double lat, double lon, DateTime time, {required bool snapped}) {
    points.value = [
      ...points.value,
      PlanPoint(lat: lat, lon: lon, time: time, snapped: snapped),
    ];
  }

  /// Retire le dernier point ajouté. Limite assumée : si ce point faisait
  /// partie d'une séquence de sommets insérée automatiquement (accroche
  /// suivant la forme d'un segment), seul le tout dernier sommet est
  /// retiré, pas toute la séquence — un "annuler" répété suffit à revenir
  /// en arrière proprement.
  void undoLastPoint() {
    if (points.value.isEmpty) return;
    points.value = points.value.sublist(0, points.value.length - 1);
    _lastSnap = null;
  }

  void clear() {
    points.value = const [];
    _modeOverrides.clear();
    _lastSnap = null;
    magnetEnabled.value = true;
  }

  /// Finalise le plan : le convertit en `Trace` + `Segment`s via le même
  /// [SegmentationEngine] que l'import GPX et l'enregistrement en direct,
  /// persiste le résultat, puis réinitialise le contrôleur pour un
  /// prochain plan.
  Future<SegmentationResult> finalizePlan({
    required String ownerUuid,
    required IsarService isarService,
    required LocalSearchEngine searchEngine,
    String? traceName,
    ActivityType activityType = ActivityType.hiking,
  }) async {
    final current = points.value;
    if (current.length < 2) {
      throw StateError('Au moins 2 points sont requis pour finaliser un plan.');
    }

    final trackPoints = current
        .map((p) => GpxTrackPoint(latitude: p.lat, longitude: p.lon, time: p.time))
        .toList();
    final parsed = GpxParseResult(
      trackPoints: trackPoints,
      waypoints: const [],
      traceName: traceName ?? 'Plan du ${_uuid.v4().substring(0, 8)}',
    );

    const margin = 0.01;
    final lats = current.map((p) => p.lat);
    final lons = current.map((p) => p.lon);
    final minLat = lats.reduce((a, b) => a < b ? a : b) - margin;
    final maxLat = lats.reduce((a, b) => a > b ? a : b) + margin;
    final minLon = lons.reduce((a, b) => a < b ? a : b) - margin;
    final maxLon = lons.reduce((a, b) => a > b ? a : b) + margin;

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

    final engine = SegmentationEngine(config: config.segmentationConfig);
    final result = engine.segment(
      gpx: parsed,
      nearbyExistingSegments: nearbySegments,
      nearbyExistingPois: nearbyPois,
      ownerUuid: ownerUuid,
      traceNameOverride: traceName,
      activityType: activityType,
      modeOverrides: List.of(_modeOverrides),
    );

    await SegmentationPersistence.persist(
      isarService: isarService,
      result: result,
      searchEngine: searchEngine,
    );

    clear();
    return result;
  }

  void dispose() {
    points.dispose();
    magnetEnabled.dispose();
  }
}
