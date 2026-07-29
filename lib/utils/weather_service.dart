import 'package:flutter/material.dart';
import 'package:open_meteo/open_meteo.dart';

/// Regroupe les codes météo WMO (utilisés par Open-Meteo) en icônes
/// Material génériques -- volontairement provisoire, à remplacer par des
/// icônes météo dédiées plus tard si besoin.
IconData weatherCodeIcon(int code) {
  if (code == 0) return Icons.wb_sunny;
  if (code <= 3) return Icons.wb_cloudy;
  if (code == 45 || code == 48) return Icons.foggy;
  if (code >= 51 && code <= 67) return Icons.grain;
  if ((code >= 71 && code <= 77) || code == 85 || code == 86) return Icons.ac_unit;
  if (code >= 80 && code <= 82) return Icons.grain;
  if (code >= 95) return Icons.thunderstorm;
  return Icons.cloud;
}

String weatherCodeLabel(int code) {
  if (code == 0) return 'Ciel dégagé';
  if (code == 1) return 'Généralement clair';
  if (code == 2) return 'Partiellement nuageux';
  if (code == 3) return 'Couvert';
  if (code == 45 || code == 48) return 'Brouillard';
  if (code >= 51 && code <= 57) return 'Bruine';
  if (code >= 61 && code <= 67) return 'Pluie';
  if (code >= 71 && code <= 77) return 'Neige';
  if (code >= 80 && code <= 82) return 'Averses';
  if (code == 85 || code == 86) return 'Averses de neige';
  if (code >= 95) return 'Orage';
  return 'Inconnu';
}

/// Sévérité grossière d'un code météo, utilisée pour choisir le code le
/// plus significatif parmi plusieurs heures (ex: alerter sur un orage à
/// venir plutôt que sur le ciel dégagé de l'heure courante).
int _weatherCodeSeverity(int code) {
  if (code >= 95) return 6;
  if ((code >= 71 && code <= 77) || code == 85 || code == 86) return 5;
  if ((code >= 61 && code <= 67) || (code >= 80 && code <= 82)) return 4;
  if (code >= 51 && code <= 57) return 3;
  if (code == 45 || code == 48) return 2;
  if (code >= 1 && code <= 3) return 1;
  return 0;
}

/// Récupère et expose la météo Open-Meteo pour une position donnée.
/// Désactivé par défaut (comme le podomètre) : l'utilisateur doit taper
/// sur le carré "Météo" du panneau Navigation pour l'activer, ce qui
/// déclenche le premier chargement.
class WeatherService extends ChangeNotifier {
  static const _api = WeatherApi();

  bool _isActive = false;
  bool _isLoading = false;
  String? _error;
  ResponseSegment? _segment;

  bool get isActive => _isActive;
  bool get isLoading => _isLoading;
  String? get error => _error;
  ResponseSegment? get segment => _segment;

  /// Code météo (WMO) le plus significatif parmi les 4 prochaines heures,
  /// pour l'icône résumée du carré -- null tant qu'aucune donnée n'est
  /// disponible.
  int? get next4HoursWeatherCode {
    final hourly = _segment?.hourlyData[WeatherHourly.weather_code];
    if (hourly == null || hourly.values.isEmpty) return null;
    final now = DateTime.now();
    final window = now.add(const Duration(hours: 4));
    final upcoming = hourly.values.entries
        .where((e) => !e.key.isBefore(now) && e.key.isBefore(window))
        .map((e) => e.value.toInt())
        .toList();
    if (upcoming.isEmpty) return null;
    upcoming.sort(
        (a, b) => _weatherCodeSeverity(b).compareTo(_weatherCodeSeverity(a)));
    return upcoming.first;
  }

  /// Bascule l'activation ; [lat]/[lon] (position GPS courante) sont
  /// nécessaires pour charger la météo à l'activation.
  Future<void> toggle(double? lat, double? lon) async {
    _isActive = !_isActive;
    if (_isActive) {
      await refresh(lat, lon);
    } else {
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
      final response = await _api.request(
        locations: {OpenMeteoLocation(latitude: lat, longitude: lon)},
        hourly: const {
          WeatherHourly.weather_code,
          WeatherHourly.temperature_2m,
          WeatherHourly.precipitation_probability,
        },
        daily: const {
          WeatherDaily.weather_code,
          WeatherDaily.temperature_2m_max,
          WeatherDaily.temperature_2m_min,
          WeatherDaily.precipitation_probability_max,
        },
        forecastDays: 2,
      );
      _segment = response.segments.first;
    } catch (e) {
      _error = 'Météo indisponible';
      debugPrint('WeatherService: erreur de chargement: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}
