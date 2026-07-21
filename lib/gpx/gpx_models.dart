/// Représentation intermédiaire d'un fichier GPX, indépendante du parseur
/// utilisé pour l'obtenir. Sert de pont entre [GpxParser] et
/// [SegmentationEngine] : ce dernier ne connaît que ces classes, jamais
/// le XML brut ni une bibliothèque tierce de parsing.
library;

class GpxTrackPoint {
  const GpxTrackPoint({
    required this.latitude,
    required this.longitude,
    this.elevation,
    this.time,
    this.startsNewSegment = false,
  });

  final double latitude;
  final double longitude;
  final double? elevation;
  final DateTime? time;

  /// `true` si ce point est le premier d'un nouveau `<trkseg>`.
  ///
  /// La spécification GPX précise qu'un nouveau `<trkseg>` marque une
  /// coupure réelle de l'enregistrement (perte de signal GPS, appareil
  /// éteint, changement de jour de randonnée...) : c'est donc un point de
  /// coupure légitime pour le découpage en segments, au même titre qu'une
  /// intersection avec la toile existante ou un point d'intérêt.
  final bool startsNewSegment;
}

class GpxWaypoint {
  const GpxWaypoint({
    required this.latitude,
    required this.longitude,
    this.elevation,
    this.name,
    this.description,
    this.rawType,
  });

  final double latitude;
  final double longitude;
  final double? elevation;
  final String? name;
  final String? description;

  /// Contenu brut de la balise `<type>` du waypoint, si présente. Utilisé
  /// pour une classification best-effort en [POIType]. Peut être `null`
  /// ou inexploitable selon le logiciel source (Garmin, OsmAnd, IGN
  /// Rando... n'utilisent pas de vocabulaire standardisé).
  final String? rawType;
}

class GpxParseResult {
  const GpxParseResult({
    required this.trackPoints,
    required this.waypoints,
    this.traceName,
  });

  /// Tous les points de trace (`<trkpt>`), tous segments `<trkseg>`
  /// confondus, concaténés dans l'ordre du fichier. Les ruptures entre
  /// segments restent visibles via [GpxTrackPoint.startsNewSegment].
  final List<GpxTrackPoint> trackPoints;

  final List<GpxWaypoint> waypoints;

  /// Nom de la trace, si présent (`<metadata><name>` ou, à défaut,
  /// `<trk><name>` de la première trace du fichier).
  final String? traceName;
}
