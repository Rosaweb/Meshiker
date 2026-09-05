import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:meshiker/gps/gps_fix_quality.dart';

final _epoch = DateTime(2026, 1, 1, 12, 0, 0);

Position _pos({
  required double lat,
  required double lon,
  double accuracy = 5.0,
  int secondsFromEpoch = 0,
}) {
  return Position(
    latitude: lat,
    longitude: lon,
    timestamp: _epoch.add(Duration(seconds: secondsFromEpoch)),
    accuracy: accuracy,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );
}

void main() {
  group('GpsFixQuality.isAcceptableFirstFix', () {
    test('accepts a fix within the accuracy threshold', () {
      expect(GpsFixQuality.isAcceptableFirstFix(_pos(lat: 45, lon: 6, accuracy: 10)), isTrue);
    });

    test('rejects a fix beyond the accuracy threshold', () {
      expect(GpsFixQuality.isAcceptableFirstFix(_pos(lat: 45, lon: 6, accuracy: 20)), isFalse);
    });
  });

  group('GpsFixQuality.isAcceptableFix', () {
    test('rejects when the current fix accuracy is too poor', () {
      final previous = _pos(lat: 45.0, lon: 6.0, secondsFromEpoch: 0);
      final current = _pos(lat: 45.0001, lon: 6.0, accuracy: 20, secondsFromEpoch: 3);
      expect(GpsFixQuality.isAcceptableFix(previous: previous, current: current), isFalse);
    });

    test('rejects a micro-movement below the noise floor', () {
      // ~1 m de dérive sur quelques secondes -- typique du bruit GPS à
      // l'arrêt (véhicule stationné, téléphone posé).
      final previous = _pos(lat: 45.0, lon: 6.0, secondsFromEpoch: 0);
      final current = _pos(lat: 45.000009, lon: 6.0, secondsFromEpoch: 3);
      expect(GpsFixQuality.isAcceptableFix(previous: previous, current: current), isFalse);
    });

    test('rejects a plausible-distance fix reached implausibly slowly', () {
      // ~4 m parcourus en 10 minutes : dépasse minMovementMeters, mais la
      // vitesse déduite est bien en dessous de minSpeedKmh -- du jitter GPS
      // accumulé plutôt qu'un déplacement réel.
      final previous = _pos(lat: 45.0, lon: 6.0, secondsFromEpoch: 0);
      final current = _pos(lat: 45.00004, lon: 6.0, secondsFromEpoch: 600);
      expect(GpsFixQuality.isAcceptableFix(previous: previous, current: current), isFalse);
    });

    test('rejects a non-increasing timestamp', () {
      final previous = _pos(lat: 45.0, lon: 6.0, secondsFromEpoch: 10);
      final current = _pos(lat: 45.0001, lon: 6.0, secondsFromEpoch: 10);
      expect(GpsFixQuality.isAcceptableFix(previous: previous, current: current), isFalse);
    });

    test('accepts a normal walking-pace fix', () {
      // ~5.5 m en 3 s : ~6.6 km/h, précision correcte -- rythme de marche
      // plausible.
      final previous = _pos(lat: 45.0, lon: 6.0, secondsFromEpoch: 0);
      final current = _pos(lat: 45.00005, lon: 6.0, secondsFromEpoch: 3);
      expect(GpsFixQuality.isAcceptableFix(previous: previous, current: current), isTrue);
    });
  });
}
