import 'package:flutter_test/flutter_test.dart';
import 'package:meshiker/gpx/gpx_parser.dart';
import 'package:meshiker/gpx/gpx_validation.dart';

void main() {
  test('parses a simple track with one segment', () {
    const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1">
  <metadata><name>Ma Randonnée</name></metadata>
  <trk>
    <trkseg>
      <trkpt lat="45.0" lon="1.0"><ele>100</ele></trkpt>
      <trkpt lat="45.001" lon="1.001"><ele>105</ele></trkpt>
    </trkseg>
  </trk>
</gpx>
''';

    final result = GpxParser.parseString(xml);

    expect(result.traceName, 'Ma Randonnée');
    expect(result.trackPoints, hasLength(2));
    expect(result.trackPoints.first.startsNewSegment, isTrue);
    expect(result.trackPoints.last.startsNewSegment, isFalse);
  });

  test('throws FormatException when <gpx> tag is missing', () {
    expect(() => GpxParser.parseString('<not-gpx></not-gpx>'), throwsFormatException);
  });

  group('validation des coordonnées', () {
    test('ignore un trkpt avec des coordonnées hors plage plutôt que de le garder à (0,0)', () {
      const xml = '''
<gpx version="1.1">
  <trk>
    <trkseg>
      <trkpt lat="999" lon="1.0"><ele>100</ele></trkpt>
      <trkpt lat="45.0" lon="1.0"><ele>100</ele></trkpt>
    </trkseg>
  </trk>
</gpx>
''';
      final result = GpxParser.parseString(xml);

      expect(result.trackPoints, hasLength(1));
      expect(result.trackPoints.single.latitude, 45.0);
      // Le premier point du segment restant doit toujours porter
      // startsNewSegment, même si le point invalide qui le précédait dans
      // le fichier a été ignoré.
      expect(result.trackPoints.single.startsNewSegment, isTrue);
    });

    test('ignore un trkpt dont lat/lon vaut NaN ou Infinity', () {
      const xml = '''
<gpx version="1.1">
  <trk>
    <trkseg>
      <trkpt lat="NaN" lon="1.0"></trkpt>
      <trkpt lat="45.0" lon="Infinity"></trkpt>
      <trkpt lat="45.0" lon="1.0"></trkpt>
    </trkseg>
  </trk>
</gpx>
''';
      final result = GpxParser.parseString(xml);

      expect(result.trackPoints, hasLength(1));
      expect(result.trackPoints.single.latitude, 45.0);
      expect(result.trackPoints.single.longitude, 1.0);
    });

    test('ignore une élévation non finie mais garde le point', () {
      const xml = '''
<gpx version="1.1">
  <trk>
    <trkseg>
      <trkpt lat="45.0" lon="1.0"><ele>NaN</ele></trkpt>
    </trkseg>
  </trk>
</gpx>
''';
      final result = GpxParser.parseString(xml);

      expect(result.trackPoints, hasLength(1));
      expect(result.trackPoints.single.elevation, isNull);
    });

    test('ignore un waypoint aux coordonnées invalides', () {
      const xml = '''
<gpx version="1.1">
  <wpt lat="200" lon="1.0"><name>Invalide</name></wpt>
  <wpt lat="45.0" lon="1.0"><name>Valide</name></wpt>
  <trk><trkseg><trkpt lat="45.0" lon="1.0"></trkpt></trkseg></trk>
</gpx>
''';
      final result = GpxParser.parseString(xml);

      expect(result.waypoints, hasLength(1));
      expect(result.waypoints.single.name, 'Valide');
    });
  });

  group('limites de conformité', () {
    test('rejette un contenu dépassant la taille maximale', () {
      final hugeContent = 'x' * (GpxLimits.maxContentBytes + 1);
      expect(
        () => GpxParser.parseString(hugeContent),
        throwsA(isA<GpxValidationException>()),
      );
    });

    test('rejette un fichier avec plus de points que la limite autorisée', () {
      final buffer = StringBuffer('<gpx version="1.1"><trk><trkseg>');
      for (var i = 0; i < GpxLimits.maxTrackPoints + 1; i++) {
        buffer.write('<trkpt lat="45.0" lon="1.0"></trkpt>');
      }
      buffer.write('</trkseg></trk></gpx>');

      expect(
        () => GpxParser.parseString(buffer.toString()),
        throwsA(isA<GpxValidationException>()),
      );
    });
  });
}
