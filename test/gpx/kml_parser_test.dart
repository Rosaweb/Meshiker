import 'package:flutter_test/flutter_test.dart';
import 'package:meshiker/gpx/kml_parser.dart';

void main() {
  test('parses a LineString track and a Point placemark', () {
    const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>Ma Randonnée</name>
    <Placemark>
      <name>Sommet</name>
      <description>Vue superbe</description>
      <Point>
        <coordinates>1.234,45.678,120</coordinates>
      </Point>
    </Placemark>
    <Placemark>
      <name>Trace</name>
      <LineString>
        <coordinates>
          1.0,45.0,100
          1.001,45.001,105
          1.002,45.002,110
        </coordinates>
      </LineString>
    </Placemark>
  </Document>
</kml>
''';

    final result = KmlParser.parseString(xml);

    expect(result.traceName, 'Ma Randonnée');
    expect(result.waypoints, hasLength(1));
    expect(result.waypoints.single.name, 'Sommet');
    expect(result.waypoints.single.latitude, 45.678);
    expect(result.waypoints.single.longitude, 1.234);
    expect(result.waypoints.single.elevation, 120);

    expect(result.trackPoints, hasLength(3));
    expect(result.trackPoints.first.startsNewSegment, isTrue);
    expect(result.trackPoints[1].startsNewSegment, isFalse);
    expect(result.trackPoints.first.latitude, 45.0);
    expect(result.trackPoints.first.longitude, 1.0);
    expect(result.trackPoints.first.elevation, 100);
  });

  test('parses a gx:Track with timestamps', () {
    const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">
  <Document>
    <Placemark>
      <gx:Track>
        <when>2024-06-01T08:00:00Z</when>
        <gx:coord>1.0 45.0 100</gx:coord>
        <when>2024-06-01T08:00:10Z</when>
        <gx:coord>1.001 45.001 105</gx:coord>
      </gx:Track>
    </Placemark>
  </Document>
</kml>
''';

    final result = KmlParser.parseString(xml);

    expect(result.trackPoints, hasLength(2));
    expect(result.trackPoints.first.latitude, 45.0);
    expect(result.trackPoints.first.longitude, 1.0);
    expect(result.trackPoints.first.time, DateTime.parse('2024-06-01T08:00:00Z'));
    expect(result.trackPoints.last.time, DateTime.parse('2024-06-01T08:00:10Z'));
  });

  test('handles multiple LineStrings in separate Placemarks as separate segments', () {
    const xml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <Placemark>
      <LineString><coordinates>1.0,45.0 1.001,45.001</coordinates></LineString>
    </Placemark>
    <Placemark>
      <LineString><coordinates>2.0,46.0 2.001,46.001</coordinates></LineString>
    </Placemark>
  </Document>
</kml>
''';

    final result = KmlParser.parseString(xml);

    expect(result.trackPoints, hasLength(4));
    expect(result.trackPoints[0].startsNewSegment, isTrue);
    expect(result.trackPoints[1].startsNewSegment, isFalse);
    expect(result.trackPoints[2].startsNewSegment, isTrue);
    expect(result.trackPoints[3].startsNewSegment, isFalse);
  });

  test('throws FormatException when <kml> tag is missing', () {
    expect(() => KmlParser.parseString('<not-kml></not-kml>'), throwsFormatException);
  });
}
