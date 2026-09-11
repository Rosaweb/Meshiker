import 'package:xml/xml.dart';

import 'gpx_models.dart';
import 'gpx_validation.dart';

/// Parseur GPX minimaliste, construit directement sur `package:xml`
/// plutôt que sur un wrapper GPX de plus haut niveau (type `gpx` ou
/// `geoxml`).
///
/// Choix assumé : `package:xml` est l'une des bibliothèques Dart les plus
/// anciennes, stables et largement utilisées (y compris en interne par
/// d'autres packages de l'écosystème) ; son API de base (`XmlDocument.parse`,
/// `findElements`, `getAttribute`, `innerText`) n'a pas de raison de
/// changer. À l'inverse, un wrapper GPX dédié impose un modèle d'objets
/// dont l'API exacte peut varier d'une version à l'autre, pour un fichier
/// GPX dont on n'a de toute façon besoin que d'un sous-ensemble de champs
/// (lat/lon/ele/time/name/desc/type). Écrire ces quelques dizaines de
/// lignes nous-mêmes, une fois, élimine ce risque.
///
/// Ne gère que ce dont l'app a besoin : `<trk>/<trkseg>/<trkpt>` et
/// `<wpt>`. Les `<rte>` (itinéraires planifiés) ne sont pas traités ici ;
/// à ajouter si le besoin apparaît (mode planification, section 3 du
/// brief).
class GpxParser {
  const GpxParser._();

  static GpxParseResult parseString(String xmlContent) {
    // Rejette tôt un contenu anormalement volumineux, avant même de
    // tenter de construire l'arbre DOM (voir GpxLimits).
    GpxLimits.checkContentLength(xmlContent);

    final document = XmlDocument.parse(xmlContent);
    final gpxElements = document.findAllElements('gpx');
    if (gpxElements.isEmpty) {
      throw const FormatException('Fichier GPX invalide : balise <gpx> introuvable.');
    }
    final gpxEl = gpxElements.first;

    final trackPoints = <GpxTrackPoint>[];
    for (final trk in gpxEl.findElements('trk')) {
      for (final trkseg in trk.findElements('trkseg')) {
        var isFirstOfSegment = true;
        for (final trkpt in trkseg.findElements('trkpt')) {
          // Un point aux coordonnées invalides est ignoré (pas tout le
          // fichier) : on ne consomme isFirstOfSegment que pour un point
          // effectivement retenu, pour que le prochain point valide du
          // segment porte bien startsNewSegment.
          final point = _parsePoint(trkpt, startsNewSegment: isFirstOfSegment);
          if (point == null) continue;
          trackPoints.add(point);
          isFirstOfSegment = false;
        }
      }
    }

    final waypoints = <GpxWaypoint>[];
    for (final wpt in gpxEl.findElements('wpt')) {
      final p = _parsePoint(wpt);
      if (p == null) continue;
      waypoints.add(GpxWaypoint(
        latitude: p.latitude,
        longitude: p.longitude,
        elevation: p.elevation,
        name: _childText(wpt, 'name'),
        description: _childText(wpt, 'desc'),
        rawType: _childText(wpt, 'type'),
      ));
    }

    GpxLimits.checkPointCounts(trackPoints: trackPoints.length, waypoints: waypoints.length);

    return GpxParseResult(
      trackPoints: trackPoints,
      waypoints: waypoints,
      traceName: _traceName(gpxEl),
    );
  }

  /// Retourne `null` (point ignoré par l'appelant) si `lat`/`lon` sont
  /// absents, illisibles, ou hors plage/non finis (`NaN`, `Infinity`) —
  /// voir GpxLimits.isValidLatitude/isValidLongitude. Avant ce contrôle,
  /// une coordonnée invalide retombait silencieusement sur `0`, créant un
  /// faux point ("Null Island") plutôt que d'être rejetée.
  static GpxTrackPoint? _parsePoint(
    XmlElement el, {
    bool startsNewSegment = false,
  }) {
    final lat = double.tryParse(el.getAttribute('lat') ?? '');
    final lon = double.tryParse(el.getAttribute('lon') ?? '');
    if (lat == null || lon == null || !GpxLimits.isValidLatitude(lat) || !GpxLimits.isValidLongitude(lon)) {
      return null;
    }
    final eleText = _childText(el, 'ele');
    final eleRaw = eleText != null ? double.tryParse(eleText) : null;
    final ele = (eleRaw != null && GpxLimits.isValidElevation(eleRaw)) ? eleRaw : null;
    final timeText = _childText(el, 'time');
    final time = timeText != null ? DateTime.tryParse(timeText) : null;
    return GpxTrackPoint(
      latitude: lat,
      longitude: lon,
      elevation: ele,
      time: time,
      startsNewSegment: startsNewSegment,
    );
  }

  static String? _childText(XmlElement parent, String tag) {
    final matches = parent.findElements(tag);
    if (matches.isEmpty) return null;
    final text = matches.first.innerText.trim();
    return text.isEmpty ? null : text;
  }

  static String? _traceName(XmlElement gpxEl) {
    final metadataEls = gpxEl.findElements('metadata');
    if (metadataEls.isNotEmpty) {
      final name = _childText(metadataEls.first, 'name');
      if (name != null) return name;
    }
    final trkEls = gpxEl.findElements('trk');
    if (trkEls.isNotEmpty) {
      final name = _childText(trkEls.first, 'name');
      if (name != null) return name;
    }
    return null;
  }
}
