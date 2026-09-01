import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:collection/collection.dart';

import '../map/osm_poi_categories.dart';

class OsmPoi {
  final String id; // node id OSM -- clé de dédoublonnage
  final String categoryId; // référence à OsmPoiCategoryDef.id
  final String name;
  final LatLng location;
  final Map<String, String> tags; // tags bruts (adresse, téléphone, horaires...)

  OsmPoi({
    required this.id,
    required this.categoryId,
    required this.name,
    required this.location,
    this.tags = const {},
  });
}

/// Vérifie qu'un fragment Overpass du type '["shop"="bakery"]' correspond
/// bien aux [tags] d'un élément -- utilisé pour retrouver la catégorie
/// d'origine d'un POI reçu du serveur (qui ne renvoie pas cette info
/// directement).
bool _fragmentMatches(Map<String, String> tags, String fragment) {
  final regex = RegExp(r'"([^"]+)"="([^"]+)"');
  for (final match in regex.allMatches(fragment)) {
    final key = match.group(1)!;
    final value = match.group(2)!;
    if (tags[key] != value) return false;
  }
  return true;
}

class OverpassService {
  /// Exécute une requête Overpass QL brute et renvoie le JSON décodé, ou
  /// `null` en cas d'échec (timeout, réseau, statut HTTP non-200) — échec
  /// silencieux volontaire, à l'appelant de décider du repli (liste vide,
  /// message "indisponible"...), cohérent avec le reste du pipeline OSM de
  /// l'app.
  ///
  /// Point d'entrée HTTP partagé par [fetchPois] (POI carte, requête bbox)
  /// et `TerrainOverpassService` (analyse terrain assistant IA, requête
  /// corridor `around:` — cf. `spec-assistant-terrain-topo.md` §2) : les
  /// deux besoins construisent des requêtes très différentes, mais aucune
  /// raison de dupliquer l'appel réseau lui-même.
  static Future<Map<String, dynamic>?> runQuery(
    String query, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('https://overpass-api.de/api/interpreter'),
            headers: {'User-Agent': 'Meshiker/1.0'},
            body: query,
          )
          .timeout(timeout);
      if (response.statusCode != 200) return null;
      return json.decode(response.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<List<OsmPoi>> fetchPois({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    required Set<String> categoryIds,
  }) async {
    if (categoryIds.isEmpty) return [];

    final clauses = <String>[];
    for (final catId in categoryIds) {
      final def = kOsmPoiCategories.firstWhereOrNull((c) => c.id == catId);
      if (def == null) continue;
      for (final fragment in def.overpassFilters) {
        clauses.add('node$fragment($minLat,$minLon,$maxLat,$maxLon);');
      }
    }
    if (clauses.isEmpty) return [];

    final query = '[out:json][timeout:25];(${clauses.join()});out body;';
    final data = await runQuery(query, timeout: const Duration(seconds: 25));
    if (data == null) return [];

    final elements = data['elements'] as List;
    return elements.map((e) {
      final tags = Map<String, String>.from(e['tags'] ?? {});
      final matched = kOsmPoiCategories.firstWhere(
        (c) => c.overpassFilters.any((f) => _fragmentMatches(tags, f)),
        orElse: () => kOsmPoiCategories.first,
      );
      return OsmPoi(
        id: e['id'].toString(),
        categoryId: matched.id,
        name: tags['name'] ?? matched.label,
        location: LatLng(e['lat'], e['lon']),
        tags: tags,
      );
    }).toList();
  }
}
