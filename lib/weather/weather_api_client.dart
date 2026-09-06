import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../utils/settings_service.dart';
import 'weather_models.dart';

/// Raison d'indisponibilité de la météo, pour choisir le message affiché.
enum WeatherUnavailableReason {
  /// `GOOGLE_WEATHER_API_KEY` absente du build (`--dart-define-from-file`).
  notConfigured,

  /// Aucune connectivité réseau (« zone blanche »).
  offline,

  /// Timeout, erreur réseau, ou statut HTTP non-200.
  network,
}

class WeatherUnavailable implements Exception {
  final WeatherUnavailableReason reason;

  /// Message précis optionnel ; sinon [frenchMessage] déduit de [reason].
  final String? detail;

  const WeatherUnavailable(this.reason, {this.detail});

  String get frenchMessage =>
      detail ??
      switch (reason) {
        WeatherUnavailableReason.notConfigured =>
          'Météo indisponible (configuration manquante).',
        WeatherUnavailableReason.offline => 'Météo indisponible hors ligne.',
        WeatherUnavailableReason.network => 'Météo indisponible.',
      };

  @override
  String toString() => 'WeatherUnavailable(${reason.name})';
}

/// Client REST de la Google Maps Platform Weather API (WeatherNext 3).
///
/// - Clé lue via `String.fromEnvironment('GOOGLE_WEATHER_API_KEY')`
///   (`--dart-define-from-file=env.json`), clé *client* restreinte par
///   package Android / bundle iOS + limitée à la Weather API dans la console
///   Google Cloud (§6). Distincte de la clé Places serveur.
/// - Facturation par appel (§2) : un point interrogé = un appel. `pageSize`
///   est fixé au nombre d'heures/jours demandés (toujours ≤ 24 / ≤ 5) donc
///   la réponse tient sur une seule page, jamais de pagination facturée.
/// - Cache mémoire de session (§8) : TTL court, clé =
///   endpoint + lat/lon arrondis (~100 m) + horizon + unités. Partagé entre
///   la stat card et la page météo via l'instance unique exposée par
///   `WeatherService`. Vidé au redémarrage de l'app.
class WeatherApiClient {
  WeatherApiClient({
    http.Client? httpClient,
    Connectivity? connectivity,
    String? apiKeyOverride,
    this.cacheTtl = const Duration(minutes: 10),
  })  : _http = httpClient ?? http.Client(),
        _connectivity = connectivity ?? Connectivity(),
        _apiKey = apiKeyOverride ?? _envApiKey;

  static const _envApiKey = String.fromEnvironment('GOOGLE_WEATHER_API_KEY');
  static const _base = 'https://weather.googleapis.com/v1';

  final http.Client _http;
  final Connectivity _connectivity;
  final String _apiKey;
  final Duration cacheTtl;

  final Map<String, _CacheEntry> _cache = {};

  /// `false` si la clé n'a pas été fournie au build : toutes les surfaces
  /// météo doivent alors afficher un état « indisponible » sans jamais
  /// tenter d'appel.
  bool get isConfigured => _apiKey.isNotEmpty;

  /// Prévisions horaires pour un point. [hours] ∈ [1, 24].
  Future<List<HourForecast>> forecastHours({
    required double lat,
    required double lon,
    required int hours,
    required UnitSystem units,
  }) async {
    final h = hours.clamp(1, 24);
    final data = await _get(
      path: 'forecast/hours:lookup',
      lat: lat,
      lon: lon,
      units: units,
      extraParams: {'hours': '$h', 'pageSize': '$h'},
      cacheKey: 'hours',
      horizon: h,
    );
    final list = (data['forecastHours'] as List?) ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(HourForecast.fromJson)
        .toList();
  }

  /// Prévisions journalières. [days] ∈ [1, 5].
  Future<List<DayForecast>> forecastDays({
    required double lat,
    required double lon,
    required int days,
    required UnitSystem units,
  }) async {
    final d = days.clamp(1, 5);
    final data = await _get(
      path: 'forecast/days:lookup',
      lat: lat,
      lon: lon,
      units: units,
      extraParams: {'days': '$d', 'pageSize': '$d'},
      cacheKey: 'days',
      horizon: d,
    );
    final list = (data['forecastDays'] as List?) ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(DayForecast.fromJson)
        .toList();
  }

  void clearCache() => _cache.clear();

  void dispose() => _http.close();

  Future<Map<String, dynamic>> _get({
    required String path,
    required double lat,
    required double lon,
    required UnitSystem units,
    required Map<String, String> extraParams,
    required String cacheKey,
    required int horizon,
  }) async {
    if (!isConfigured) {
      throw const WeatherUnavailable(WeatherUnavailableReason.notConfigured);
    }

    final unitsSystem = units == UnitSystem.imperial ? 'IMPERIAL' : 'METRIC';
    // ~100 m de résolution : suffisant pour dédoublonner des ouvertures
    // successives de la page sans multiplier les entrées de cache.
    final latKey = lat.toStringAsFixed(3);
    final lonKey = lon.toStringAsFixed(3);
    final key = '$cacheKey|$latKey|$lonKey|$horizon|$unitsSystem';

    final cached = _cache[key];
    if (cached != null && !cached.isExpired(cacheTtl)) {
      return cached.data;
    }

    final connectivity = await _connectivity.checkConnectivity();
    if (connectivity.every((r) => r == ConnectivityResult.none)) {
      throw const WeatherUnavailable(WeatherUnavailableReason.offline);
    }

    final uri = Uri.parse('$_base/$path').replace(queryParameters: {
      'key': _apiKey,
      'location.latitude': '$lat',
      'location.longitude': '$lon',
      'unitsSystem': unitsSystem,
      'languageCode': 'fr',
      ...extraParams,
    });

    try {
      final response =
          await _http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        debugPrint(
            'WeatherApiClient: HTTP ${response.statusCode} sur $path — ${response.body}');
        throw const WeatherUnavailable(WeatherUnavailableReason.network);
      }
      final decoded = json.decode(response.body) as Map<String, dynamic>;
      _cache[key] = _CacheEntry(decoded, DateTime.now());
      return decoded;
    } on WeatherUnavailable {
      rethrow;
    } catch (e) {
      debugPrint('WeatherApiClient: échec $path — $e');
      throw const WeatherUnavailable(WeatherUnavailableReason.network);
    }
  }
}

class _CacheEntry {
  final Map<String, dynamic> data;
  final DateTime fetchedAt;
  _CacheEntry(this.data, this.fetchedAt);

  bool isExpired(Duration ttl) => DateTime.now().difference(fetchedAt) > ttl;
}
