import 'package:flutter_test/flutter_test.dart';
import 'package:meshiker/weather/weather_conditions.dart';

void main() {
  group('weatherConditionSeverity', () {
    test('orage > neige > pluie > bruine > brouillard > couvert > dégagé', () {
      expect(
        weatherConditionSeverity('THUNDERSTORM'),
        greaterThan(weatherConditionSeverity('SNOW')),
      );
      expect(
        weatherConditionSeverity('SNOW'),
        greaterThan(weatherConditionSeverity('RAIN')),
      );
      expect(
        weatherConditionSeverity('RAIN'),
        greaterThan(weatherConditionSeverity('DRIZZLE')),
      );
      expect(
        weatherConditionSeverity('DRIZZLE'),
        greaterThan(weatherConditionSeverity('FOG')),
      );
      expect(
        weatherConditionSeverity('CLOUDY'),
        greaterThan(weatherConditionSeverity('CLEAR')),
      );
    });

    test('type inconnu ou null -> 0', () {
      expect(weatherConditionSeverity(null), 0);
      expect(weatherConditionSeverity('TYPE_UNSPECIFIED'), 0);
      expect(weatherConditionSeverity('SOMETHING_NEW'), 0);
    });

    test('insensible à la casse et aux espaces', () {
      expect(weatherConditionSeverity('  rain  '),
          weatherConditionSeverity('RAIN'));
    });
  });

  group('mostNotableCondition', () {
    test('choisit la condition la plus notable de la fenêtre', () {
      expect(
        mostNotableCondition(['CLEAR', 'PARTLY_CLOUDY', 'RAIN', 'CLOUDY']),
        'RAIN',
      );
    });

    test('à égalité de sévérité, le premier (plus proche) gagne', () {
      // CLEAR et MOSTLY_CLEAR ont tous deux sévérité 0.
      expect(mostNotableCondition(['CLEAR', 'MOSTLY_CLEAR']), 'CLEAR');
    });

    test('liste vide -> null', () {
      expect(mostNotableCondition(const []), isNull);
    });

    test('n\'affiche pas la pluie si seul le ciel dégagé est prévu', () {
      expect(
        mostNotableCondition(['CLEAR', 'CLEAR', 'MOSTLY_CLEAR', 'CLEAR']),
        'CLEAR',
      );
    });
  });

  group('weatherConditionLabelFr', () {
    test('libellé connu', () {
      expect(weatherConditionLabelFr('RAIN'), 'Pluie');
      expect(weatherConditionLabelFr('THUNDERSTORM'), 'Orage');
    });

    test('type inconnu -> libellé neutre', () {
      expect(weatherConditionLabelFr('NOPE'), 'Conditions variables');
      expect(weatherConditionLabelFr(null), 'Conditions variables');
    });
  });
}
