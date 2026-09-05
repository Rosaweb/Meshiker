import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:meshiker/gps/stationary_detector.dart';

final _epoch = DateTime(2026, 1, 1, 12, 0, 0);

Position _pos({required double lat, required double lon, required int secondsFromEpoch}) {
  return Position(
    latitude: lat,
    longitude: lon,
    timestamp: _epoch.add(Duration(seconds: secondsFromEpoch)),
    accuracy: 5,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );
}

void main() {
  group('StationaryDetector', () {
    const window = Duration(seconds: 30);
    const radius = 10.0;

    test('is not stationary with fewer than two points in the buffer', () {
      final detector = StationaryDetector();
      expect(
        detector.update(_pos(lat: 45, lon: 6, secondsFromEpoch: 0), windowDuration: window, radiusMeters: radius),
        isFalse,
      );
    });

    test('detects stationarity when fixes stay within the radius', () {
      final detector = StationaryDetector();
      detector.update(_pos(lat: 45.0, lon: 6.0, secondsFromEpoch: 0), windowDuration: window, radiusMeters: radius);
      detector.update(_pos(lat: 45.00001, lon: 6.0, secondsFromEpoch: 5), windowDuration: window, radiusMeters: radius);
      final result = detector.update(
        _pos(lat: 45.00002, lon: 6.0, secondsFromEpoch: 10),
        windowDuration: window,
        radiusMeters: radius,
      );
      expect(result, isTrue);
    });

    test('does not detect stationarity while moving beyond the radius', () {
      final detector = StationaryDetector();
      detector.update(_pos(lat: 45.0, lon: 6.0, secondsFromEpoch: 0), windowDuration: window, radiusMeters: radius);
      final result = detector.update(
        // ~100 m plus loin -- une vraie marche, pas du bruit à l'arrêt.
        _pos(lat: 45.0009, lon: 6.0, secondsFromEpoch: 5),
        windowDuration: window,
        radiusMeters: radius,
      );
      expect(result, isFalse);
    });

    test('drops fixes older than windowDuration, so an old stop does not mask a fresh departure', () {
      final detector = StationaryDetector();
      // Un arrêt de quelques fixs...
      detector.update(_pos(lat: 45.0, lon: 6.0, secondsFromEpoch: 0), windowDuration: window, radiusMeters: radius);
      detector.update(_pos(lat: 45.00001, lon: 6.0, secondsFromEpoch: 5), windowDuration: window, radiusMeters: radius);
      // ...puis un unique fix bien après la fin de la fenêtre : les fixs de
      // l'arrêt sont purgés, il ne reste qu'un point -- pas assez pour
      // conclure à une stationnarité.
      final result = detector.update(
        _pos(lat: 45.00001, lon: 6.0, secondsFromEpoch: 100),
        windowDuration: window,
        radiusMeters: radius,
      );
      expect(result, isFalse);
    });
  });
}
