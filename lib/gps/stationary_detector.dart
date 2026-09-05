import 'package:geolocator/geolocator.dart' as geo;

import '../utils/geo_utils.dart';

/// Détection de stationnarité par fenêtre glissante : si toutes les
/// positions reçues dans les [windowDuration] dernières secondes tiennent
/// dans un rayon de [radiusMeters] autour de leur centroïde, l'utilisateur
/// est considéré à l'arrêt. Partagé par les trois fonctionnalités
/// dégradées par le bruit GPS (cf. `spec-filtrage-gps-centralise.md`).
///
/// `windowDuration`/`radiusMeters` sont passés à chaque appel plutôt que
/// figés à la construction : configurables par l'utilisateur
/// (`SettingsService.stationaryWindowPreset`/`stationaryRadiusPreset`), un
/// changement de réglage s'applique donc dès le prochain fix, sans avoir à
/// reconstruire le détecteur ni redémarrer l'enregistrement en cours.
class StationaryDetector {
  final List<geo.Position> _buffer = [];

  bool update(
    geo.Position position, {
    required Duration windowDuration,
    required double radiusMeters,
  }) {
    _buffer.add(position);
    _buffer.removeWhere(
      (p) => position.timestamp.difference(p.timestamp) > windowDuration,
    );

    if (_buffer.length < 2) return false;

    final center = _centroid(_buffer);
    return _buffer.every(
      (p) => GeoUtils.haversineMeters(
            p.latitude,
            p.longitude,
            center.latitude,
            center.longitude,
          ) <=
          radiusMeters,
    );
  }

  ({double latitude, double longitude}) _centroid(List<geo.Position> points) {
    final lat = points.map((p) => p.latitude).reduce((a, b) => a + b) / points.length;
    final lng = points.map((p) => p.longitude).reduce((a, b) => a + b) / points.length;
    return (latitude: lat, longitude: lng);
  }
}
