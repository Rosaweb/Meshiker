import 'dart:convert';
import 'package:http/http.dart' as http;

/// Service de secours pour l'altimétrie manquante (spec-assistant-terrain-topo.md
/// §3.2, point ouvert §8.2) : appelé UNIQUEMENT quand une portion de trace
/// n'a pas d'altitude fiable (import GPX sans données GPS/baro) — jamais en
/// remplacement des altitudes déjà mesurées, qui restent toujours
/// prioritaires.
///
/// Choix Open-Elevation plutôt que Google Elevation API : service public
/// gratuit, sans clé — même logique que `OverpassService`/Overpass pour ce
/// pipeline (cf. §2 de la spec, tout reste côté client sans secret à
/// cacher). Précision inférieure aux données dédiées (IGN en France),
/// acceptable puisqu'utilisée uniquement en comblement (cf. §7, limites
/// connues de la spec).
class ElevationFallbackService {
  ElevationFallbackService._();

  static const _endpoint = 'https://api.open-elevation.com/api/v1/lookup';

  /// Renvoie une altitude (mètres) par point d'entrée, dans le même ordre,
  /// ou `null` pour un point dont l'altitude n'a pas pu être obtenue —
  /// échec silencieux (réseau, timeout, service indisponible) : à
  /// l'appelant de dégrader gracieusement (garder les `null` existants)
  /// plutôt que de faire échouer toute l'analyse terrain pour ça.
  static Future<List<double?>> fetchElevations(
    List<({double lat, double lon})> points, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (points.isEmpty) return [];

    try {
      final response = await http
          .post(
            Uri.parse(_endpoint),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'locations': points.map((p) => {'latitude': p.lat, 'longitude': p.lon}).toList(),
            }),
          )
          .timeout(timeout);
      if (response.statusCode != 200) return List<double?>.filled(points.length, null);

      final data = json.decode(response.body) as Map<String, dynamic>;
      final results = data['results'] as List?;
      if (results == null || results.length != points.length) {
        return List<double?>.filled(points.length, null);
      }
      return results
          .map((r) => ((r as Map<String, dynamic>)['elevation'] as num?)?.toDouble())
          .toList();
    } catch (_) {
      return List<double?>.filled(points.length, null);
    }
  }
}
