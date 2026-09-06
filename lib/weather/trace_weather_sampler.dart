/// Fonctions pures utilisées pour l'échantillonnage des points météo le long
/// d'une trace en mode premium (§3.4 / §4 de `spec-meteo.md`). Aucune
/// dépendance à Isar, au réseau ou à Flutter — testables directement.
library;

import '../utils/geo_utils.dart';

/// Vitesse par défaut (km/h) quand aucune vitesse enregistrée exploitable
/// n'est disponible, ou quand l'écart avec une vitesse enregistrée est jugé
/// négligeable (§4.2).
const double kDefaultHikingSpeedKmh = 4.5;

/// Seuil (km/h) en deçà duquel on ne remplace pas [kDefaultHikingSpeedKmh]
/// par la vitesse enregistrée : « la différence n'est pas jugée
/// significative » (§4.2).
const double kSpeedOverrideThresholdKmh = 1.0;

/// Nombre d'enregistrements horaires restants jusqu'à minuit local (§3.4).
/// Le créneau de l'heure en cours compte comme le premier enregistrement.
/// Toujours dans `[1, 24]`.
int hoursUntilLocalMidnight(DateTime now) {
  final h = 24 - now.hour;
  if (h < 1) return 1;
  if (h > 24) return 24;
  return h;
}

/// Choisit la vitesse (km/h) servant à espacer les points le long de la
/// trace (§4.2). Priorité : vitesse de la sortie en cours
/// ([currentOutingKmh]) puis moyenne historique globale
/// ([globalHistoryKmh]). Une valeur `null` ou `<= 0` est ignorée. Si
/// l'écart avec [kDefaultHikingSpeedKmh] est `<= kSpeedOverrideThresholdKmh`,
/// on garde le défaut.
double effectiveSpeedKmh({
  double? currentOutingKmh,
  double? globalHistoryKmh,
}) {
  double? recorded;
  if (currentOutingKmh != null && currentOutingKmh > 0) {
    recorded = currentOutingKmh;
  } else if (globalHistoryKmh != null && globalHistoryKmh > 0) {
    recorded = globalHistoryKmh;
  }

  if (recorded == null) return kDefaultHikingSpeedKmh;
  if ((recorded - kDefaultHikingSpeedKmh).abs() <= kSpeedOverrideThresholdKmh) {
    return kDefaultHikingSpeedKmh;
  }
  return recorded;
}

/// Un point échantillonné le long de la trace.
class TraceSamplePoint {
  final double lat;
  final double lon;

  /// Distance cumulée depuis le début de la trace, en mètres (kilométrage
  /// affiché §3.4).
  final double distanceAlongTraceMeters;

  const TraceSamplePoint({
    required this.lat,
    required this.lon,
    required this.distanceAlongTraceMeters,
  });
}

/// Place [count] points le long de [polyline], en partant de
/// [startOffsetMeters] (progression actuelle de l'utilisateur sur la trace)
/// et espacés de [spacingMeters].
///
/// Le premier point correspond à la position de départ elle-même (heure en
/// cours), les suivants sont décalés de `spacingMeters`. Si la trace se
/// termine avant d'avoir placé [count] points, on s'arrête au dernier point
/// de la trace : une rando plus courte que la fin de journée renvoie moins
/// de points que d'heures (pas de météo « sur le sentier » après l'arrivée).
List<TraceSamplePoint> sampleAlongTrace({
  required List<({double lat, double lon})> polyline,
  required double startOffsetMeters,
  required double spacingMeters,
  required int count,
}) {
  if (polyline.isEmpty || count <= 0) return const [];
  if (polyline.length == 1) {
    return [
      TraceSamplePoint(
        lat: polyline.first.lat,
        lon: polyline.first.lon,
        distanceAlongTraceMeters: 0,
      ),
    ];
  }

  final total = GeoUtils.polylineLengthMeters(polyline);
  final safeSpacing = spacingMeters <= 0 ? 1.0 : spacingMeters;
  final start = startOffsetMeters.clamp(0.0, total);

  final targets = <double>[];
  for (var i = 0; i < count; i++) {
    final d = start + i * safeSpacing;
    if (d > total) break;
    targets.add(d);
  }
  // Toujours au moins le point de départ, même si `start == total`.
  if (targets.isEmpty) targets.add(start);

  final result = <TraceSamplePoint>[];
  var segIndex = 0;
  var accumulated = 0.0; // distance jusqu'au sommet `segIndex`
  for (final target in targets) {
    while (segIndex < polyline.length - 1) {
      final segLen = GeoUtils.haversineMeters(
        polyline[segIndex].lat,
        polyline[segIndex].lon,
        polyline[segIndex + 1].lat,
        polyline[segIndex + 1].lon,
      );
      if (accumulated + segLen >= target || segIndex == polyline.length - 2) {
        final t = segLen <= 0 ? 0.0 : ((target - accumulated) / segLen).clamp(0.0, 1.0);
        final a = polyline[segIndex];
        final b = polyline[segIndex + 1];
        result.add(TraceSamplePoint(
          lat: a.lat + (b.lat - a.lat) * t,
          lon: a.lon + (b.lon - a.lon) * t,
          distanceAlongTraceMeters: target,
        ));
        break;
      }
      accumulated += segLen;
      segIndex++;
    }
  }
  return result;
}
