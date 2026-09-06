import 'package:flutter_test/flutter_test.dart';
import 'package:meshiker/weather/weather_models.dart';

void main() {
  group('HourForecast.fromJson', () {
    test('extrait tous les champs du §3.4', () {
      final h = HourForecast.fromJson({
        'interval': {'startTime': '2026-09-06T14:00:00Z'},
        'weatherCondition': {
          'type': 'RAIN',
          'iconBaseUri': 'https://example/icons/rain',
        },
        'temperature': {'degrees': 17.4, 'unit': 'CELSIUS'},
        'feelsLikeTemperature': {'degrees': 16.1, 'unit': 'CELSIUS'},
        'precipitation': {
          'probability': {'percent': 65, 'type': 'RAIN'},
          'qpf': {'quantity': 2.3, 'unit': 'MILLIMETERS'},
        },
        'wind': {
          'speed': {'value': 14.0, 'unit': 'KILOMETERS_PER_HOUR'},
        },
        'airPressure': {'meanSeaLevelMillibars': 1012.6},
      });

      expect(h.time, DateTime.parse('2026-09-06T14:00:00Z').toLocal());
      expect(h.conditionType, 'RAIN');
      expect(h.rainProbabilityPercent, 65);
      expect(h.qpfQuantity, 2.3);
      expect(h.windSpeed, 14.0);
      expect(h.temperature, 17.4);
      expect(h.feelsLike, 16.1);
      expect(h.temperatureUnit, 'CELSIUS');
      expect(h.pressureMb, 1012.6);
      expect(h.distanceAlongTraceMeters, isNull);
    });

    test('champs manquants -> null, aucune exception', () {
      final h = HourForecast.fromJson({});
      expect(h.time, isNull);
      expect(h.conditionType, isNull);
      expect(h.rainProbabilityPercent, isNull);
      expect(h.pressureMb, isNull);
    });

    test('copyWith attache le kilométrage sans perdre le reste', () {
      final h = HourForecast.fromJson({
        'weatherCondition': {'type': 'CLEAR'},
        'temperature': {'degrees': 20},
      }).copyWith(distanceAlongTraceMeters: 4200);
      expect(h.distanceAlongTraceMeters, 4200);
      expect(h.conditionType, 'CLEAR');
      expect(h.temperature, 20);
    });
  });

  group('DayForecast.fromJson', () {
    test('demi-journées jour/nuit + risque de pluie = max des deux', () {
      final d = DayForecast.fromJson({
        'displayDate': {'year': 2026, 'month': 9, 'day': 7},
        'maxTemperature': {'degrees': 22, 'unit': 'CELSIUS'},
        'minTemperature': {'degrees': 11, 'unit': 'CELSIUS'},
        'daytimeForecast': {
          'weatherCondition': {'type': 'PARTLY_CLOUDY'},
          'precipitation': {
            'probability': {'percent': 20},
          },
        },
        'nighttimeForecast': {
          'weatherCondition': {'type': 'RAIN'},
          'precipitation': {
            'probability': {'percent': 70},
          },
        },
      });

      expect(d.date, DateTime(2026, 9, 7));
      expect(d.tempMax, 22);
      expect(d.tempMin, 11);
      expect(d.conditionType, 'PARTLY_CLOUDY'); // résumé = diurne
      expect(d.rainProbabilityPercent, 70); // max(20, 70)
      expect(d.daytime.conditionType, 'PARTLY_CLOUDY');
      expect(d.nighttime.conditionType, 'RAIN');
    });

    test('blocs demi-journée absents -> HalfDayForecast vide', () {
      final d = DayForecast.fromJson({
        'displayDate': {'year': 2026, 'month': 9, 'day': 8},
      });
      expect(d.daytime.conditionType, isNull);
      expect(d.nighttime.conditionType, isNull);
      expect(d.rainProbabilityPercent, isNull);
    });
  });
}
