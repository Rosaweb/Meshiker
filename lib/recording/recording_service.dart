import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:isar_community/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../database/isar_service.dart';
import '../gpx/gpx_models.dart';
import '../gpx/segmentation_engine.dart';
import '../gpx/segmentation_persistence.dart';
import '../models/enums.dart';
import '../models/gps_point.dart';
import '../models/recording_draft.dart';
import '../models/trace.dart';
import '../models/waypoint.dart';
import '../search/local_search_engine.dart';
import '../utils/geo_utils.dart';
import 'recording_config.dart';

const _uuid = Uuid();

/// Enregistre une randonnee en direct, en tache de fond, puis la
/// transforme en Trace + Segment definitifs via SegmentationEngine (le
/// meme moteur que pour un import GPX, etape 2 -- voir plus bas).
///
/// ## Foreground service : le choix de geolocator seul
///
/// Plutot que d'ajouter un package dedie (type flutter_foreground_task)
/// en plus de geolocator, ce service s'appuie sur la capacite native de
/// geolocator a faire tourner ses mises a jour de position dans un VRAI
/// foreground service Android -- AndroidSettings.foregroundNotificationConfig
/// affiche la notification persistante requise et empeche l'OS de couper
/// les mises a jour quand l'app est reduite ou l'ecran verrouille. Cela
/// evite une dependance supplementaire qui ferait, in fine, le meme
/// travail que geolocator fait deja nativement pour ce cas precis.
///
/// Sur iOS, la situation est fondamentalement differente et il faut le
/// dire clairement : il n'existe pas de "foreground service" facon
/// Android. La continuite en arriere-plan vient de CoreLocation lui-meme
/// : autorisation "Toujours" (NSLocationAlwaysAndWhenInUseUsageDescription
/// dans Info.plist) + UIBackgroundModes: [location] + allowBackgroundLocationUpdates: true
/// cote AppleSettings. Un package generique de "tache de fond" ne
/// changerait rien a cette contrainte systeme -- ses propres mainteneurs
/// documentent d'ailleurs des limitations severes sur iOS (tache detruite
/// si l'app est fermee manuellement, pas de redemarrage au boot, fenetre
/// de quelques secondes hors CoreLocation). Le plus robuste sur iOS reste
/// donc de laisser CoreLocation piloter la continuite, pas d'empiler un
/// second mecanisme par-dessus.
///
/// ## Robustesse face a un arret brutal du processus
///
/// Un foreground service reduit fortement le risque d'etre tue par l'OS,
/// mais ne l'elimine pas totalement (gestionnaires de batterie agressifs
/// de certains constructeurs, redemarrage inopine...). Les points sont
/// donc persistes au fil de l'eau par petits lots (RecordingPointBatch,
/// voir models/recording_draft.dart) plutot que gardes uniquement en
/// memoire jusqu'a stop() : en cas de coupure, rien n'est perdu au-dela
/// du dernier lot non flushe (quelques dizaines de points au plus).
///
/// ## Contrainte batterie (section 4 du brief)
///
/// Aucun appel reseau ici, uniquement des ecritures Isar locales. Le
/// decoupage en segments (calculs geometriques repetes) n'a lieu qu'UNE
/// SEULE FOIS, a l'arret (stop()) -- jamais a chaque position recue.
class RecordingService {
  RecordingService({
    required this.isarService,
    this.config = const RecordingConfig(),
  });

  final IsarService isarService;
  final RecordingConfig config;

  StreamSubscription<geo.Position>? _positionSub;
  String? _sessionUuid;
  ActivityType _activityType = ActivityType.hiking;
  final List<PointGPS> _pendingBatch = [];
  int _batchIndex = 0;
  bool _nextPointStartsNewSegment = false;

  /// Etat courant, observable par l'UI (bouton demarrer/pause/arreter).
  final ValueNotifier<RecordingStatus> status =
      ValueNotifier(RecordingStatus.idle);

  /// true = aimant active (segments routes par defaut), false = mode
  /// hors-piste force. C'est CE notifier que le bouton bascule de l'UI de
  /// planification/enregistrement (section 3 du brief) doit refleter.
  final ValueNotifier<bool> magnetEnabled = ValueNotifier(true);

  /// Nombre de points captures depuis le debut de la session -- utile
  /// pour un petit indicateur "1 248 points enregistres" a l'ecran.
  final ValueNotifier<int> pointCount = ValueNotifier(0);

  /// Données temps réel pour le volet contextuel
  final ValueNotifier<double> currentSpeedMps = ValueNotifier(0.0);
  final ValueNotifier<double> averageSpeedDailyMps = ValueNotifier(0.0);
  final ValueNotifier<double> averageSpeedGlobalMps = ValueNotifier(0.0);
  final ValueNotifier<double> dailyDistanceMeters = ValueNotifier(0.0);
  final ValueNotifier<double> gpsAccuracyMeters = ValueNotifier(0.0);
  final ValueNotifier<geo.Position?> currentPosition = ValueNotifier(null);

  /// Données de progression sur la piste active
  final ValueNotifier<double> trackDistanceDoneMeters = ValueNotifier(0.0);
  final ValueNotifier<double> trackDistanceRemainingMeters = ValueNotifier(0.0);

  /// Navigation vers waypoint
  final ValueNotifier<Waypoint?> nextWaypoint = ValueNotifier(null);
  final ValueNotifier<double> distanceToNextWaypointMeters = ValueNotifier(0.0);
  final ValueNotifier<Waypoint?> destinationWaypoint = ValueNotifier(null);
  final ValueNotifier<double> distanceToDestinationMeters = ValueNotifier(0.0);

  bool _isDailyDistanceInitialized = false;
  geo.Position? _lastSavedPosition;
  Trace? _activeTrace;
  List<({double lat, double lon})> _activePolyline = [];
  List<Waypoint> _traceWaypoints = [];

  // Variables pour le calcul des moyennes
  int _dailyPointsCount = 0;
  double _dailySpeedSum = 0.0;
  int _globalPointsCount = 0;
  double _globalSpeedSum = 0.0;

  bool get isActive => status.value == RecordingStatus.recording;

  // -----------------------------------------------------------------
  // Permissions
  // -----------------------------------------------------------------

  /// Demande les permissions necessaires. Ne demande PAS d'emblee la
  /// permission "toujours" (mauvaise pratique UX et taux de refus plus
  /// eleve) : commence par "pendant l'utilisation", a l'app d'inviter
  /// ensuite l'utilisateur a passer sur "toujours" juste avant de lancer
  /// un enregistrement, avec une explication contextuelle.
  Future<bool> ensurePermissions() async {
    if (!await geo.Geolocator.isLocationServiceEnabled()) return false;

    var permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
    }
    if (permission == geo.LocationPermission.denied ||
        permission == geo.LocationPermission.deniedForever) {
      return false;
    }

    // Permission de notification (Android 13+, requise pour afficher la
    // notification persistante du foreground service). Sans lien avec la
    // localisation : geolocator ne la gere pas, d'ou permission_handler
    // pour ce seul cas precis.
    if (Platform.isAndroid) {
      final notifStatus = await ph.Permission.notification.status;
      if (!notifStatus.isGranted) {
        await ph.Permission.notification.request();
      }
    }
    return true;
  }

  /// A appeler separement, juste avant start(), avec une explication a
  /// l'ecran ("necessaire pour continuer a enregistrer votre trace quand
  /// l'app est en arriere-plan"). Sur iOS, l'autorisation "Toujours" ne
  /// peut etre obtenue qu'apres un premier octroi de "pendant l'utilisation".
  Future<bool> ensureBackgroundPermission() async {
    final permission = await geo.Geolocator.requestPermission();
    return permission == geo.LocationPermission.always;
  }

  void _updateSpeedAverages(double currentSpeed) {
    // On ne compte que les vitesses > 0.5 m/s pour ne pas fausser la moyenne à l'arrêt
    if (currentSpeed < 0.5) return;

    // Moyenne du jour
    _dailyPointsCount++;
    _dailySpeedSum += currentSpeed;
    averageSpeedDailyMps.value = _dailySpeedSum / _dailyPointsCount;

    // Moyenne globale
    _globalPointsCount++;
    _globalSpeedSum += currentSpeed;
    averageSpeedGlobalMps.value = _globalSpeedSum / _globalPointsCount;
    
    _persistSpeedAverages();
  }

  Future<void> _initDailyDistance() async {
    _isDailyDistanceInitialized = true;
    final prefs = await SharedPreferences.getInstance();
    
    // Moyennes de vitesse
    _globalPointsCount = prefs.getInt('global_speed_count') ?? 0;
    _globalSpeedSum = prefs.getDouble('global_speed_sum') ?? 0.0;
    if (_globalPointsCount > 0) {
      averageSpeedGlobalMps.value = _globalSpeedSum / _globalPointsCount;
    }

    final speedDateStr = prefs.getString('daily_speed_date');
    if (speedDateStr != null) {
      final speedDate = DateTime.parse(speedDateStr);
      final now = DateTime.now();
      if (speedDate.year == now.year && speedDate.month == now.month && speedDate.day == now.day) {
        _dailyPointsCount = prefs.getInt('daily_speed_count') ?? 0;
        _dailySpeedSum = prefs.getDouble('daily_speed_sum') ?? 0.0;
        if (_dailyPointsCount > 0) {
          averageSpeedDailyMps.value = _dailySpeedSum / _dailyPointsCount;
        }
      }
    }

    final lastDateStr = prefs.getString('daily_distance_date');
    if (lastDateStr != null) {
      final lastDate = DateTime.parse(lastDateStr);
      final now = DateTime.now();
      if (lastDate.year == now.year && lastDate.month == now.month && lastDate.day == now.day) {
        dailyDistanceMeters.value = prefs.getDouble('daily_distance_meters') ?? 0.0;
        return;
      }
    }

    final initialDist = await isarService.getDailyDistanceMeters();
    dailyDistanceMeters.value = initialDist;
  }

  Future<void> _persistSpeedAverages() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('global_speed_count', _globalPointsCount);
    await prefs.setDouble('global_speed_sum', _globalSpeedSum);
    
    await prefs.setInt('daily_speed_count', _dailyPointsCount);
    await prefs.setDouble('daily_speed_sum', _dailySpeedSum);
    await prefs.setString('daily_speed_date', DateTime.now().toIso8601String());
  }

  // -----------------------------------------------------------------
  // Cycle de vie de l'enregistrement
  // -----------------------------------------------------------------

  Future<void> start({
    required String ownerUuid,
    ActivityType activityType = ActivityType.hiking,
  }) async {
    if (status.value != RecordingStatus.idle) return;

    _sessionUuid = _uuid.v4();
    _activityType = activityType;
    _batchIndex = 0;
    _pendingBatch.clear();
    _nextPointStartsNewSegment = false;
    pointCount.value = 0;
    magnetEnabled.value = true;

    await isarService.isar.writeTxn(
      () => isarService.isar.recordingDrafts.put(
        RecordingDraft()
          ..sessionUuid = _sessionUuid!
          ..ownerUuid = ownerUuid
          ..activityType = activityType
          ..startedAt = DateTime.now()
          ..updatedAt = DateTime.now(),
      ),
    );

    _positionSub = geo.Geolocator
        .getPositionStream(locationSettings: _buildLocationSettings())
        .listen(_onPosition);
    status.value = RecordingStatus.recording;
  }

  geo.LocationSettings _buildLocationSettings() {
    if (Platform.isAndroid) {
      return geo.AndroidSettings(
        accuracy: config.accuracy,
        distanceFilter: config.distanceFilterMeters,
        // C'est ce parametre qui transforme les mises a jour de position
        // en un veritable foreground service Android avec notification
        // persistante (voir la doc de classe ci-dessus).
        foregroundNotificationConfig: geo.ForegroundNotificationConfig(
          notificationTitle: config.notificationTitle,
          notificationText: config.notificationText,
          enableWakeLock: true,
        ),
      );
    }
    if (Platform.isIOS || Platform.isMacOS) {
      return geo.AppleSettings(
        accuracy: config.accuracy,
        activityType: geo.ActivityType.fitness,
        distanceFilter: config.distanceFilterMeters,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      );
    }
    return geo.LocationSettings(
      accuracy: config.accuracy,
      distanceFilter: config.distanceFilterMeters,
    );
  }

  void _onPosition(geo.Position position) {
    // 1. Mise à jour systématique de la position et de la précision
    final lastPos = currentPosition.value;
    currentPosition.value = position;
    currentSpeedMps.value = position.speed;
    gpsAccuracyMeters.value = position.accuracy;
    
    // 2. Mise à jour des moyennes de vitesse
    _updateSpeedAverages(position.speed);

    // 3. Initialisation opportuniste de la distance du jour si ce n'est pas déjà fait
    if (!_isDailyDistanceInitialized) {
      _initDailyDistance();
    }

    // 3. Accumulation de la distance du jour (Toutes les positions connues aujourd'hui)
    if (lastPos != null) {
      final now = DateTime.now();
      if (lastPos.timestamp.year == now.year &&
          lastPos.timestamp.month == now.month &&
          lastPos.timestamp.day == now.day) {
        final dist = geo.Geolocator.distanceBetween(
          lastPos.latitude, 
          lastPos.longitude, 
          position.latitude, 
          position.longitude
        );
        dailyDistanceMeters.value += dist;
        _persistDailyDistance(dailyDistanceMeters.value);
      } else {
        // Nouveau jour détecté lors de la réception du point
        dailyDistanceMeters.value = 0;
        _persistDailyDistance(0);
      }
    }

    // 4. Mise à jour de la progression sur la piste active
    _updateNavigationStats(position);

    // 5. Si un enregistrement est actif, on traite le point pour la trace Isar
    if (status.value == RecordingStatus.recording) {
      _pendingBatch.add(PointGPS.create(
        latitude: position.latitude,
        longitude: position.longitude,
        altitude: position.altitude,
        timestamp: position.timestamp,
        accuracyMeters: position.accuracy,
        speedMps: position.speed,
        headingDegrees: position.heading,
      ));
      pointCount.value++;

      if (_pendingBatch.length >= config.pointsPerBatch) {
        unawaited(_flushBatch());
      }
    }
  }

  Future<void> _updateNavigationStats(geo.Position position) async {
    final prefs = await SharedPreferences.getInstance();
    final activeGpx = prefs.getString('active_gpx');
    final destUuid = prefs.getString('nav_wp_uuid');

    // Chargement de la trace si nécessaire
    if (_activeTrace?.name != activeGpx) {
      if (activeGpx == null) {
        _activeTrace = null;
        _activePolyline = [];
        _traceWaypoints = [];
      } else {
        _activeTrace = await isarService.isar.traces.filter().nameEqualTo(activeGpx).findFirst();
        if (_activeTrace != null) {
          _activePolyline = await isarService.getTracePolyline(_activeTrace!);
          _traceWaypoints = await isarService.searchWaypoints(filterGpxName: activeGpx);
        }
      }
    }

    if (_activePolyline.isEmpty) {
      trackDistanceDoneMeters.value = 0;
      trackDistanceRemainingMeters.value = 0;
      nextWaypoint.value = null;
      distanceToNextWaypointMeters.value = 0;
      return;
    }

    // Projection sur la trace
    final snap = GeoUtils.snapToPolyline(
      position.latitude, 
      position.longitude, 
      _activePolyline, 
      50.0 // Rayon de 50m pour être considéré sur la trace
    );

    if (snap == null) return;

    final totalDist = GeoUtils.polylineLengthMeters(_activePolyline);
    final doneDist = GeoUtils.distanceToSnapMeters(_activePolyline, snap);
    
    trackDistanceDoneMeters.value = doneDist;
    trackDistanceRemainingMeters.value = totalDist - doneDist;

    // Calcul du prochain waypoint
    Waypoint? next;
    double minDistToNext = double.infinity;

    for (final wp in _traceWaypoints) {
      final wpSnap = GeoUtils.snapToPolyline(wp.latitude, wp.longitude, _activePolyline, 100);
      if (wpSnap == null) continue;

      final wpDist = GeoUtils.distanceToSnapMeters(_activePolyline, wpSnap);
      if (wpDist > doneDist) {
        final dist = wpDist - doneDist;
        if (dist < minDistToNext) {
          minDistToNext = dist;
          next = wp;
        }
      }
    }
    nextWaypoint.value = next;
    distanceToNextWaypointMeters.value = next != null ? minDistToNext : 0;

    // Destination spécifique
    if (destUuid != null) {
      final dest = await isarService.isar.waypoints.filter().localUuidEqualTo(destUuid).findFirst();
      destinationWaypoint.value = dest;
      if (dest != null) {
        final destSnap = GeoUtils.snapToPolyline(dest.latitude, dest.longitude, _activePolyline, 100);
        if (destSnap != null) {
          final destDist = GeoUtils.distanceToSnapMeters(_activePolyline, destSnap);
          distanceToDestinationMeters.value = (destDist - doneDist).abs();
        } else {
          // Si le point n'est pas sur la trace, distance à vol d'oiseau ?
          distanceToDestinationMeters.value = geo.Geolocator.distanceBetween(
            position.latitude, position.longitude, dest.latitude, dest.longitude
          );
        }
      }
    } else {
      destinationWaypoint.value = null;
      distanceToDestinationMeters.value = 0;
    }
  }

  Future<void> _persistDailyDistance(double distance) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('daily_distance_meters', distance);
    await prefs.setString('daily_distance_date', DateTime.now().toIso8601String());
  }

  Future<void> _flushBatch() async {
    if (_pendingBatch.isEmpty || _sessionUuid == null) return;

    final batch = RecordingPointBatch()
      ..sessionUuid = _sessionUuid!
      ..batchIndex = _batchIndex++
      ..points = List.of(_pendingBatch)
      ..startsNewSegment = _nextPointStartsNewSegment;

    _nextPointStartsNewSegment = false;
    _pendingBatch.clear();

    await isarService.isar.writeTxn(
      () => isarService.isar.recordingPointBatchs.put(batch),
    );
  }

  /// Met l'enregistrement en pause : arrete reellement la consommation
  /// GPS (pas juste un filtre applicatif qui ignorerait les points) --
  /// coherent avec la contrainte batterie du brief. A la reprise, le
  /// premier point du lot suivant est marque startsNewSegment, exactement
  /// comme une rupture de segment GPX importe.
  Future<void> pause() async {
    if (status.value != RecordingStatus.recording) return;
    await _flushBatch();
    await _positionSub?.cancel();
    _positionSub = null;
    status.value = RecordingStatus.paused;

    await isarService.isar.writeTxn(() async {
      final draft = await isarService.isar.recordingDrafts
          .filter()
          .sessionUuidEqualTo(_sessionUuid!)
          .findFirst();
      if (draft != null) {
        draft
          ..isPaused = true
          ..updatedAt = DateTime.now();
        await isarService.isar.recordingDrafts.put(draft);
      }
    });
  }

  Future<void> resume() async {
    if (status.value != RecordingStatus.paused) return;
    _nextPointStartsNewSegment = true;
    _positionSub = geo.Geolocator
        .getPositionStream(locationSettings: _buildLocationSettings())
        .listen(_onPosition);
    status.value = RecordingStatus.recording;
  }

  /// Bascule le mode route/hors-piste ("aimant"). Sans effet persistant
  /// avant le premier start() (juste l'etat par defaut du prochain
  /// enregistrement) ; pendant une session active, enregistre un
  /// RecordingModeOverride horodate, consomme par SegmentationEngine a
  /// l'arret pour forcer une coupure et le mode de la tranche suivante.
  Future<void> setMagnetEnabled(bool enabled) async {
    if (magnetEnabled.value == enabled) return;
    magnetEnabled.value = enabled;
    if (_sessionUuid == null || status.value == RecordingStatus.idle) return;

    await isarService.isar.writeTxn(
      () => isarService.isar.recordingModeOverrides.put(
        RecordingModeOverride()
          ..sessionUuid = _sessionUuid!
          ..at = DateTime.now()
          ..mode = enabled ? SegmentMode.routed : SegmentMode.offPath,
      ),
    );
  }

  Future<void> toggleMagnet() => setMagnetEnabled(!magnetEnabled.value);

  /// Arrete l'enregistrement, reconstitue la trace complete a partir des
  /// lots persistes, la decoupe via SegmentationEngine (meme moteur que
  /// l'import GPX de l'etape 2), persiste le resultat et nettoie les
  /// donnees provisoires.
  Future<SegmentationResult> stop({
    required String ownerUuid,
    required LocalSearchEngine searchEngine,
    String? traceName,
    SegmentationEngine engine = const SegmentationEngine(),
  }) async {
    if (status.value == RecordingStatus.idle) {
      throw StateError('Aucun enregistrement en cours.');
    }

    await _flushBatch();
    await _positionSub?.cancel();
    _positionSub = null;

    final sessionUuid = _sessionUuid!;
    final result = await _finalizeSession(
      sessionUuid: sessionUuid,
      ownerUuid: ownerUuid,
      activityType: _activityType,
      traceName: traceName,
      searchEngine: searchEngine,
      engine: engine,
    );

    _sessionUuid = null;
    status.value = RecordingStatus.idle;
    return result;
  }

  // -----------------------------------------------------------------
  // Recuperation apres arret brutal
  // -----------------------------------------------------------------

  /// Session laissee en cours par un precedent lancement de l'app (voir
  /// la doc de RecordingDraft). A appeler au demarrage de l'app pour
  /// proposer "Reprendre l'enregistrement interrompu ?".
  Future<RecordingDraft?> findAbandonedDraft() {
    return isarService.currentRecordingDraft();
  }

  /// Finalise directement une session retrouvee apres un arret brutal,
  /// SANS tenter de relancer le flux GPS (le contexte -- position, cause
  /// de l'arret... -- a ete perdu). Convertit simplement ce qui a ete
  /// persiste jusqu'ici en Trace + Segments, comme le ferait stop().
  Future<SegmentationResult> finalizeAbandonedDraft({
    required RecordingDraft draft,
    required LocalSearchEngine searchEngine,
    String? traceName,
    SegmentationEngine engine = const SegmentationEngine(),
  }) {
    return _finalizeSession(
      sessionUuid: draft.sessionUuid,
      ownerUuid: draft.ownerUuid,
      activityType: draft.activityType,
      traceName: traceName,
      searchEngine: searchEngine,
      engine: engine,
    );
  }

  Future<SegmentationResult> _finalizeSession({
    required String sessionUuid,
    required String ownerUuid,
    required ActivityType activityType,
    required LocalSearchEngine searchEngine,
    required SegmentationEngine engine,
    String? traceName,
  }) async {
    final batches = await isarService.isar.recordingPointBatchs
        .filter()
        .sessionUuidEqualTo(sessionUuid)
        .sortByBatchIndex()
        .findAll();

    final trackPoints = <GpxTrackPoint>[];
    for (final batch in batches) {
      var isFirst = true;
      for (final p in batch.points) {
        trackPoints.add(GpxTrackPoint(
          latitude: p.latitude,
          longitude: p.longitude,
          elevation: p.altitude,
          time: p.timestamp,
          startsNewSegment: isFirst && batch.startsNewSegment,
        ));
        isFirst = false;
      }
    }

    if (trackPoints.length < 2) {
      throw StateError(
        'Session trop courte pour produire une trace exploitable '
        '(${trackPoints.length} point(s) enregistre(s)).',
      );
    }

    final overrideRows = await isarService.isar.recordingModeOverrides
        .filter()
        .sessionUuidEqualTo(sessionUuid)
        .sortByAt()
        .findAll();
    final overrides = overrideRows
        .map((o) => ModeOverride(at: o.at, mode: o.mode))
        .toList();

    final parsed = GpxParseResult(
      trackPoints: trackPoints,
      waypoints: const [],
      traceName: traceName,
    );

    // Meme logique de pre-chargement cible que GpxImportService (etape
    // 2) : seuls les segments/POI de la zone parcourue sont charges.
    const margin = 0.01;
    final lats = trackPoints.map((p) => p.latitude);
    final lons = trackPoints.map((p) => p.longitude);
    final minLat = lats.reduce(min) - margin;
    final maxLat = lats.reduce(max) + margin;
    final minLon = lons.reduce(min) - margin;
    final maxLon = lons.reduce(max) + margin;

    final nearbySegments = await isarService.segmentsInViewport(
      minLat: minLat,
      maxLat: maxLat,
      minLon: minLon,
      maxLon: maxLon,
    );
    final nearbyPois = await isarService.poisInViewport(
      minLat: minLat,
      maxLat: maxLat,
      minLon: minLon,
      maxLon: maxLon,
    );

    final result = engine.segment(
      gpx: parsed,
      nearbyExistingSegments: nearbySegments,
      nearbyExistingPois: nearbyPois,
      ownerUuid: ownerUuid,
      traceNameOverride: traceName,
      activityType: activityType,
      modeOverrides: overrides,
    );

    await SegmentationPersistence.persist(
      isarService: isarService,
      result: result,
      searchEngine: searchEngine,
      additionalWork: () async {
        // La session est désormais entièrement transformée en données
        // définitives : les données provisoires n'ont plus lieu d'être.
        // Exécuté dans LA MÊME transaction que les upserts ci-dessus
        // (voir SegmentationPersistence.persist) : soit tout réussit
        // ensemble, soit rien n'est modifié.
        await isarService.isar.recordingPointBatchs
            .filter()
            .sessionUuidEqualTo(sessionUuid)
            .deleteAll();
        await isarService.isar.recordingModeOverrides
            .filter()
            .sessionUuidEqualTo(sessionUuid)
            .deleteAll();
        await isarService.isar.recordingDrafts
            .filter()
            .sessionUuidEqualTo(sessionUuid)
            .deleteAll();
      },
    );

    return result;
  }

  /// A appeler quand l'UI qui possede ce service est detruite, pour
  /// liberer le flux GPS et les ValueNotifier.
  void dispose() {
    unawaited(_positionSub?.cancel());
    status.dispose();
    magnetEnabled.dispose();
    pointCount.dispose();
  }
}
