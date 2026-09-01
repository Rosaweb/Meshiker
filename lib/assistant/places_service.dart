import '../utils/supabase_bootstrap_service.dart';

/// Client léger pour l'Edge Function `assistant-places` (v2, function
/// calling de l'assistant IA — recherche de commerces à proximité et
/// horaires via Google Places API). Même piège à éviter qu'avec
/// `assistant-token` : la clé Google Places ne doit jamais atteindre le
/// client, cette classe ne parle qu'à Supabase, qui appelle Google Places
/// côté serveur.
class PlacesService {
  PlacesService({required this.supabaseBootstrap});

  final SupabaseBootstrapService supabaseBootstrap;

  /// Recherche des commerces/services à proximité de [latitude]/[longitude].
  /// [query] est un texte libre en français (ex. "boulangerie", "pharmacie
  /// de garde") — transmis tel quel à la recherche textuelle Google Places,
  /// qui gère mieux le langage naturel qu'une énumération de types anglais.
  Future<Map<String, dynamic>> searchNearby({
    required double latitude,
    required double longitude,
    required String query,
    int radiusMeters = 2000,
  }) => _invoke({
        'action': 'search',
        'query': query,
        'latitude': latitude,
        'longitude': longitude,
        'radiusMeters': radiusMeters,
      });

  /// Horaires détaillés d'un commerce déjà trouvé via [searchNearby]
  /// (identifié par son `placeId` Google Places).
  Future<Map<String, dynamic>> placeHours({required String placeId}) => _invoke({
        'action': 'hours',
        'placeId': placeId,
      });

  Future<Map<String, dynamic>> _invoke(Map<String, dynamic> body) async {
    final ready = await supabaseBootstrap.ensureReady();
    final client = ready ? supabaseBootstrap.clientOrNull : null;
    if (client == null) {
      return {'erreur': 'service_indisponible'};
    }
    try {
      final response = await client.functions.invoke('assistant-places', body: body);
      if (response.status != 200) {
        return {'erreur': 'recherche_echouee'};
      }
      return response.data as Map<String, dynamic>;
    } catch (_) {
      return {'erreur': 'recherche_echouee'};
    }
  }
}
