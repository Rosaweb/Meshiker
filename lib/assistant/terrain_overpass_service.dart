import '../utils/overpass_service.dart';

/// Un objet OSM (node/way/relation) renvoyé par une requête corridor
/// [TerrainOverpassService.fetchElementsAroundPath], avec sa géométrie
/// complète — un seul point pour un `node`, la liste ordonnée des sommets
/// pour un `way`/une `relation` (`out geom;`, cf. requête).
class TerrainOsmElement {
  TerrainOsmElement({
    required this.id,
    required this.isWay,
    required this.tags,
    required this.geometry,
  });

  /// `"type/id"` OSM (ex. `"way/123456"`), stable et unique tous types
  /// confondus — sert de clé de dédoublonnage si besoin en aval.
  final String id;

  /// `true` pour un `way`/une `relation` (géométrie à plusieurs sommets),
  /// `false` pour un `node` (point unique) — distinction nécessaire pour la
  /// classification géométrique (croisement/longement n'ont de sens que
  /// pour une ligne).
  final bool isWay;

  final Map<String, String> tags;

  /// Toujours non vide (un `node` produit une géométrie à un seul point).
  final List<({double lat, double lon})> geometry;
}

/// Clés de tags interrogées pour l'analyse terrain (spec-assistant-terrain-topo.md
/// §3.3) — volontairement un ensemble stable et court, filtré par CLÉ
/// jamais par valeur (cf. §2 du même document : l'app ne maintient pas de
/// liste blanche de valeurs, condamnée à devenir obsolète).
const kTerrainOverpassKeys = [
  'natural',
  'historic',
  'man_made',
  'waterway',
  'railway',
  'barrier',
  'bridge',
  'tunnel',
  'ford',
  'tourism',
  'leisure',
  'landuse',
  'highway',
];

/// Requête Overpass "corridor" autour d'une trace de randonnée, pour
/// l'analyse terrain de l'assistant IA (spec-assistant-terrain-topo.md).
///
/// Distinct de [OverpassService.fetchPois] (bbox, `node` uniquement,
/// catégorisation POI pour l'affichage carte) : ce service interroge
/// `node`+`way`+`relation` le long d'une polyligne simplifiée, sans
/// catégorisation UI — les objets bruts (tags + géométrie) sont renvoyés
/// tels quels, le classement géométrique et l'interprétation sémantique se
/// font en aval (`TerrainAnalysisService`, puis Gemini). Réutilise
/// volontairement la plomberie HTTP bas niveau de [OverpassService]
/// (`runQuery`) plutôt que de la dupliquer — cf. §2 de la spec.
class TerrainOverpassService {
  TerrainOverpassService._();

  /// Interroge tous les objets OSM dont une clé de [kTerrainOverpassKeys]
  /// est renseignée, dans un corridor de [bufferMeters] autour de
  /// [simplifiedPolyline] (déjà simplifiée par
  /// `GeoUtils.simplifyDouglasPeucker` — cette méthode ne le fait pas
  /// elle-même, pour rester un simple client HTTP sans logique
  /// géométrique).
  ///
  /// Construction en une seule clause `nwr[~"^(clé1|clé2|...)$"~"."]` avec
  /// le filtre `around:` à liste de points, plutôt qu'une clause par clé :
  /// répéter la liste de points (potentiellement plusieurs dizaines de
  /// sommets) une fois par clé gonflerait inutilement la requête pour un
  /// gain nul.
  static Future<List<TerrainOsmElement>> fetchElementsAroundPath({
    required List<({double lat, double lon})> simplifiedPolyline,
    required double bufferMeters,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (simplifiedPolyline.length < 2) return [];

    final aroundList = simplifiedPolyline.map((p) => '${p.lat},${p.lon}').join(',');
    final keyPattern = kTerrainOverpassKeys.join('|');
    final query = '[out:json][timeout:25];'
        'nwr[~"^($keyPattern)\$"~"."](around:${bufferMeters.round()},$aroundList);'
        'out geom;';

    final data = await OverpassService.runQuery(query, timeout: timeout);
    if (data == null) return [];

    final elements = data['elements'] as List? ?? const [];
    return _parseElements(elements);
  }

  static List<TerrainOsmElement> _parseElements(List elements) {
    final result = <TerrainOsmElement>[];
    for (final raw in elements) {
      final e = raw as Map<String, dynamic>;
      final rawTags = e['tags'];
      if (rawTags is! Map || rawTags.isEmpty) continue; // sans tags, rien à classifier
      final tags = rawTags.cast<String, dynamic>().map((k, v) => MapEntry(k, v.toString()));

      final type = e['type'] as String;
      final List<({double lat, double lon})> geometry;
      if (type == 'node') {
        final lat = e['lat'];
        final lon = e['lon'];
        if (lat == null || lon == null) continue;
        geometry = [(lat: (lat as num).toDouble(), lon: (lon as num).toDouble())];
      } else {
        final geom = e['geometry'];
        if (geom is! List || geom.isEmpty) continue;
        geometry = geom
            .whereType<Map>()
            .where((g) => g['lat'] != null && g['lon'] != null)
            .map((g) => (lat: (g['lat'] as num).toDouble(), lon: (g['lon'] as num).toDouble()))
            .toList();
        if (geometry.isEmpty) continue;
      }

      result.add(TerrainOsmElement(
        id: '$type/${e['id']}',
        isWay: type != 'node',
        tags: tags,
        geometry: geometry,
      ));
    }
    return result;
  }
}
