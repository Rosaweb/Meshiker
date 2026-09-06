/// Correspondances pour les valeurs de `weatherCondition.type` renvoyées par
/// la Google Maps Platform Weather API (enum chaîne, ex. `RAIN`,
/// `THUNDERSTORM`, `PARTLY_CLOUDY`...). Volontairement tolérant : tout type
/// inconnu ou `null` retombe sur un rendu neutre, jamais d'exception.
///
/// La table [_severity] matérialise la « liste de priorité » du §3.2 de
/// `spec-meteo.md` (icône de tendance des 4 prochaines heures) : c'est un
/// choix produit, éditable ici sans toucher au reste du code. Portée depuis
/// l'ancienne heuristique WMO `_weatherCodeSeverity` de `open_meteo`.
library;

import 'package:flutter/material.dart';

/// Normalise un type API en clé majuscule sans espaces superflus.
String _norm(String? type) => (type ?? '').trim().toUpperCase();

/// Sévérité « randonneur » d'une condition : plus la valeur est haute, plus
/// la condition mérite d'être mise en avant sur la fenêtre de tendance
/// (§3.2). Type inconnu → 0.
const Map<String, int> _severity = {
  // Orages / grêle — le plus notable
  'HEAVY_THUNDERSTORM': 8,
  'THUNDERSTORM': 8,
  'THUNDERSHOWER': 8,
  'LIGHT_THUNDERSTORM_RAIN': 8,
  'SCATTERED_THUNDERSTORMS': 8,
  'HAIL': 8,
  'HAIL_SHOWERS': 8,
  // Neige lourde / tempête de neige / poudrerie
  'HEAVY_SNOW_STORM': 7,
  'SNOWSTORM': 7,
  'BLOWING_SNOW': 7,
  'HEAVY_SNOW': 7,
  'HEAVY_SNOW_SHOWERS': 7,
  'SNOW_PERIODICALLY_HEAVY': 7,
  // Neige / neige-pluie
  'SNOW': 6,
  'LIGHT_SNOW': 6,
  'LIGHT_SNOW_SHOWERS': 6,
  'SNOW_SHOWERS': 6,
  'SCATTERED_SNOW_SHOWERS': 6,
  'CHANCE_OF_SNOW_SHOWERS': 6,
  'LIGHT_TO_MODERATE_SNOW': 6,
  'MODERATE_TO_HEAVY_SNOW': 6,
  'RAIN_AND_SNOW': 6,
  // Pluie forte / verglaçante / périodiquement forte
  'HEAVY_RAIN': 5,
  'HEAVY_RAIN_SHOWERS': 5,
  'RAIN_PERIODICALLY_HEAVY': 5,
  'MODERATE_TO_HEAVY_RAIN': 5,
  'FREEZING_RAIN': 5,
  // Pluie / averses
  'RAIN': 4,
  'LIGHT_RAIN': 4,
  'LIGHT_RAIN_SHOWERS': 4,
  'RAIN_SHOWERS': 4,
  'SCATTERED_SHOWERS': 4,
  'CHANCE_OF_SHOWERS': 4,
  'LIGHT_TO_MODERATE_RAIN': 4,
  'WIND_AND_RAIN': 4,
  // Bruine
  'DRIZZLE': 3,
  'LIGHT_DRIZZLE': 3,
  // Brouillard / brume
  'FOG': 2,
  'MIST': 2,
  'HAZE': 2,
  // Vent fort
  'WINDY': 2,
  // Couvert
  'CLOUDY': 1,
  'MOSTLY_CLOUDY': 1,
  // Éclaircies
  'PARTLY_CLOUDY': 0,
  'MOSTLY_CLEAR': 0,
  // Dégagé
  'CLEAR': 0,
};

const Map<String, String> _labelFr = {
  'CLEAR': 'Ciel dégagé',
  'MOSTLY_CLEAR': 'Généralement dégagé',
  'PARTLY_CLOUDY': 'Partiellement nuageux',
  'MOSTLY_CLOUDY': 'Très nuageux',
  'CLOUDY': 'Couvert',
  'WINDY': 'Venteux',
  'WIND_AND_RAIN': 'Vent et pluie',
  'LIGHT_RAIN_SHOWERS': 'Faibles averses',
  'CHANCE_OF_SHOWERS': 'Risque d\'averses',
  'SCATTERED_SHOWERS': 'Averses éparses',
  'RAIN_SHOWERS': 'Averses',
  'HEAVY_RAIN_SHOWERS': 'Fortes averses',
  'LIGHT_TO_MODERATE_RAIN': 'Pluie faible à modérée',
  'MODERATE_TO_HEAVY_RAIN': 'Pluie modérée à forte',
  'RAIN': 'Pluie',
  'LIGHT_RAIN': 'Pluie faible',
  'HEAVY_RAIN': 'Pluie forte',
  'RAIN_PERIODICALLY_HEAVY': 'Pluie parfois forte',
  'FREEZING_RAIN': 'Pluie verglaçante',
  'DRIZZLE': 'Bruine',
  'LIGHT_DRIZZLE': 'Bruine légère',
  'LIGHT_SNOW_SHOWERS': 'Faibles chutes de neige',
  'CHANCE_OF_SNOW_SHOWERS': 'Risque de neige',
  'SCATTERED_SNOW_SHOWERS': 'Neige éparse',
  'SNOW_SHOWERS': 'Chutes de neige',
  'HEAVY_SNOW_SHOWERS': 'Fortes chutes de neige',
  'LIGHT_TO_MODERATE_SNOW': 'Neige faible à modérée',
  'MODERATE_TO_HEAVY_SNOW': 'Neige modérée à forte',
  'SNOW': 'Neige',
  'LIGHT_SNOW': 'Neige faible',
  'HEAVY_SNOW': 'Neige forte',
  'SNOWSTORM': 'Tempête de neige',
  'SNOW_PERIODICALLY_HEAVY': 'Neige parfois forte',
  'HEAVY_SNOW_STORM': 'Forte tempête de neige',
  'BLOWING_SNOW': 'Poudrerie',
  'RAIN_AND_SNOW': 'Pluie et neige',
  'HAIL': 'Grêle',
  'HAIL_SHOWERS': 'Averses de grêle',
  'THUNDERSTORM': 'Orage',
  'THUNDERSHOWER': 'Averse orageuse',
  'LIGHT_THUNDERSTORM_RAIN': 'Pluie orageuse faible',
  'SCATTERED_THUNDERSTORMS': 'Orages épars',
  'HEAVY_THUNDERSTORM': 'Orage violent',
  'FOG': 'Brouillard',
  'MIST': 'Brume',
  'HAZE': 'Brume sèche',
};

/// Icône Material représentant une condition. Aucune image réseau
/// (`iconBaseUri` ignoré en v1) pour rester cohérent avec l'offline-first.
IconData weatherConditionIcon(String? type) {
  final t = _norm(type);
  if (t.contains('THUNDER')) return Icons.thunderstorm;
  if (t.contains('HAIL')) return Icons.grain;
  if (t.contains('SNOW') || t == 'BLOWING_SNOW') return Icons.ac_unit;
  if (t.contains('RAIN') || t.contains('SHOWERS') || t.contains('DRIZZLE')) {
    return Icons.water_drop;
  }
  if (t == 'FOG' || t == 'MIST' || t == 'HAZE') return Icons.foggy;
  if (t == 'WINDY' || t == 'WIND_AND_RAIN') return Icons.air;
  if (t == 'CLOUDY' || t == 'MOSTLY_CLOUDY') return Icons.cloud;
  if (t == 'PARTLY_CLOUDY' || t == 'MOSTLY_CLEAR') return Icons.wb_cloudy;
  if (t == 'CLEAR') return Icons.wb_sunny;
  return Icons.cloud_outlined;
}

/// Libellé français court d'une condition. Type inconnu → libellé neutre.
String weatherConditionLabelFr(String? type) {
  final t = _norm(type);
  return _labelFr[t] ?? 'Conditions variables';
}

/// Sévérité « randonneur » (0 = anodin). Type inconnu → 0.
int weatherConditionSeverity(String? type) => _severity[_norm(type)] ?? 0;

/// Parmi [types] (ordonnés chronologiquement), renvoie celui de plus forte
/// sévérité pour l'icône de tendance du §3.2 — à égalité, le premier (le
/// plus proche dans le temps) l'emporte. `null` si la liste est vide.
String? mostNotableCondition(Iterable<String?> types) {
  String? best;
  var bestSeverity = -1;
  for (final t in types) {
    final s = weatherConditionSeverity(t);
    if (s > bestSeverity) {
      bestSeverity = s;
      best = t;
    }
  }
  return best;
}
