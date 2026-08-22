import 'overpass_service.dart';

/// Cache par grille des POI OSM déjà récupérés, pour ne pas rappeler
/// Overpass quand l'utilisateur revient sur une zone déjà visitée dans la
/// session en cours. Un cache par bbox exacte ne suffirait pas (l'utilisateur
/// ne revient jamais exactement sur le même rectangle) -- la grille fixe,
/// avec une cellule mise en cache indépendamment des autres, résout ça.
///
/// Uniquement en mémoire (pas de persistance disque) : se réinitialise à
/// chaque redémarrage, pas de TTL nécessaire en V1.
class OsmPoiCache {
  static const double cellSizeDeg = 0.05; // ~5 km, ajustable

  final Map<String, List<OsmPoi>> _cells = {}; // clé "x_y_categoryId"

  static (int, int) cellIndex(double lat, double lon) =>
      ((lon / cellSizeDeg).floor(), (lat / cellSizeDeg).floor());

  static List<(int, int)> cellsInBbox(double minLat, double minLon, double maxLat, double maxLon) {
    final (x0, y0) = cellIndex(minLat, minLon);
    final (x1, y1) = cellIndex(maxLat, maxLon);
    return [for (var x = x0; x <= x1; x++) for (var y = y0; y <= y1; y++) (x, y)];
  }

  bool hasCell(int cx, int cy, String categoryId) => _cells.containsKey('${cx}_${cy}_$categoryId');
  List<OsmPoi> cell(int cx, int cy, String categoryId) => _cells['${cx}_${cy}_$categoryId'] ?? const [];
  void put(int cx, int cy, String categoryId, List<OsmPoi> pois) => _cells['${cx}_${cy}_$categoryId'] = pois;
}
