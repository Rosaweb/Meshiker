import 'package:flutter_test/flutter_test.dart';
import 'package:meshiker/weather/trace_weather_sampler.dart';

void main() {
  group('hoursUntilLocalMidnight', () {
    test('compte le créneau de l\'heure en cours', () {
      expect(hoursUntilLocalMidnight(DateTime(2026, 9, 6, 0, 5)), 24);
      expect(hoursUntilLocalMidnight(DateTime(2026, 9, 6, 8, 30)), 16);
      expect(hoursUntilLocalMidnight(DateTime(2026, 9, 6, 23, 59)), 1);
    });

    test('toujours dans [1, 24]', () {
      for (var h = 0; h < 24; h++) {
        final v = hoursUntilLocalMidnight(DateTime(2026, 9, 6, h));
        expect(v, inInclusiveRange(1, 24));
      }
    });
  });

  group('effectiveSpeedKmh', () {
    test('défaut 4,5 quand rien de disponible', () {
      expect(effectiveSpeedKmh(), kDefaultHikingSpeedKmh);
      expect(effectiveSpeedKmh(currentOutingKmh: 0, globalHistoryKmh: 0),
          kDefaultHikingSpeedKmh);
    });

    test('porte de ±1 km/h autour du défaut', () {
      // écart <= 1 km/h -> on garde 4,5
      expect(effectiveSpeedKmh(currentOutingKmh: 5.4), kDefaultHikingSpeedKmh);
      expect(effectiveSpeedKmh(currentOutingKmh: 3.6), kDefaultHikingSpeedKmh);
      // écart > 1 km/h -> on prend la vitesse enregistrée
      expect(effectiveSpeedKmh(currentOutingKmh: 6.0), 6.0);
      expect(effectiveSpeedKmh(currentOutingKmh: 3.0), 3.0);
    });

    test('sortie en cours prioritaire sur historique global', () {
      expect(
        effectiveSpeedKmh(currentOutingKmh: 6.5, globalHistoryKmh: 3.0),
        6.5,
      );
    });

    test('repli sur historique global si pas de sortie en cours', () {
      expect(
        effectiveSpeedKmh(currentOutingKmh: 0, globalHistoryKmh: 6.5),
        6.5,
      );
    });
  });

  group('sampleAlongTrace', () {
    // ~111,32 m par 0,001° de longitude à l'équateur.
    final line = <({double lat, double lon})>[
      for (var i = 0; i <= 100; i++) (lat: 0.0, lon: i * 0.001),
    ];

    test('un point par heure restante, espacés de la distance voulue', () {
      final pts = sampleAlongTrace(
        polyline: line,
        startOffsetMeters: 0,
        spacingMeters: 1000,
        count: 5,
      );
      expect(pts.length, 5);
      expect(pts.first.distanceAlongTraceMeters, 0);
      for (var i = 1; i < pts.length; i++) {
        expect(pts[i].distanceAlongTraceMeters,
            closeTo(i * 1000, 0.001));
        // La longitude progresse avec la distance cumulée.
        expect(pts[i].lon, greaterThan(pts[i - 1].lon));
      }
    });

    test('démarre à la progression actuelle', () {
      final pts = sampleAlongTrace(
        polyline: line,
        startOffsetMeters: 3000,
        spacingMeters: 1000,
        count: 3,
      );
      expect(pts.first.distanceAlongTraceMeters, closeTo(3000, 0.001));
      expect(pts.last.distanceAlongTraceMeters, closeTo(5000, 0.001));
    });

    test('s\'arrête à la fin de la trace si elle est plus courte', () {
      final total = 100 * 0.001 * 111319.9; // ~ longueur de `line`
      final pts = sampleAlongTrace(
        polyline: line,
        startOffsetMeters: total - 2500,
        spacingMeters: 1000,
        count: 10,
      );
      // Depuis ~2,5 km avant la fin, espacés de 1 km : 3 points au plus.
      expect(pts.length, lessThanOrEqualTo(3));
      for (final p in pts) {
        expect(p.distanceAlongTraceMeters, lessThanOrEqualTo(total + 1));
      }
    });

    test('polyligne vide ou count nul -> liste vide', () {
      expect(
        sampleAlongTrace(
            polyline: const [], startOffsetMeters: 0, spacingMeters: 1000, count: 5),
        isEmpty,
      );
      expect(
        sampleAlongTrace(
            polyline: line, startOffsetMeters: 0, spacingMeters: 1000, count: 0),
        isEmpty,
      );
    });
  });
}
