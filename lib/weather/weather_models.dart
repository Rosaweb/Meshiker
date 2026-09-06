/// Modèles de données météo issus de la Google Maps Platform Weather API
/// (endpoints `forecast/hours:lookup` et `forecast/days:lookup`).
///
/// Parsing volontairement défensif : chaque champ est nullable et lu via
/// helpers tolérants (`_asDouble` / `_asInt`), l'API pouvant omettre des
/// blocs entiers selon la couverture. Aucune conversion d'unité côté client
/// (§5) : `unitsSystem` est passé à la requête, la réponse arrive déjà dans
/// le bon système — sauf la pression, toujours en hPa/mb.
library;

double? _asDouble(dynamic v) => v is num ? v.toDouble() : null;
int? _asInt(dynamic v) => v is num ? v.round() : null;

DateTime? _parseUtcToLocal(dynamic v) {
  if (v is! String || v.isEmpty) return null;
  return DateTime.tryParse(v)?.toLocal();
}

/// Prévision pour une heure donnée (`forecastHours[i]`).
class HourForecast {
  /// Début du créneau, converti en heure locale de l'appareil.
  final DateTime? time;

  /// `weatherCondition.type` brut (voir `weather_conditions.dart`).
  final String? conditionType;

  /// `precipitation.probability.percent` (0–100).
  final int? rainProbabilityPercent;

  /// `precipitation.qpf.quantity` — millimètres annoncés (ou équivalent
  /// impérial si `unitsSystem=IMPERIAL`).
  final double? qpfQuantity;
  final String? qpfUnit;

  /// `wind.speed.value` + `wind.speed.unit`.
  final double? windSpeed;
  final String? windUnit;

  /// Température et ressenti (`temperature.degrees`,
  /// `feelsLikeTemperature.degrees`) + unité (`C`/`F`).
  final double? temperature;
  final double? feelsLike;
  final String? temperatureUnit;

  /// `airPressure.meanSeaLevelMillibars` — toujours en hPa/mb (§5).
  final double? pressureMb;

  /// Distance cumulée le long de la trace, en mètres (premium, §3.4).
  /// `null` pour le point unique « position actuelle ».
  final double? distanceAlongTraceMeters;

  const HourForecast({
    this.time,
    this.conditionType,
    this.rainProbabilityPercent,
    this.qpfQuantity,
    this.qpfUnit,
    this.windSpeed,
    this.windUnit,
    this.temperature,
    this.feelsLike,
    this.temperatureUnit,
    this.pressureMb,
    this.distanceAlongTraceMeters,
  });

  factory HourForecast.fromJson(Map<String, dynamic> json) {
    final interval = json['interval'] as Map<String, dynamic>?;
    final condition = json['weatherCondition'] as Map<String, dynamic>?;
    final precip = json['precipitation'] as Map<String, dynamic>?;
    final probability = precip?['probability'] as Map<String, dynamic>?;
    final qpf = precip?['qpf'] as Map<String, dynamic>?;
    final wind = json['wind'] as Map<String, dynamic>?;
    final windSpeed = wind?['speed'] as Map<String, dynamic>?;
    final temp = json['temperature'] as Map<String, dynamic>?;
    final feels = json['feelsLikeTemperature'] as Map<String, dynamic>?;
    final pressure = json['airPressure'] as Map<String, dynamic>?;

    return HourForecast(
      time: _parseUtcToLocal(interval?['startTime'] ?? json['startTime']),
      conditionType: condition?['type'] as String?,
      rainProbabilityPercent: _asInt(probability?['percent']),
      qpfQuantity: _asDouble(qpf?['quantity']),
      qpfUnit: qpf?['unit'] as String?,
      windSpeed: _asDouble(windSpeed?['value']),
      windUnit: windSpeed?['unit'] as String?,
      temperature: _asDouble(temp?['degrees']),
      feelsLike: _asDouble(feels?['degrees']),
      temperatureUnit: (temp?['unit'] ?? feels?['unit']) as String?,
      pressureMb: _asDouble(pressure?['meanSeaLevelMillibars']),
    );
  }

  HourForecast copyWith({double? distanceAlongTraceMeters}) => HourForecast(
        time: time,
        conditionType: conditionType,
        rainProbabilityPercent: rainProbabilityPercent,
        qpfQuantity: qpfQuantity,
        qpfUnit: qpfUnit,
        windSpeed: windSpeed,
        windUnit: windUnit,
        temperature: temperature,
        feelsLike: feelsLike,
        temperatureUnit: temperatureUnit,
        pressureMb: pressureMb,
        distanceAlongTraceMeters:
            distanceAlongTraceMeters ?? this.distanceAlongTraceMeters,
      );
}

/// Météo d'une demi-journée (`daytimeForecast` 7h–19h ou `nighttimeForecast`
/// 19h–7h) telle que fournie *dans la même réponse* `forecast/days` — aucun
/// appel supplémentaire pour le détail jour/nuit (§3.5).
class HalfDayForecast {
  final String? conditionType;
  final int? rainProbabilityPercent;
  final double? qpfQuantity;
  final String? qpfUnit;
  final double? windSpeed;
  final String? windUnit;

  const HalfDayForecast({
    this.conditionType,
    this.rainProbabilityPercent,
    this.qpfQuantity,
    this.qpfUnit,
    this.windSpeed,
    this.windUnit,
  });

  factory HalfDayForecast.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const HalfDayForecast();
    final condition = json['weatherCondition'] as Map<String, dynamic>?;
    final precip = json['precipitation'] as Map<String, dynamic>?;
    final probability = precip?['probability'] as Map<String, dynamic>?;
    final qpf = precip?['qpf'] as Map<String, dynamic>?;
    final wind = json['wind'] as Map<String, dynamic>?;
    final windSpeed = wind?['speed'] as Map<String, dynamic>?;

    return HalfDayForecast(
      conditionType: condition?['type'] as String?,
      rainProbabilityPercent: _asInt(probability?['percent']),
      qpfQuantity: _asDouble(qpf?['quantity']),
      qpfUnit: qpf?['unit'] as String?,
      windSpeed: _asDouble(windSpeed?['value']),
      windUnit: windSpeed?['unit'] as String?,
    );
  }
}

/// Prévision pour un jour calendaire (`forecastDays[i]`).
class DayForecast {
  final DateTime? date;
  final double? tempMax;
  final double? tempMin;
  final String? temperatureUnit;

  /// Condition « résumé » du jour : on retient celle de la demi-journée
  /// diurne (plus représentative pour un randonneur).
  final String? conditionType;

  /// Risque de pluie affiché sur la ligne : max des deux demi-journées.
  final int? rainProbabilityPercent;

  final HalfDayForecast daytime;
  final HalfDayForecast nighttime;

  const DayForecast({
    this.date,
    this.tempMax,
    this.tempMin,
    this.temperatureUnit,
    this.conditionType,
    this.rainProbabilityPercent,
    this.daytime = const HalfDayForecast(),
    this.nighttime = const HalfDayForecast(),
  });

  factory DayForecast.fromJson(Map<String, dynamic> json) {
    final interval = json['interval'] as Map<String, dynamic>?;
    final displayDate = json['displayDate'] as Map<String, dynamic>?;
    final maxTemp = json['maxTemperature'] as Map<String, dynamic>?;
    final minTemp = json['minTemperature'] as Map<String, dynamic>?;
    final daytime =
        HalfDayForecast.fromJson(json['daytimeForecast'] as Map<String, dynamic>?);
    final nighttime = HalfDayForecast.fromJson(
        json['nighttimeForecast'] as Map<String, dynamic>?);

    DateTime? date;
    if (displayDate != null &&
        displayDate['year'] is num &&
        displayDate['month'] is num &&
        displayDate['day'] is num) {
      date = DateTime((displayDate['year'] as num).toInt(),
          (displayDate['month'] as num).toInt(),
          (displayDate['day'] as num).toInt());
    } else {
      date = _parseUtcToLocal(interval?['startTime']);
    }

    final dayP = daytime.rainProbabilityPercent;
    final nightP = nighttime.rainProbabilityPercent;
    int? rainP;
    if (dayP != null || nightP != null) {
      rainP = [dayP ?? 0, nightP ?? 0].reduce((a, b) => a > b ? a : b);
    }

    return DayForecast(
      date: date,
      tempMax: _asDouble(maxTemp?['degrees']),
      tempMin: _asDouble(minTemp?['degrees']),
      temperatureUnit: (maxTemp?['unit'] ?? minTemp?['unit']) as String?,
      conditionType: daytime.conditionType,
      rainProbabilityPercent: rainP,
      daytime: daytime,
      nighttime: nighttime,
    );
  }
}
