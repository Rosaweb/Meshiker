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

    try {
      final response = await http.post(
        Uri.parse('https://overpass-api.de/api/interpreter'),
        headers: {'User-Agent': 'Meshiker/1.0'},
        body: query,
      );
      if (response.statusCode != 200) return [];

      final data = json.decode(response.body);
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
    } catch (_) {
      return []; // échec silencieux, cohérent avec le reste du pipeline
    }
  }
}
