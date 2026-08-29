import 'package:flutter_test/flutter_test.dart';
import 'package:meshiker/navigation/waypoint_announcement_engine.dart';

void main() {
  const waypoint = AnnouncementWaypoint(
    localUuid: 'wp-1',
    name: 'Le Chalet du Berger',
    typeName: "Point d'eau",
    description: 'Source fraîche toute l\'année, débit faible en été.',
  );

  const fullSettings = AnnouncementSettings(
    onApproachEnabled: true,
    onSpotEnabled: true,
    approachDistanceMeters: 300,
    announceTitle: true,
    announceType: true,
    announceDescription: false,
  );

  group('approach trigger', () {
    test('fires once when entering the approach radius', () {
      final result = WaypointAnnouncementEngine.evaluate(
        waypoint: waypoint,
        distanceMeters: 250,
        accuracyMeters: 5,
        speedMps: 0,
        settings: fullSettings,
        state: const AnnouncementTriggerState(),
      );

      expect(result, isNotNull);
      expect(result!.state.distanceAnnounced, isTrue);
      expect(result.state.onSpotAnnounced, isFalse);
      expect(result.event.phrase, contains('Dans 300 mètres'));
      expect(result.event.phrase, contains('Le Chalet du Berger'));
      expect(result.event.phrase, contains("Point d'eau"));
    });

    test('does not fire again once already announced', () {
      final result = WaypointAnnouncementEngine.evaluate(
        waypoint: waypoint,
        distanceMeters: 250,
        accuracyMeters: 5,
        speedMps: 0,
        settings: fullSettings,
        state: const AnnouncementTriggerState(distanceAnnounced: true),
      );

      expect(result, isNull);
    });

    test('does not fire outside the configured radius', () {
      final result = WaypointAnnouncementEngine.evaluate(
        waypoint: waypoint,
        distanceMeters: 500,
        accuracyMeters: 5,
        speedMps: 0,
        settings: fullSettings,
        state: const AnnouncementTriggerState(),
      );

      expect(result, isNull);
    });
  });

  group('approach lookahead compensation', () {
    // Terrain test (2026-08) : sans compensation, l'annonce d'approche
    // arrivait ~10m plus tard que prévu à l'allure de marche (~1,1 m/s).
    test('fires earlier than the raw radius when walking at speed', () {
      // 310m réels, à 1.1 m/s : anticipation de 1.1 * 3.0 = 3.3m -> distance
      // effective 306.7m, encore hors du seuil de 300m -> ne déclenche pas.
      final tooFar = WaypointAnnouncementEngine.evaluate(
        waypoint: waypoint,
        distanceMeters: 310,
        accuracyMeters: 5,
        speedMps: 1.1,
        settings: fullSettings,
        state: const AnnouncementTriggerState(),
      );
      expect(tooFar, isNull);

      // 303m réels : distance effective 303 - 3.3 = 299.7m <= 300m ->
      // déclenche alors que la distance brute est encore hors du seuil.
      final result = WaypointAnnouncementEngine.evaluate(
        waypoint: waypoint,
        distanceMeters: 303,
        accuracyMeters: 5,
        speedMps: 1.1,
        settings: fullSettings,
        state: const AnnouncementTriggerState(),
      );
      expect(result, isNotNull);
    });

    test('does not anticipate when stationary (speed 0 behaves like before)', () {
      final result = WaypointAnnouncementEngine.evaluate(
        waypoint: waypoint,
        distanceMeters: 300,
        accuracyMeters: 5,
        speedMps: 0,
        settings: fullSettings,
        state: const AnnouncementTriggerState(),
      );
      expect(result, isNotNull);

      final stillOutside = WaypointAnnouncementEngine.evaluate(
        waypoint: waypoint,
        distanceMeters: 301,
        accuracyMeters: 5,
        speedMps: 0,
        settings: fullSettings,
        state: const AnnouncementTriggerState(),
      );
      expect(stillOutside, isNull);
    });

    test('does not affect the on-the-spot trigger', () {
      // Même à vitesse élevée, l'annonce "sur place" reste basée sur la
      // distance réelle : à 10m de distance réelle mais hors du rayon
      // effectif, elle doit tout de même se déclencher normalement.
      final result = WaypointAnnouncementEngine.evaluate(
        waypoint: waypoint,
        distanceMeters: 10,
        accuracyMeters: 5,
        speedMps: 3.0,
        settings: fullSettings,
        state: const AnnouncementTriggerState(distanceAnnounced: true),
      );

      expect(result, isNotNull);
      expect(result!.event.phrase, contains('Vous êtes arrivé'));
    });
  });

  group('on-the-spot trigger', () {
    test('fires once when within the on-the-spot radius', () {
      final result = WaypointAnnouncementEngine.evaluate(
        waypoint: waypoint,
        distanceMeters: 10,
        accuracyMeters: 5,
        speedMps: 0,
        settings: fullSettings,
        state: const AnnouncementTriggerState(distanceAnnounced: true),
      );

      expect(result, isNotNull);
      expect(result!.state.onSpotAnnounced, isTrue);
      expect(result.event.phrase, contains('Vous êtes arrivé'));
    });

    test('is independent from the approach trigger (can fire without it)', () {
      // L'utilisateur peut arriver directement dans le rayon "sur place"
      // sans jamais avoir été détecté dans le rayon d'approche (ex. gros
      // saut GPS) : l'annonce sur place doit tout de même se déclencher.
      final result = WaypointAnnouncementEngine.evaluate(
        waypoint: waypoint,
        distanceMeters: 10,
        accuracyMeters: 5,
        speedMps: 0,
        settings: fullSettings,
        state: const AnnouncementTriggerState(),
      );

      expect(result, isNotNull);
      expect(result!.event.phrase, contains('Vous êtes arrivé'));
    });

    test('widens the on-the-spot radius to match poor GPS accuracy', () {
      // Précision GPS de 40m > rayon de base de 20m : le rayon effectif
      // s'élargit à 40m (§2.5).
      final result = WaypointAnnouncementEngine.evaluate(
        waypoint: waypoint,
        distanceMeters: 35,
        accuracyMeters: 40,
        speedMps: 0,
        settings: const AnnouncementSettings(
          onApproachEnabled: false,
          onSpotEnabled: true,
          approachDistanceMeters: 300,
          announceTitle: true,
          announceType: false,
          announceDescription: false,
        ),
        state: const AnnouncementTriggerState(),
      );

      expect(result, isNotNull);
    });
  });

  group('GPS-accuracy merge (UI spec point 3)', () {
    test('collapses approach and on-the-spot into a single announcement when rings overlap', () {
      // Précision de 290m avec un rayon d'approche de 300m et un rayon sur
      // place d'au moins 20m : les deux anneaux sont indiscernables.
      final result = WaypointAnnouncementEngine.evaluate(
        waypoint: waypoint,
        distanceMeters: 200,
        accuracyMeters: 290,
        speedMps: 0,
        settings: fullSettings,
        state: const AnnouncementTriggerState(),
      );

      expect(result, isNotNull);
      expect(result!.state.distanceAnnounced, isTrue);
      expect(result.state.onSpotAnnounced, isTrue);
      expect(result.event.phrase, contains('Signal GPS approximatif'));
      expect(result.event.phrase, contains('Vous êtes arrivé'));
    });

    test('never fires twice after a merged announcement', () {
      final result = WaypointAnnouncementEngine.evaluate(
        waypoint: waypoint,
        distanceMeters: 200,
        accuracyMeters: 290,
        speedMps: 0,
        settings: fullSettings,
        state: const AnnouncementTriggerState(distanceAnnounced: true, onSpotAnnounced: true),
      );

      expect(result, isNull);
    });

    test('does not merge when only one trigger is enabled', () {
      final result = WaypointAnnouncementEngine.evaluate(
        waypoint: waypoint,
        distanceMeters: 200,
        accuracyMeters: 290,
        speedMps: 0,
        settings: const AnnouncementSettings(
          onApproachEnabled: true,
          onSpotEnabled: false,
          approachDistanceMeters: 300,
          announceTitle: true,
          announceType: false,
          announceDescription: false,
        ),
        state: const AnnouncementTriggerState(),
      );

      expect(result, isNotNull);
      expect(result!.event.phrase, isNot(contains('Signal GPS approximatif')));
    });
  });

  group('content composition', () {
    test('includes only enabled content blocks, in title -> type -> description order', () {
      final result = WaypointAnnouncementEngine.evaluate(
        waypoint: waypoint,
        distanceMeters: 10,
        accuracyMeters: 5,
        speedMps: 0,
        settings: const AnnouncementSettings(
          onApproachEnabled: false,
          onSpotEnabled: true,
          approachDistanceMeters: 300,
          announceTitle: true,
          announceType: true,
          announceDescription: true,
        ),
        state: const AnnouncementTriggerState(),
      );

      final phrase = result!.event.phrase;
      final titleIndex = phrase.indexOf('Le Chalet du Berger');
      final typeIndex = phrase.indexOf("Point d'eau");
      final descIndex = phrase.indexOf('Source fraîche');
      expect(titleIndex, greaterThanOrEqualTo(0));
      expect(typeIndex, greaterThan(titleIndex));
      expect(descIndex, greaterThan(typeIndex));
    });

    test('omits disabled content blocks', () {
      final result = WaypointAnnouncementEngine.evaluate(
        waypoint: waypoint,
        distanceMeters: 10,
        accuracyMeters: 5,
        speedMps: 0,
        settings: const AnnouncementSettings(
          onApproachEnabled: false,
          onSpotEnabled: true,
          approachDistanceMeters: 300,
          announceTitle: true,
          announceType: false,
          announceDescription: false,
        ),
        state: const AnnouncementTriggerState(),
      );

      expect(result!.event.phrase, isNot(contains("Point d'eau")));
    });
  });

  group('description truncation', () {
    test('leaves short descriptions untouched', () {
      const short = 'Un point d\'eau agréable.';
      expect(WaypointAnnouncementEngine.truncateDescription(short), short);
    });

    test('cuts long descriptions at a word boundary under the limit', () {
      final long = List.generate(100, (i) => 'mot$i').join(' '); // largement > 500 caractères
      final truncated = WaypointAnnouncementEngine.truncateDescription(long);

      expect(truncated.length, lessThanOrEqualTo(WaypointAnnouncementEngine.descriptionTruncateLimit + 1));
      expect(truncated, isNot(endsWith('mot')));
      // Ne coupe jamais en plein milieu d'un mot : le texte tronqué (hors
      // ellipse finale) doit être un préfixe exact du texte original.
      final withoutEllipsis = truncated.replaceAll('…', '');
      expect(long.startsWith(withoutEllipsis), isTrue);
    });
  });
}
