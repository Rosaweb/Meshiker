import 'package:xml/xml.dart';

import 'gpx_models.dart';

/// Sérialiseur GPX minimaliste, symétrique de [GpxParser] : produit
/// exactement les mêmes balises (gpx/metadata/name, trk/name,
/// trkseg/trkpt avec lat/lon/ele/time) que [GpxParser] sait relire,
/// pour que tout fichier généré ici soit réimportable tel quel dans
/// l'app.
///
/// Fonction pure : ne touche jamais Isar, ne prend en entrée que les
/// points déjà résolus (voir `IsarService.getTraceTrackPoints`).
class GpxSerializer {
  const GpxSerializer._();

  static String serializeTrace({
    required List<GpxTrackPoint> points,
    required String traceName,
    List<GpxWaypoint> waypoints = const [],
  }) {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element('gpx', attributes: {
      'version': '1.1',
      'creator': 'Meshiker',
      'xmlns': 'http://www.topografix.com/GPX/1/1',
    }, nest: () {
      builder.element('metadata', nest: () {
        builder.element('name', nest: traceName);
      });
      for (final wp in waypoints) {
        _writeWaypoint(builder, wp);
      }
      builder.element('trk', nest: () {
        builder.element('name', nest: traceName);
        for (final segment in _splitSegments(points)) {
          builder.element('trkseg', nest: () {
            for (final point in segment) {
              _writeTrackPoint(builder, point);
            }
          });
        }
      });
    });
    return builder.buildDocument().toXmlString(pretty: true);
  }

  static void _writeWaypoint(XmlBuilder builder, GpxWaypoint waypoint) {
    builder.element('wpt', attributes: {
      'lat': waypoint.latitude.toString(),
      'lon': waypoint.longitude.toString(),
    }, nest: () {
      if (waypoint.elevation != null) {
        builder.element('ele', nest: waypoint.elevation.toString());
      }
      if (waypoint.name != null) {
        builder.element('name', nest: waypoint.name!);
      }
      if (waypoint.description != null) {
        builder.element('desc', nest: waypoint.description!);
      }
    });
  }

  static void _writeTrackPoint(XmlBuilder builder, GpxTrackPoint point) {
    builder.element('trkpt', attributes: {
      'lat': point.latitude.toString(),
      'lon': point.longitude.toString(),
    }, nest: () {
      if (point.elevation != null) {
        builder.element('ele', nest: point.elevation.toString());
      }
      if (point.time != null) {
        builder.element('time', nest: point.time!.toUtc().toIso8601String());
      }
    });
  }

  /// Regroupe les points en blocs `<trkseg>` à chaque rupture marquée par
  /// [GpxTrackPoint.startsNewSegment], au même titre que [GpxParser] les
  /// distingue à la lecture.
  static List<List<GpxTrackPoint>> _splitSegments(List<GpxTrackPoint> points) {
    if (points.isEmpty) return const [];
    final segments = <List<GpxTrackPoint>>[];
    var current = <GpxTrackPoint>[];
    for (final point in points) {
      if (point.startsNewSegment && current.isNotEmpty) {
        segments.add(current);
        current = [];
      }
      current.add(point);
    }
    if (current.isNotEmpty) segments.add(current);
    return segments;
  }
}
