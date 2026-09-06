import 'package:flutter/foundation.dart';

import '../utils/settings_service.dart';
import 'weather_api_client.dart';
import 'weather_conditions.dart';
import 'weather_models.dart';

/// Alimente la stat card « Météo » du volet Navigation (§3.2).
///
/// Désactivé par défaut, comme le podomètre : l'utilisateur tape sur le
/// carré « Météo » pour l'activer (premier chargement) ou le rafraîchir. Un
/// double-tap ouvre la page Météo plein écran.
///
/// Un seul appel `forecast.hours` avec `hours=4` : le premier enregistrement
/// couvre « maintenant », les quatre servent à choisir l'icône de tendance.
/// L'instance [client] est partagée avec la page Météo pour bénéficier du
/// cache de session (§8).
class WeatherService extends ChangeNotifier {
  WeatherService({WeatherApiClient? client, SettingsService? settings})
      : client = client ?? WeatherApiClient(),
        _settings = settings;

  final WeatherApiClient client;
  SettingsService? _settings;

  /// Injecté après construction dans `main.dart` (ordre d'init : le service
  /// est créé avant que `SettingsService` ne soit prêt).
  set settings(SettingsService value) => _settings = value;

  bool _isActive = false;
  bool _isLoading = false;
  String? _error;
  List<HourForecast> _hours = const [];

  bool get isActive => _isActive;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// `true` si la clé API n'a pas été fournie au build : la carte reste
  /// utilisable mais aucun appel n'est tenté.
  bool get isConfigured => client.isConfigured;

  /// `weatherCondition.type` le plus notable pour un randonneur parmi les 4
  /// prochaines heures (§3.2) — `null` tant qu'aucune donnée n'est chargée.
  /// La requête ne demande que `hours=4`, donc `_hours` contient déjà
  /// exactement la fenêtre voulue (enregistrement 0 = heure en cours).
  String? get next4HoursCondition {
    if (_hours.isEmpty) return null;
    return mostNotableCondition(_hours.map((h) => h.conditionType));
  }

  /// Bascule l'activation ; [lat]/[lon] (position GPS courante) sont
  /// nécessaires pour charger la météo à l'activation.
  Future<void> toggle(double? lat, double? lon) async {
    _isActive = !_isActive;
    if (_isActive) {
      await refresh(lat, lon);
    } else {
      _hours = const [];
      _error = null;
      notifyListeners();
    }
  }

  Future<void> refresh(double? lat, double? lon) async {
    if (lat == null || lon == null) {
      _error = 'Position GPS indisponible';
      notifyListeners();
      return;
    }
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      _hours = await client.forecastHours(
        lat: lat,
        lon: lon,
        hours: 4,
        units: _settings?.weatherUnitSystem ?? UnitSystem.metric,
      );
    } on WeatherUnavailable catch (e) {
      _error = e.frenchMessage;
      _hours = const [];
    } catch (e) {
      _error = 'Météo indisponible';
      _hours = const [];
      debugPrint('WeatherService: erreur de chargement: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    client.dispose();
    super.dispose();
  }
}
