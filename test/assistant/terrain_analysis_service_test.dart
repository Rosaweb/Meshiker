import 'package:flutter_test/flutter_test.dart';
import 'package:meshiker/assistant/terrain_analysis_service.dart';
import 'package:meshiker/assistant/terrain_overpass_service.dart';

void main() {
  // Route rectiligne plein Nord (longitude constante) d'environ 1,1 km --
  // simplifie le calcul du côté gauche/droite attendu (Est = droite, Ouest
  // = gauche) et les distances le long de la route dans les assertions.
  final route = [(lat: 45.0000, lon: 6.0000), (lat: 45.0100, lon: 6.0000)];

  TerrainOsmElement node(Map<String, String> tags, {required double lat, required double lon}) {
    return TerrainOsmElement(id: 'node/1', isWay: false, tags: tags, geometry: [(lat: lat, lon: lon)]);
  }

  TerrainOsmElement way(Map<String, String> tags, List<({double lat, double lon})> geometry) {
    return TerrainOsmElement(id: 'way/1', isWay: true, tags: tags, geometry: geometry);
  }

  group('classifyElements — node', () {
    test('a node right on the route is a crossing', () {
      final el = node({'railway': 'level_crossing'}, lat: 45.0050, lon: 6.0000);
      final result = TerrainAnalysisService.classifyElements([el], route);

      expect(result, hasLength(1));
      expect(result.single.relation, 'croisement');
      expect(result.single.side, isNull);
    });

    test('a node ~30 m east of the route is a nearby point on the right', () {
      // 0.0004° de longitude à 45°N ≈ 31 m (111 320 * cos(45°) * 0.0004).
      final el = node({'historic': 'wayside_cross'}, lat: 45.0050, lon: 6.0004);
      final result = TerrainAnalysisService.classifyElements([el], route);

      expect(result, hasLength(1));
      expect(result.single.relation, 'point_proche');
      expect(result.single.side, 'droite');
    });

    test('a node west of the route is a nearby point on the left', () {
      final el = node({'historic': 'wayside_cross'}, lat: 45.0050, lon: 5.9996);
      final result = TerrainAnalysisService.classifyElements([el], route);

      expect(result.single.side, 'gauche');
    });

    test('blacklisted tags are dropped entirely', () {
      final el = node({'barrier': 'fence'}, lat: 45.0050, lon: 6.0000);
      final result = TerrainAnalysisService.classifyElements([el], route);

      expect(result, isEmpty);
    });

    test('a node far outside the search radius is dropped', () {
      final el = node({'historic': 'wayside_cross'}, lat: 45.0050, lon: 6.01);
      final result = TerrainAnalysisService.classifyElements([el], route);

      expect(result, isEmpty);
    });
  });

  group('classifyElements — way', () {
    test('a way whose midpoint sits on the route is a crossing', () {
      final el = way({'waterway': 'stream'}, [
        (lat: 45.0060, lon: 5.9995),
        (lat: 45.0060, lon: 6.0000),
        (lat: 45.0060, lon: 6.0005),
      ]);
      final result = TerrainAnalysisService.classifyElements([el], route);

      expect(result, hasLength(1));
      expect(result.single.relation, 'croisement');
      // ~0,0060° de latitude ≈ 668 m depuis le début de la route.
      expect(result.single.distanceM, closeTo(668, 5));
    });

    test('a way running alongside the route for a long stretch is a paralleling', () {
      // ~20 m à l'est de la route sur ~670 m -- dans le tampon (40 m) et
      // au-delà du seuil de longement (150 m).
      final el = way({'waterway': 'canal', 'name': 'Canal du Test'}, [
        (lat: 45.0020, lon: 6.00025),
        (lat: 45.0040, lon: 6.00025),
        (lat: 45.0060, lon: 6.00025),
        (lat: 45.0080, lon: 6.00025),
      ]);
      final result = TerrainAnalysisService.classifyElements([el], route);

      expect(result, hasLength(1));
      expect(result.single.relation, 'longement');
      expect(result.single.name, 'Canal du Test');
      expect(result.single.lengthM, greaterThan(600));
      expect(result.single.runStartM, closeTo(222, 10));
      expect(result.single.runEndM, closeTo(890, 10));
    });

    test('a way entirely outside the buffer is dropped', () {
      final el = way({'natural': 'water'}, [
        (lat: 45.0020, lon: 6.0010),
        (lat: 45.0040, lon: 6.0010),
      ]);
      final result = TerrainAnalysisService.classifyElements([el], route);

      expect(result, isEmpty);
    });
  });
}
