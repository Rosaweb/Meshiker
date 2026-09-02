import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Service d'enrichissement altimétrique (modèle numérique de terrain).
///
/// Utilise l'API publique OpenTopoData (gratuite, open source, auto-hébergeable
/// si le volume le justifie un jour — voir
/// `spec-calibrage-podometre-elevation.md` §4.4). Overpass ne convient pas :
/// c'est une base de tags OSM, pas un modèle de terrain.
///
/// L'enrichissement d'une trace est un événement **unique** (résultat mis en
/// cache dans Isar, jamais réinterrogé) et échantillonné à la granularité de
/// calibrage (~50-100 m), donc le volume reste très en dessous des limites
/// (100 points/req, 1 req/s, 1000 req/jour) — aucun throttling élaboré requis
/// au-delà du délai de politesse d'1 req/s.
class ElevationService {
  static const _baseUrl = 'https://api.opentopodata.org/v1/srtm30m';
  static const _maxLocationsPerRequest = 100;

  /// Retourne une liste de même longueur que [points], avec `null` aux index
  /// où la récupération a échoué (réseau indisponible, terrain sans donnée,
  /// statut HTTP non-200...).
  static Future<List<double?>> fetchElevations(
    List<({double lat, double lon})> points,
  ) async {
    final results = List<double?>.filled(points.length, null);
    if (points.isEmpty) return results;

    for (var offset = 0;
        offset < points.length;
        offset += _maxLocationsPerRequest) {
      final chunk =
          points.skip(offset).take(_maxLocationsPerRequest).toList();
      final locations = chunk.map((p) => '${p.lat},${p.lon}').join('|');

      try {
        final response = await http
            .get(Uri.parse('$_baseUrl?locations=$locations'))
            .timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final data = json.decode(response.body) as Map<String, dynamic>;
          final resultsJson = (data['results'] as List?) ?? const [];
          for (var i = 0; i < resultsJson.length; i++) {
            final ele = (resultsJson[i] as Map<String, dynamic>)['elevation'];
            if (ele is num) results[offset + i] = ele.toDouble();
          }
        } else {
          debugPrint(
              'ElevationService: HTTP ${response.statusCode} sur $_baseUrl');
        }
      } catch (e) {
        debugPrint('ElevationService: fetch failed: $e');
        // Hors-ligne / erreur : on laisse `null`, retenté plus tard.
      }

      if (offset + _maxLocationsPerRequest < points.length) {
        await Future.delayed(const Duration(milliseconds: 1100)); // 1 req/s
      }
    }
    return results;
  }
}
