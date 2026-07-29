import 'dart:math';

import '../../gpx/gpx_models.dart';
import '../../utils/geo_utils.dart';

/// Série de points prêts à être tracés pour un profil altimétrique :
/// distance cumulée en abscisse, altitude en ordonnée. Les éventuels trous
/// (altitude non fournie par le capteur/le fichier pour certains points)
/// sont comblés par interpolation linéaire entre les points connus.
class ElevationSeries {
  final List<double> distancesM;
  final List<double> elevations;
  final double totalDistanceM;
  final double minEle;
  final double maxEle;

  const ElevationSeries({
    required this.distancesM,
    required this.elevations,
    required this.totalDistanceM,
    required this.minEle,
    required this.maxEle,
  });

  factory ElevationSeries.fromPoints(List<GpxTrackPoint> points) {
    final dist = List<double>.filled(points.length, 0);
    for (var i = 1; i < points.length; i++) {
      dist[i] = dist[i - 1] +
          GeoUtils.haversineMeters(points[i - 1].latitude, points[i - 1].longitude,
              points[i].latitude, points[i].longitude);
    }
    final totalDistanceM = dist.isEmpty ? 0.0 : dist.last;

    final ele = List<double?>.from(points.map((p) => p.elevation));
    int? lastKnown;
    for (var i = 0; i < ele.length; i++) {
      if (ele[i] == null) continue;
      if (lastKnown != null && i - lastKnown > 1) {
        final v0 = ele[lastKnown]!;
        final v1 = ele[i]!;
        final span = dist[i] - dist[lastKnown];
        for (var j = lastKnown + 1; j < i; j++) {
          final t = span == 0 ? 0.0 : (dist[j] - dist[lastKnown]) / span;
          ele[j] = v0 + (v1 - v0) * t;
        }
      }
      lastKnown = i;
    }
    final firstKnown = ele.indexWhere((e) => e != null);
    final lastKnownIdx = ele.lastIndexWhere((e) => e != null);
    if (firstKnown != -1) {
      for (var i = 0; i < firstKnown; i++) {
        ele[i] = ele[firstKnown];
      }
      for (var i = lastKnownIdx + 1; i < ele.length; i++) {
        ele[i] = ele[lastKnownIdx];
      }
    }
    final elevations = ele.map((e) => e ?? 0.0).toList();

    final minEle = elevations.isNotEmpty ? elevations.reduce(min) : 0.0;
    final maxEle = elevations.isNotEmpty ? elevations.reduce(max) : 0.0;

    return ElevationSeries(
      distancesM: dist,
      elevations: elevations,
      totalDistanceM: totalDistanceM,
      minEle: minEle,
      maxEle: maxEle,
    );
  }
}
