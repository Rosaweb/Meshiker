import 'package:geolocator/geolocator.dart' as geo;

import '../utils/geo_utils.dart';

/// Filtre de qualité de fix GPS, partagé par les trois fonctionnalités
/// dégradées par le bruit GPS positionnel : distance journalière, stockage
/// de la trace enregistrée et calibrage pente du podomètre (cf.
/// `spec-filtrage-gps-centralise.md`). Fonction pure, sans état : ne dépend
/// que des deux fixs comparés.
class GpsFixQuality {
  GpsFixQuality._();

  static const double maxAccuracyMeters = 15.0;
  static const double minMovementMeters = 3.0;
  static const double minSpeedKmh = 0.5;

  /// Cas du tout premier fix d'une session (pas de fix précédemment accepté
  /// pour comparer) : accepté sur la seule précision, sans contrainte de
  /// mouvement.
  static bool isAcceptableFirstFix(geo.Position position) =>
      position.accuracy <= maxAccuracyMeters;

  /// Un fix est exploitable si : sa précision est suffisante, le
  /// déplacement depuis le dernier fix accepté dépasse le bruit GPS typique
  /// à l'arrêt (véhicule stationné, téléphone posé), et la vitesse déduite
  /// est cohérente avec un déplacement réel (filtre le micro-jitter qui
  /// franchirait `minMovementMeters` sur un intervalle très court).
  static bool isAcceptableFix({
    required geo.Position previous,
    required geo.Position current,
    double maxAccuracyMeters = GpsFixQuality.maxAccuracyMeters,
    double minMovementMeters = GpsFixQuality.minMovementMeters,
    double minSpeedKmh = GpsFixQuality.minSpeedKmh,
  }) {
    if (current.accuracy > maxAccuracyMeters) return false;

    final distance = GeoUtils.haversineMeters(
      previous.latitude,
      previous.longitude,
      current.latitude,
      current.longitude,
    );
    if (distance < minMovementMeters) return false;

    final seconds = current.timestamp.difference(previous.timestamp).inSeconds;
    if (seconds <= 0) return false;
    final speedKmh = (distance / seconds) * 3.6;
    if (speedKmh < minSpeedKmh) return false;

    return true;
  }
}
