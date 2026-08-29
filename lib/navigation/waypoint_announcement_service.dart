import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

import '../map/map_view_model.dart';
import '../models/waypoint.dart';
import '../recording/recording_service.dart';
import '../utils/geo_utils.dart';
import '../utils/settings_service.dart';
import 'waypoint_announcement_engine.dart';

/// Branche le moteur pur [WaypointAnnouncementEngine] sur les flux de
/// données déjà existants (position live, waypoints affichés, prochain
/// waypoint du roadmap) et restitue les annonces via `flutter_tts` — 100%
/// local, aucun appel réseau, cf. spec-assistant-vocal-ia.md §2.
///
/// N'introduit aucune dépendance croisée entre RecordingService et
/// MapViewModel : ce service se contente d'observer les ValueNotifier déjà
/// exposés par les deux, sans modifier leur logique interne.
class WaypointAnnouncementService {
  WaypointAnnouncementService({
    required this.mapViewModel,
    required this.recordingService,
    required this.settingsService,
  });

  final MapViewModel mapViewModel;
  final RecordingService recordingService;
  final SettingsService settingsService;

  final FlutterTts _tts = FlutterTts();
  Future<void> _speechQueue = Future.value();

  final Map<String, AnnouncementTriggerState> _waypointManagerState = {};
  final Map<String, AnnouncementTriggerState> _roadmapState = {};

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await _tts.setLanguage('fr-FR');
    await _tts.setQueueMode(1); // QUEUE_ADD : n'interrompt pas une annonce en cours
    recordingService.currentPosition.addListener(_onPosition);
  }

  void dispose() {
    recordingService.currentPosition.removeListener(_onPosition);
    _tts.stop();
  }

  void _onPosition() {
    final position = recordingService.currentPosition.value;
    if (position == null) return;
    final accuracy = position.accuracy;
    // Vitesse issue de la même position GPS (pas de RecordingService.
    // currentSpeedMps ici : ce ValueNotifier est mis à jour dans le même
    // _onPosition que celui qui notifie currentPosition, sans garantie
    // d'ordre par rapport à ce listener — autant lire la même mesure).
    final speed = position.speed;

    if (settingsService.waypointAnnouncementsEnabled) {
      unawaited(_checkWaypointManager(position.latitude, position.longitude, accuracy, speed));
    }
    if (settingsService.roadmapAnnouncementsEnabled) {
      unawaited(_checkRoadmap(accuracy, speed));
    }
  }

  Future<void> _checkWaypointManager(double lat, double lon, double accuracy, double speed) async {
    final candidates = mapViewModel.waypoints.value;
    final activeUuids = candidates.map((w) => w.localUuid).toSet();
    // Un waypoint qui sort du jeu surveillé (viewport, filtres) perd son
    // état "déjà annoncé" : s'y approcher à nouveau plus tard réannonce.
    _waypointManagerState.removeWhere((uuid, _) => !activeUuids.contains(uuid));

    final settings = AnnouncementSettings(
      onApproachEnabled: settingsService.waypointAnnounceOnApproach,
      onSpotEnabled: settingsService.waypointAnnounceOnSpot,
      approachDistanceMeters: settingsService.waypointAnnounceDistanceMeters,
      announceTitle: settingsService.waypointAnnounceTitle,
      announceType: settingsService.waypointAnnounceType,
      announceDescription: settingsService.waypointAnnounceDescription,
    );

    for (final waypoint in candidates) {
      final state = _waypointManagerState[waypoint.localUuid] ?? const AnnouncementTriggerState();
      if (state.isFullyAnnounced) continue;

      final distance = GeoUtils.haversineMeters(lat, lon, waypoint.latitude, waypoint.longitude);
      final result = WaypointAnnouncementEngine.evaluate(
        waypoint: await _toAnnouncementWaypoint(waypoint, settings),
        distanceMeters: distance,
        accuracyMeters: accuracy,
        speedMps: speed,
        settings: settings,
        state: state,
      );
      if (result == null) continue;

      _waypointManagerState[waypoint.localUuid] = result.state;
      _speak(result.event.phrase);
    }
  }

  Future<void> _checkRoadmap(double accuracy, double speed) async {
    final waypoint = recordingService.nextWaypoint.value;
    if (waypoint == null) return;
    final distance = recordingService.distanceToNextWaypointMeters.value;

    final state = _roadmapState[waypoint.localUuid] ?? const AnnouncementTriggerState();
    if (state.isFullyAnnounced) return;

    final settings = AnnouncementSettings(
      onApproachEnabled: settingsService.roadmapAnnounceOnApproach,
      onSpotEnabled: settingsService.roadmapAnnounceOnSpot,
      approachDistanceMeters: settingsService.roadmapAnnounceDistanceMeters,
      announceTitle: settingsService.roadmapAnnounceTitle,
      announceType: settingsService.roadmapAnnounceType,
      announceDescription: settingsService.roadmapAnnounceDescription,
    );

    final result = WaypointAnnouncementEngine.evaluate(
      waypoint: await _toAnnouncementWaypoint(waypoint, settings),
      distanceMeters: distance,
      accuracyMeters: accuracy,
      speedMps: speed,
      settings: settings,
      state: state,
    );
    if (result == null) return;

    _roadmapState[waypoint.localUuid] = result.state;
    _speak(result.event.phrase);
  }

  /// `IsarService.searchWaypoints` (utilisé par `MapViewModel`) ne
  /// précharge pas le lien `category` (contrairement à
  /// `roadmap_screen.dart`/`waypoint_manager_screen.dart` qui l'affichent) :
  /// on ne le charge qu'ici, juste avant une annonce potentielle, et
  /// seulement si le contenu "type" est activé — jamais à chaque tick pour
  /// chaque candidat.
  Future<AnnouncementWaypoint> _toAnnouncementWaypoint(
    Waypoint waypoint,
    AnnouncementSettings settings,
  ) async {
    String? typeName;
    if (settings.announceType) {
      if (!waypoint.category.isLoaded) {
        await waypoint.category.load();
      }
      typeName = waypoint.category.value?.name;
    }
    return AnnouncementWaypoint(
      localUuid: waypoint.localUuid,
      name: waypoint.name,
      typeName: typeName,
      description: waypoint.description,
    );
  }

  void _speak(String phrase) {
    _speechQueue = _speechQueue.then((_) => _tts.speak(phrase));
  }
}
