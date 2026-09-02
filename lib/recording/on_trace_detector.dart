import '../database/isar_service.dart';
import '../models/segment.dart';
import '../utils/geo_utils.dart';

/// Détection passive du fait que l'utilisateur *suit* une trace connue sans
/// l'avoir chargée explicitement dans le Roadmap (cas fréquent).
///
/// Sert de source d'altitude « propre » pour le calibrage du podomètre : une
/// altitude de trace est une valeur statique par point, bien plus stable que
/// le différentiel de deux fixs GPS bruités (cf.
/// `spec-calibrage-podometre-elevation.md` §4.1 / §4.3).
///
/// S'appuie sur le pré-filtrage indexé bounding-box déjà en place
/// ([IsarService.segmentsInViewport]) plutôt que de balayer tout le stock de
/// segments à chaque position. Un même segment doit rester le candidat le
/// plus proche pendant [_confirmAfter] avant d'être considéré comme
/// « suivi », pour ne pas réagir à un simple croisement de sentier.
class OnTraceDetector {
  static const _snapThresholdMeters = 30.0;
  static const _confirmAfter = Duration(minutes: 3);
  static const _viewportMarginDegrees = 0.01; // ~1 km, cohérent avec l'import

  Segment? _candidate;
  DateTime? _candidateSince;

  /// Segment actuellement confirmé comme « suivi », ou `null`.
  Segment? get confirmedSegment {
    final since = _candidateSince;
    if (_candidate == null || since == null) return null;
    return DateTime.now().difference(since) >= _confirmAfter ? _candidate : null;
  }

  /// À appeler à chaque position pertinente. Retourne le segment confirmé
  /// « suivi » si applicable, sinon `null` (candidat encore trop récent, ou
  /// aucun segment à portée).
  Future<Segment?> checkPosition(
      double lat, double lon, IsarService isarService) async {
    final nearby = await isarService.segmentsInViewport(
      minLat: lat - _viewportMarginDegrees,
      maxLat: lat + _viewportMarginDegrees,
      minLon: lon - _viewportMarginDegrees,
      maxLon: lon + _viewportMarginDegrees,
    );

    Segment? closest;
    for (final s in nearby) {
      if (s.points.length < 2) continue;
      final polyline =
          s.points.map((p) => (lat: p.latitude, lon: p.longitude)).toList();
      if (GeoUtils.snapToPolyline(lat, lon, polyline, _snapThresholdMeters) !=
          null) {
        closest = s;
        break;
      }
    }

    if (closest == null || closest.localUuid != _candidate?.localUuid) {
      _candidate = closest;
      _candidateSince = closest != null ? DateTime.now() : null;
      return null;
    }

    // Même candidat qu'au passage précédent : on garde la référence fraîche
    // (points potentiellement enrichis entre-temps) sans réinitialiser le
    // chrono de confirmation.
    _candidate = closest;
    return confirmedSegment;
  }

  /// Oublie le candidat courant (ex. arrêt de l'enregistrement / de la
  /// localisation).
  void reset() {
    _candidate = null;
    _candidateSince = null;
  }
}
