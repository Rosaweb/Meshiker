import 'package:flutter_test/flutter_test.dart';
import 'package:meshiker/utils/geo_utils.dart';

void main() {
  group('simplifyDouglasPeucker', () {
    test('returns the input unchanged when fewer than 3 points', () {
      final points = [(lat: 45.0, lon: 6.0), (lat: 45.001, lon: 6.001)];
      expect(GeoUtils.simplifyDouglasPeucker(points, 10), points);
    });

    test('always keeps both endpoints', () {
      final points = [
        (lat: 45.0, lon: 6.0),
        (lat: 45.001, lon: 6.0005),
        (lat: 45.002, lon: 6.001),
      ];
      final simplified = GeoUtils.simplifyDouglasPeucker(points, 1000);
      expect(simplified.first, points.first);
      expect(simplified.last, points.last);
    });

    test('collapses near-collinear points within tolerance to the two endpoints', () {
      // Une ligne quasi droite Nord (même longitude), points intermédiaires
      // décalés de quelques centimètres seulement -- bien en dessous d'une
      // tolérance de 10 m.
      final points = [
        (lat: 45.0000, lon: 6.0000),
        (lat: 45.0010, lon: 6.0000001),
        (lat: 45.0020, lon: 6.0000002),
        (lat: 45.0030, lon: 6.0000001),
        (lat: 45.0040, lon: 6.0000),
      ];
      final simplified = GeoUtils.simplifyDouglasPeucker(points, 10);
      expect(simplified, [points.first, points.last]);
    });

    test('keeps a point whose deviation exceeds the tolerance', () {
      // Point central décalé d'environ 100 m perpendiculairement à la
      // corde reliant les deux extrémités (~0.0009 deg de longitude à
      // cette latitude) -- doit être conservé avec une tolérance de 10 m.
      final points = [
        (lat: 45.0000, lon: 6.0000),
        (lat: 45.0010, lon: 6.0009),
        (lat: 45.0020, lon: 6.0000),
      ];
      final simplified = GeoUtils.simplifyDouglasPeucker(points, 10);
      expect(simplified, points);
    });

    test('reduces a dense zigzag to only the points that matter', () {
      final points = [
        (lat: 45.0000, lon: 6.0000),
        (lat: 45.0005, lon: 6.0000),
        (lat: 45.0010, lon: 6.0000),
        (lat: 45.0015, lon: 6.0000),
        (lat: 45.0020, lon: 6.0050), // écart net, doit survivre
        (lat: 45.0025, lon: 6.0000),
        (lat: 45.0030, lon: 6.0000),
      ];
      final simplified = GeoUtils.simplifyDouglasPeucker(points, 5);
      expect(simplified.length, lessThan(points.length));
      expect(simplified.first, points.first);
      expect(simplified.last, points.last);
      expect(simplified, contains(points[4]));
    });
  });
}
