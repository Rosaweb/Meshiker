import 'package:collection/collection.dart';
import 'package:xml/xml.dart';

import 'gpx_models.dart';
import 'gpx_validation.dart';

/// Parseur KML minimaliste, écrit dans le même esprit que [GpxParser] :
/// directement sur `package:xml`, sans dépendance à un package KML tiers.
/// Il restitue le même modèle intermédiaire [GpxParseResult] que
/// [GpxParser] : [SegmentationEngine] ne voit donc jamais la différence
/// entre un import GPX et un import KML.
///
/// Formes de KML gérées :
/// - `<Placemark><Point>` : un point d'intérêt (nom + description).
/// - `<Placemark><LineString>` (y compris dans un `<MultiGeometry>`) : un
///   tracé, coordonnées `lon,lat[,ele]` séparées par des espaces/retours
///   à la ligne.
/// - `<Placemark><gx:Track>` (extension Google Earth) : un tracé
///   horodaté, une paire `<when>`/`<gx:coord>` par point.
///
/// Les `<Placemark>` sont recherchés sur tout le document
/// (`findAllElements`) pour ne pas dépendre de leur profondeur
/// d'imbrication dans `<Document>`/`<Folder>`.
class KmlParser {
  const KmlParser._();

  static GpxParseResult parseString(String xmlContent) {
    // Rejette tôt un contenu anormalement volumineux, avant même de
    // tenter de construire l'arbre DOM (voir GpxLimits).
    GpxLimits.checkContentLength(xmlContent);

    final document = XmlDocument.parse(xmlContent);
    final kmlElements = document.findAllElements('kml');
    if (kmlElements.isEmpty) {
      throw const FormatException('Fichier KML invalide : balise <kml> introuvable.');
    }

    final trackPoints = <GpxTrackPoint>[];
    final waypoints = <GpxWaypoint>[];

    for (final placemark in document.findAllElements('Placemark')) {
      final lineStrings = placemark.findAllElements('LineString').toList();
      final gxTracks = placemark.findAllElements('gx:Track').toList();

      if (lineStrings.isEmpty && gxTracks.isEmpty) {
        final point = placemark.findAllElements('Point').firstOrNull;
        final coordsText = point != null ? _childText(point, 'coordinates') : null;
        final parsed = coordsText != null ? _parseCoordinateTuple(coordsText) : null;
        if (parsed != null) {
          waypoints.add(GpxWaypoint(
            latitude: parsed.$2,
            longitude: parsed.$1,
            elevation: parsed.$3,
            name: _childText(placemark, 'name'),
            description: _childText(placemark, 'description'),
          ));
        }
        continue;
      }

      for (final lineString in lineStrings) {
        final coordsText = _childText(lineString, 'coordinates');
        if (coordsText == null) continue;
        var isFirstOfSegment = true;
        for (final tuple in coordsText.split(RegExp(r'\s+'))) {
          if (tuple.trim().isEmpty) continue;
          final parsed = _parseCoordinateTuple(tuple);
          if (parsed == null) continue;
          trackPoints.add(GpxTrackPoint(
            latitude: parsed.$2,
            longitude: parsed.$1,
            elevation: parsed.$3,
            startsNewSegment: isFirstOfSegment,
          ));
          isFirstOfSegment = false;
        }
      }

      for (final gxTrack in gxTracks) {
        final whens = gxTrack.findElements('when').toList();
        final coords = gxTrack.findElements('gx:coord').toList();
        var isFirstOfSegment = true;
        for (var i = 0; i < coords.length; i++) {
          final parsed = _parseCoordinateTuple(coords[i].innerText, separator: RegExp(r'\s+'));
          if (parsed == null) continue;
          final time = i < whens.length ? DateTime.tryParse(whens[i].innerText.trim()) : null;
          trackPoints.add(GpxTrackPoint(
            latitude: parsed.$2,
            longitude: parsed.$1,
            elevation: parsed.$3,
            time: time,
            startsNewSegment: isFirstOfSegment,
          ));
          isFirstOfSegment = false;
        }
      }
    }

    GpxLimits.checkPointCounts(trackPoints: trackPoints.length, waypoints: waypoints.length);

    return GpxParseResult(
      trackPoints: trackPoints,
      waypoints: waypoints,
      traceName: _traceName(kmlElements.first),
    );
  }

  /// Parse un triplet de coordonnées `lon,lat[,ele]` (KML classique,
  /// `separator` = `,`) ou `lon lat [ele]` (`gx:coord`, `separator` =
  /// espaces). Retourne `(lon, lat, ele)` ou `null` si illisible, hors
  /// plage, ou non fini (`NaN`/`Infinity` — voir GpxLimits).
  static (double, double, double?)? _parseCoordinateTuple(
    String raw, {
    Pattern separator = ',',
  }) {
    final parts = raw.trim().split(separator).where((s) => s.trim().isNotEmpty).toList();
    if (parts.length < 2) return null;
    final lon = double.tryParse(parts[0].trim());
    final lat = double.tryParse(parts[1].trim());
    if (lon == null || lat == null) return null;
    if (!GpxLimits.isValidLatitude(lat) || !GpxLimits.isValidLongitude(lon)) return null;
    final eleRaw = parts.length > 2 ? double.tryParse(parts[2].trim()) : null;
    final ele = (eleRaw != null && GpxLimits.isValidElevation(eleRaw)) ? eleRaw : null;
    return (lon, lat, ele);
  }

  static String? _childText(XmlElement parent, String tag) {
    final matches = parent.findElements(tag);
    if (matches.isEmpty) return null;
    final text = matches.first.innerText.trim();
    return text.isEmpty ? null : text;
  }

  static String? _traceName(XmlElement kmlEl) {
    final documentEls = kmlEl.findElements('Document');
    if (documentEls.isNotEmpty) {
      final name = _childText(documentEls.first, 'name');
      if (name != null) return name;
    }
    return _childText(kmlEl, 'name');
  }
}
