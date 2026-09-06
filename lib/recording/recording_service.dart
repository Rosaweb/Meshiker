import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:gnss_diagnostics/gnss_diagnostics.dart';
import 'package:gnss_diagnostics/src/models.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:isar_community/isar.dart';
import 'package:solar_calculator/solar_calculator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../database/isar_service.dart';
import '../gps/gps_fix_quality.dart';
import '../gps/stationary_detector.dart';
import '../gpx/gpx_models.dart';
import '../gpx/segmentation_engine.dart';
import '../gpx/segmentation_persistence.dart';
import '../models/enums.dart';
import '../models/gps_point.dart';
import '../models/recording_draft.dart';
import '../models/segment.dart';
import '../models/trace.dart';
import '../models/waypoint.dart';
import '../search/local_search_engine.dart';
import '../utils/elevation_service.dart';
import '../utils/geo_utils.dart';
import '../utils/pedometer_service.dart';
import '../utils/settings_service.dart';
import 'on_trace_detector.dart';
import 'recording_config.dart';

const _uuid = Uuid();

/// [ValueNotifier] variant that always notifies listeners on assignment,
/// even when the new value compares equal to the previous one. Needed for
/// [RecordingService.currentPosition]: a stationary GPS fix can repeat an
/// identical [geo.Position], but the map still needs the redraw.
class AlwaysNotifyValueNotifier<T> extends ChangeNotifier
    implements ValueListenable<T> {
  AlwaysNotifyValueNotifier(this._value);

  T _value;

  @override
  T get value => _value;

  set value(T newValue) {
    _value = newValue;
    notifyListeners();
  }
}

class RecordingService {
  RecordingService({
    required this.isarService,
    this.pedometerService,
    this.settingsService,
    this.config = const RecordingConfig(),
  });

  final IsarService isarService;
  final PedometerService? pedometerService;
  final SettingsService? settingsService;
  final RecordingConfig config;

  StreamSubscription<geo.Position>? _positionSub;
  StreamSubscription<GnssStatusSnapshot>? _gnssSub;
  Timer? _signalLostTimer;
  
  String? _sessionUuid;
  ActivityType _activityType = ActivityType.hiking;

  // Filtrage centralisé du bruit GPS (spec-filtrage-gps-centralise.md),
  // partagé par la distance journalière, le stockage de la trace et le
  // calibrage podomètre -- voir `_onPosition`.
  final StationaryDetector _stationaryDetector = StationaryDetector();
  // Dernier fix ayant passé `GpsFixQuality` (distinct du dernier fix reçu,
  // `currentPosition.value`, qui peut avoir été rejeté) : sert de référence
  // pour évaluer le fix suivant et pour calculer la distance journalière.
  geo.Position? _lastAcceptedFix;

  final List<PointGPS> _pendingBatch = [];
  // Historique complet de la session en cours, pour l'affichage de la trace
  // live sur la carte -- distinct de `_pendingBatch`, qui est vidé à chaque
  // flush vers Isar et ne doit pas piloter l'affichage.
  final List<PointGPS> _liveTrackPoints = [];
  int _batchIndex = 0;
  bool _nextPointStartsNewSegment = false;
  
  int _lastCalibrationSteps = 0;
  geo.Position? _lastCalibrationPosition;
  // Altitude retenue au dernier point de calibrage : plus nécessairement
  // `position.altitude` (peut venir d'une trace suivie, cf. §4.1 du spec).
  double _lastCalibrationElevation = 0;
  // Suit l'état actif du podomètre vu par le dernier `_onPosition`, pour
  // détecter une transition inactif → actif et ré-armer le baseline de
  // calibrage (cf. `_resetPedometerCalibrationBaseline`).
  bool _pedometerCalibrationArmed = false;

  final _onTraceDetector = OnTraceDetector();
  // localUuid des segments dont on a déjà tenté l'enrichissement altimétrique
  // pendant cette session (évite de re-solliciter le DEM tant que l'app tourne
  // et qu'ils restent hors-ligne). Vidé au redémarrage de l'app.
  final Set<String> _elevationEnrichmentAttempted = {};
  // Cache des Segment d'une trace chargée dans le Roadmap (source d'altitude
  // prioritaire et immédiate), keyé par `Trace.localUuid`.
  String? _roadmapSegmentsCacheKey;
  List<Segment> _roadmapSegmentsCache = const [];

  final ValueNotifier<RecordingStatus> status =
      ValueNotifier(RecordingStatus.idle);

  final ValueNotifier<bool> magnetEnabled = ValueNotifier(true);

  final ValueNotifier<int> pointCount = ValueNotifier(0);
  final ValueNotifier<List<PointGPS>> livePoints = ValueNotifier([]);

  final ValueNotifier<double> currentSpeedMps = ValueNotifier(0.0);
  final ValueNotifier<double> averageSpeedDailyMps = ValueNotifier(0.0);
  final ValueNotifier<double> averageSpeedGlobalMps = ValueNotifier(0.0);
  final ValueNotifier<double> dailyDistanceMeters = ValueNotifier(0.0);
  final ValueNotifier<double> gpsAccuracyMeters = ValueNotifier(0.0);
  final AlwaysNotifyValueNotifier<geo.Position?> currentPosition =
      AlwaysNotifyValueNotifier(null);
  final ValueNotifier<String> gpsStatus = ValueNotifier('-');

  // Stockage détaillé des satellites
  final Map<String, int> _constellationCounts = {};
  int _totalSatellites = 0;

  Map<String, int> get constellationBreakdown => Map.unmodifiable(_constellationCounts);
  int get totalSatellites => _totalSatellites;

  // Données solaires
  final ValueNotifier<String> solarTimes = ValueNotifier('--:--');

  final ValueNotifier<double> trackDistanceDoneMeters = ValueNotifier(0.0);
  final ValueNotifier<double> trackDistanceRemainingMeters = ValueNotifier(0.0);

  final ValueNotifier<Waypoint?> nextWaypoint = ValueNotifier(null);
  final ValueNotifier<double> distanceToNextWaypointMeters = ValueNotifier(0.0);
  final ValueNotifier<Waypoint?> destinationWaypoint = ValueNotifier(null);
  final ValueNotifier<double> distanceToDestinationMeters = ValueNotifier(0.0);

  bool _isDailyDistanceInitialized = false;
  Trace? _activeTrace;
  List<({double lat, double lon})> _activePolyline = [];
  List<Waypoint> _traceWaypoints = [];

  /// Trace actuellement chargée dans le Roadmap (`null` si aucune) —
  /// exposée pour l'assistant IA de navigation (v2, function calling :
  /// `decrire_itineraire`), qui n'a besoin que de lecture, jamais d'écriture.
  Trace? get activeRoadmapTrace => _activeTrace;

  /// Waypoints associés à la trace du Roadmap ci-dessus, mêmes données que
  /// celles utilisées pour les annonces vocales (§2 du plan) — même remarque
  /// que ci-dessus, lecture seule pour l'assistant IA.
  List<Waypoint> get activeRoadmapWaypoints => List.unmodifiable(_traceWaypoints);
  String? _lastKnownRoadmapTraceName;

  int _dailyPointsCount = 0;
  double _dailySpeedSum = 0.0;
  int _globalPointsCount = 0;
  double _globalSpeedSum = 0.0;

  bool get isActive => status.value == RecordingStatus.recording;

  Future<bool> ensurePermissions() async {
    try {
      bool serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('RecordingService: Location services disabled');
        // Optionnel : demander à l'utilisateur d'activer le GPS
        // await geo.Geolocator.openLocationSettings();
        return false;
      }

      var permission = await geo.Geolocator.checkPermission();
      debugPrint('RecordingService: Initial permission state: $permission');
      
      if (permission == geo.LocationPermission.denied) {
        debugPrint('RecordingService: Requesting location permission...');
        permission = await geo.Geolocator.requestPermission();
        debugPrint('RecordingService: Permission request result: $permission');
      }
      
      if (permission == geo.LocationPermission.deniedForever) {
        debugPrint('RecordingService: Permissions permanently denied');
        // Sur Xiaomi, on peut rediriger vers les paramètres si bloqué
        // await geo.Geolocator.openAppSettings();
        return false;
      }

      final granted = permission == geo.LocationPermission.whileInUse || 
                      permission == geo.LocationPermission.always;

      if (granted) {
        if (Platform.isAndroid) {
          // Demander l'accès en arrière-plan séparément (requis pour Xiaomi/MIUI)
          if (permission != geo.LocationPermission.always) {
            debugPrint('RecordingService: Requesting background location for better stability...');
            await geo.Geolocator.requestPermission();
          }

          // Demande notification (nécessaire pour le foreground service sur Android 13+)
          try {
            final notifStatus = await ph.Permission.notification.request();
            debugPrint('RecordingService: Notification permission: $notifStatus');
          } catch (e) {
            debugPrint('RecordingService: Notification request failed: $e');
          }
        }
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('RecordingService: Permission error: $e');
      return false;
    }
  }

  Future<bool> ensureBackgroundPermission() async {
    final permission = await geo.Geolocator.requestPermission();
    return permission == geo.LocationPermission.always;
  }

  void _updateSpeedAverages(double currentSpeed) {
    if (currentSpeed < 0.5) return;

    _dailyPointsCount++;
    _dailySpeedSum += currentSpeed;
    averageSpeedDailyMps.value = _dailySpeedSum / _dailyPointsCount;

    _globalPointsCount++;
    _globalSpeedSum += currentSpeed;
    averageSpeedGlobalMps.value = _globalSpeedSum / _globalPointsCount;
    
    _persistSpeedAverages();
  }

  Future<void> _initDailyDistance() async {
    _isDailyDistanceInitialized = true;
    final prefs = await SharedPreferences.getInstance();
    
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
      }
    } else {
      final initialDist = await isarService.getDailyDistanceMeters();
      dailyDistanceMeters.value = initialDist;
    }
  }

  void _resetSignalTimer() {
    _signalLostTimer?.cancel();
    if (settingsService != null && !settingsService!.locationEnabled) return;
    
    _signalLostTimer = Timer(const Duration(seconds: 15), () {
      if (_totalSatellites > 0) {
        // Signal instable ou faible
      } else {
        gpsStatus.value = 'en attente\nde signal';
      }
    });
  }

  StreamSubscription<geo.ServiceStatus>? _serviceStatusSub;

  Future<void> init() async {
    // Écoute des changements d'état du service GPS au niveau système
    _serviceStatusSub = geo.Geolocator.getServiceStatusStream().listen((status) {
      debugPrint('RecordingService: System location service status changed: $status');
      if (status == geo.ServiceStatus.enabled) {
        startPositionMonitoring();
      } else {
        gpsStatus.value = 'GPS désactivé';
        currentPosition.value = null;
      }
    });

    if (settingsService != null) {
      _lastKnownRoadmapTraceName = settingsService!.roadmapTraceName;
      pedometerService?.calibrationEnabled =
          settingsService!.pedometerCalibrationEnabled;
      settingsService!.addListener(() {
        final enabled = settingsService!.locationEnabled;
        debugPrint('RecordingService: In-app location toggle changed: $enabled');
        if (enabled) {
          startPositionMonitoring();
        } else {
          // Sans arrêt explicite, le flux GPS continuait de tourner malgré le
          // bouton "off" affiché à l'écran : la reprise ne correspondait alors
          // à aucune vraie coupure, et le baseline de calibrage du podomètre
          // ne se réarmait jamais après une pause GPS seule (podomètre resté
          // actif) -- cf. `stopPositionMonitoring`.
          stopPositionMonitoring();
        }

        // Répercute le réglage "calibrage podomètre actif" sur le service
        // podomètre (qui n'a pas de référence vers SettingsService).
        pedometerService?.calibrationEnabled =
            settingsService!.pedometerCalibrationEnabled;

        // Dès qu'une trace est chargée/déchargée du Roadmap, on recalcule
        // tout de suite le prochain waypoint plutôt que d'attendre le
        // prochain point GPS (qui peut ne jamais arriver en intérieur).
        final roadmapTraceName = settingsService!.roadmapTraceName;
        if (roadmapTraceName != _lastKnownRoadmapTraceName) {
          _lastKnownRoadmapTraceName = roadmapTraceName;
          unawaited(refreshNavigationStats());
        }
      });
    }

    await _initDailyDistance();

    // Charge `_activeTrace`/`_traceWaypoints` dès le démarrage si une trace
    // était déjà chargée dans le Roadmap lors d'une session précédente : le
    // bloc ci-dessus ne déclenche `refreshNavigationStats()` que sur un
    // CHANGEMENT du nom de trace pendant la session en cours, jamais pour
    // une trace déjà active au lancement — sans cet appel, `activeRoadmapTrace`
    // (assistant IA v2, `decrire_itineraire`) et l'affichage "Prochain
    // Waypoint" restent vides tant qu'aucun fix GPS n'est arrivé (repéré en
    // testant l'assistant en intérieur, sans GPS actif).
    unawaited(refreshNavigationStats());
  }

  /// Coupe le flux GPS de localisation (hors enregistrement de trace, cf.
  /// `pause()`/`stop()` pour ce cas). Toute reprise ultérieure repart d'un
  /// baseline de calibrage podomètre vierge (via `startPositionMonitoring`)
  /// et ne "ponte" pas la distance du jour au travers de la coupure
  /// (`_lastAcceptedFix` remis à null).
  void stopPositionMonitoring() {
    _positionSub?.cancel();
    _positionSub = null;
    _gnssSub?.cancel();
    _gnssSub = null;
    _signalLostTimer?.cancel();
    _signalLostTimer = null;
    _lastAcceptedFix = null;
    gpsStatus.value = '-';
    currentPosition.value = null;
  }

  /// Invalide le point de référence du calibrage podomètre (position, pas et
  /// altitude au dernier calibrage). À appeler à chaque reprise du flux GPS
  /// ou de la lecture de pas : sans cela, le premier calibrage après une
  /// pause "ponte" la distance parcourue avant l'arrêt à celle parcourue
  /// après la reprise via une simple distance à vol d'oiseau entre les deux
  /// positions. Sur un aller-retour (même itinéraire dans les deux sens),
  /// l'arrêt et la reprise ont lieu au même endroit : cette distance à vol
  /// d'oiseau reste artificiellement petite alors que le nombre de pas
  /// cumulés (aller + retour) est bien réel, ce qui fausse le ratio
  /// pas/mètre et retarde d'autant le calibrage du trajet retour.
  void _resetPedometerCalibrationBaseline() {
    _lastCalibrationPosition = null;
    _lastCalibrationSteps = 0;
    _lastCalibrationElevation = 0;
  }

  void startPositionMonitoring() {
    // On ne démarre le flux que si le bouton de l'app est activé
    if (settingsService != null && !settingsService!.locationEnabled) {
      debugPrint('RecordingService: Location disabled in app settings');
      gpsStatus.value = '-';
      return;
    }

    _positionSub?.cancel();
    _gnssSub?.cancel();
    _resetPedometerCalibrationBaseline();

    debugPrint('RecordingService: Starting position stream...');
    gpsStatus.value = 'recherche GPS';
    
    ensurePermissions().then((granted) {
      if (!granted) {
        debugPrint('RecordingService: Permissions not granted');
        gpsStatus.value = 'permission refusée';
        return;
      }

      try {
        _positionSub = geo.Geolocator.getPositionStream(
          locationSettings: _buildLocationSettings(isRecording: false),
        ).listen(
          (pos) {
            debugPrint('RecordingService: NEW POINT: ${pos.latitude}, ${pos.longitude}');
            _onPosition(pos);
          },
          onError: (e) {
            debugPrint('RecordingService: Stream error: $e');
            gpsStatus.value = 'erreur GPS';
          },
          cancelOnError: false,
        );

        // Intégration gnss_diagnostics pour le nombre de satellites (Android uniquement)
        if (Platform.isAndroid) {
          _gnssSub = GnssDiagnostics.statusStream.listen((snapshot) {
            _updateSatelliteInfo(snapshot);
          });
        }
        
        // On récupère une position immédiate
        geo.Geolocator.getCurrentPosition(
          locationSettings: _buildLocationSettings(isRecording: false)
        ).then((pos) {
          debugPrint('RecordingService: Initial fix point: ${pos.latitude}, ${pos.longitude}');
          _onPosition(pos);
        }).catchError((e) => debugPrint('Initial fix error: $e'));
        
        _resetSignalTimer();
      } catch (e) {
        debugPrint('RecordingService: Error starting stream: $e');
        gpsStatus.value = 'erreur technique';
      }
    });
  }

  void _updateSatelliteInfo(GnssStatusSnapshot snapshot) {
    _totalSatellites = snapshot.totalInView;
    _constellationCounts.clear();

    snapshot.constellations.forEach((name, stats) {
      if (stats.inView > 0) {
        // Normalisation des noms pour l'affichage
        final displayName = _normalizeConstellationName(name);
        _constellationCounts[displayName] = stats.inView;
      }
    });

    // Mise à jour du libellé affiché sur la carte
    if (_totalSatellites > 0) {
      gpsStatus.value = '$_totalSatellites Sats';
    } else {
      gpsStatus.value = 'Recherche...';
    }
  }

  String _normalizeConstellationName(String rawName) {
    switch (rawName.toLowerCase()) {
      case 'gps': return 'GPS';
      case 'glonass': return 'Glonass';
      case 'galileo': return 'Galileo';
      case 'beidou': return 'Beidou';
      case 'qzss': return 'QZSS';
      case 'irnss': return 'IRNSS';
      case 'sbas': return 'SBAS';
      default: return rawName[0].toUpperCase() + rawName.substring(1);
    }
  }

  Future<void> _persistSpeedAverages() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('global_speed_count', _globalPointsCount);
    await prefs.setDouble('global_speed_sum', _globalSpeedSum);
    
    await prefs.setInt('daily_speed_count', _dailyPointsCount);
    await prefs.setDouble('daily_speed_sum', _dailySpeedSum);
    await prefs.setString('daily_speed_date', DateTime.now().toIso8601String());
  }

  Future<void> start({
    required String ownerUuid,
    ActivityType activityType = ActivityType.hiking,
  }) async {
    if (status.value != RecordingStatus.idle) return;

    _sessionUuid = _uuid.v4();
    _activityType = activityType;
    _batchIndex = 0;
    _pendingBatch.clear();
    _liveTrackPoints.clear();
    _nextPointStartsNewSegment = false;
    pointCount.value = 0;
    livePoints.value = [];
    magnetEnabled.value = true;
    _resetPedometerCalibrationBaseline();

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

  /// [isRecording] : `false` quand seule la localisation est active (aucune
  /// trace en cours d'enregistrement) — la notification persistante Android
  /// doit alors refléter ce contexte plutôt que d'annoncer un enregistrement.
  geo.LocationSettings _buildLocationSettings({bool isRecording = true}) {
    if (Platform.isAndroid) {
      return geo.AndroidSettings(
        accuracy: geo.LocationAccuracy.best, // Passage en 'best' pour forcer Xiaomi à utiliser le GPS
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 2),
        // Important : spécifier explicitement le mode de notification
        foregroundNotificationConfig: geo.ForegroundNotificationConfig(
          notificationTitle:
              isRecording ? config.notificationTitle : 'Localisation active',
          notificationText: isRecording
              ? config.notificationText
              : 'Meshiker utilise votre position pour la navigation.',
          enableWakeLock: true,
        ),
      );
    }
    if (Platform.isIOS || Platform.isMacOS) {
      return geo.AppleSettings(
        accuracy: geo.LocationAccuracy.high,
        activityType: geo.ActivityType.fitness,
        distanceFilter: 0,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      );
    }
    return geo.LocationSettings(
      accuracy: geo.LocationAccuracy.high,
      distanceFilter: 0,
    );
  }

  void _onPosition(geo.Position position) {
    debugPrint('RecordingService: DISPATCHING POS: ${position.latitude}, ${position.longitude}');
    _resetSignalTimer();

    final lastPos = currentPosition.value;

    // Mise à jour de la valeur - déclenche toujours la notification aux
    // listeners (MapScreen), même si la position est identique à la
    // précédente (nécessaire pour garantir l'affichage dynamique sur la
    // carte lors d'un arrêt prolongé).
    currentPosition.value = position;

    currentSpeedMps.value = position.speed;
    gpsAccuracyMeters.value = position.accuracy;

    _updateSpeedAverages(position.speed);

    if (!_isDailyDistanceInitialized) {
      _initDailyDistance();
    }

    // Filtrage centralisé du bruit GPS (spec-filtrage-gps-centralise.md) :
    // qualité du fix par rapport au dernier fix accepté, et détection de
    // stationnarité sur fenêtre glissante (seuils configurables par
    // l'utilisateur). `accepted`/`isStationary` gouvernent ensuite les
    // trois branches dégradées par le bruit GPS ci-dessous ; tout le reste
    // de cette méthode continue de voir chaque fix brut sans filtre.
    final isStationary = _stationaryDetector.update(
      position,
      windowDuration:
          settingsService?.stationaryWindowPreset.duration ?? StationaryWindowPreset.s30.duration,
      radiusMeters:
          settingsService?.stationaryRadiusPreset.meters ?? StationaryRadiusPreset.m10.meters,
    );
    final previousAcceptedFix = _lastAcceptedFix;
    final accepted = previousAcceptedFix == null
        ? GpsFixQuality.isAcceptableFirstFix(position)
        : GpsFixQuality.isAcceptableFix(previous: previousAcceptedFix, current: position);
    if (accepted) _lastAcceptedFix = position;

    if (lastPos != null) {
      final now = DateTime.now();
      if (lastPos.timestamp.year == now.year &&
          lastPos.timestamp.month == now.month &&
          lastPos.timestamp.day == now.day) {
        // Un fix rejeté (précision/mouvement/vitesse implausible) ou une
        // pause détectée ne doit pas s'ajouter à la distance du jour --
        // sans ce filtre, la position "dérive" de quelques mètres à chaque
        // fix et gonfle artificiellement le total sur une journée entière,
        // y compris quand aucun trajet n'est en cours.
        if (accepted && !isStationary && previousAcceptedFix != null) {
          final dist = geo.Geolocator.distanceBetween(
            previousAcceptedFix.latitude,
            previousAcceptedFix.longitude,
            position.latitude,
            position.longitude,
          );
          dailyDistanceMeters.value += dist;
          _persistDailyDistance(dailyDistanceMeters.value);
        }
      } else {
        dailyDistanceMeters.value = 0;
        _persistDailyDistance(0);
      }
    }

    _updateNavigationStats(position);
    _updateSolarInfo(position);

    // Calibrage podomètre : indépendant de l'enregistrement d'une trace
    // (trop peu d'utilisateurs enregistrent réellement) — il suffit que la
    // localisation soit active (on est dans `_onPosition`), que le podomètre
    // tourne et que le réglage de calibrage soit actif.
    final pedometerCalibrationActive = pedometerService?.isActive == true &&
        (settingsService?.pedometerCalibrationEnabled ?? true);
    if (pedometerCalibrationActive) {
      // Transition inactif → actif (podomètre coupé puis relancé, ou GPS
      // repris, sans que la position ait bougé) : le baseline précédent
      // daterait d'avant la pause et fausserait le premier calibrage suivant
      // la reprise -- cf. `_resetPedometerCalibrationBaseline`.
      if (!_pedometerCalibrationArmed) {
        _resetPedometerCalibrationBaseline();
        _pedometerCalibrationArmed = true;
      }
      unawaited(_updatePedometerCalibration(position, accepted: accepted, isStationary: isStationary));
    } else {
      _pedometerCalibrationArmed = false;
    }

    if (status.value == RecordingStatus.recording) {
      // Un fix rejeté n'est jamais stocké. Un point de pause (`isStationary`)
      // n'est stocké que si l'utilisateur a explicitement activé
      // `recordPauses` (spec-filtrage-gps-centralise.md §6.1) -- par défaut,
      // la trace ne contient pas les positions d'un arrêt prolongé.
      final recordPauses = settingsService?.recordPauses ?? false;
      if (accepted && (!isStationary || recordPauses)) {
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

        // Mise à jour des points "live" pour l'affichage dynamique sur la
        // carte -- basée sur l'historique complet de la session, pas sur
        // `_pendingBatch`, qui est vidé périodiquement par `_flushBatch`.
        _liveTrackPoints.add(_pendingBatch.last);
        livePoints.value = List.of(_liveTrackPoints);

        if (_pendingBatch.length >= config.pointsPerBatch) {
          unawaited(_flushBatch());
        }
      }
    }
  }

  /// Met à jour le calibrage du podomètre tous les ~50 m parcourus, en
  /// privilégiant une altitude de trace (statique, stable) sur le
  /// différentiel d'altitude GPS live (deux fixs bruités) — cf.
  /// `spec-calibrage-podometre-elevation.md` §4.
  ///
  /// [accepted]/[isStationary] viennent du filtrage centralisé du bruit GPS
  /// (spec-filtrage-gps-centralise.md §6) : un fix rejeté est ignoré (aucun
  /// changement d'état), et une pause détectée réinitialise la référence de
  /// la fenêtre sans appeler `calibrateWithSlope` -- les pas comptés
  /// pendant une pause (piétinement, ajustement du sac) ne correspondent à
  /// aucune distance GPS réelle et fausseraient le ratio distance/pas.
  Future<void> _updatePedometerCalibration(
    geo.Position position, {
    required bool accepted,
    required bool isStationary,
  }) async {
    final ped = pedometerService;
    if (ped == null || !accepted) return;

    // Source d'altitude, par priorité : trace chargée dans le Roadmap →
    // détection passive d'une trace suivie → altitude GPS live (repli).
    final segment = await _roadmapSegmentAt(position) ??
        await _onTraceDetector.checkPosition(
            position.latitude, position.longitude, isarService);

    double? elevationSource;
    if (segment != null) {
      // Comble les altitudes manquantes du segment en tâche de fond : la
      // passe courante utilise ce qui est déjà connu (repli GPS si tout est
      // `null`), les passes suivantes profiteront de l'enrichissement.
      unawaited(_tryEnrichSegmentElevation(segment));
      elevationSource = _nearestAltitudeOnSegment(segment, position);
    }
    elevationSource ??= position.altitude;

    if (_lastCalibrationPosition == null || isStationary) {
      _lastCalibrationPosition = position;
      _lastCalibrationSteps = ped.steps;
      _lastCalibrationElevation = elevationSource;
      return;
    }

    final dist = geo.Geolocator.distanceBetween(
      _lastCalibrationPosition!.latitude,
      _lastCalibrationPosition!.longitude,
      position.latitude,
      position.longitude,
    );
    if (dist < 50) return;

    final stepsDelta = ped.steps - _lastCalibrationSteps;
    final elevationDelta = elevationSource - _lastCalibrationElevation;
    final consumed = ped.calibrateWithSlope(dist, elevationDelta, stepsDelta);

    // Le point de référence n'avance que si la fenêtre a été intégrée : si
    // le capteur de pas natif a calé sur ces ~50 m (stepsDelta <= 0 --
    // montée lente, bâtons, téléphone dans le sac...), la distance GPS
    // parcourue ne doit pas être perdue. En laissant le baseline en place,
    // elle se cumule avec la fenêtre suivante jusqu'à ce que des pas soient
    // de nouveau détectés, au lieu de disparaître du total affiché dans le
    // rapport.
    if (consumed) {
      _lastCalibrationPosition = position;
      _lastCalibrationSteps = ped.steps;
      _lastCalibrationElevation = elevationSource;
    }
  }

  /// Si une trace est chargée dans le Roadmap, retourne le segment de cette
  /// trace sur lequel se trouve [position] (à moins de 30 m), sinon `null`.
  /// Prioritaire et immédiat : pas d'attente de confirmation contrairement à
  /// [OnTraceDetector].
  Future<Segment?> _roadmapSegmentAt(geo.Position position) async {
    final trace = _activeTrace;
    if (trace == null) return null;

    if (_roadmapSegmentsCacheKey != trace.localUuid) {
      final entries = trace.segments.toList()
        ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
      final segs = <Segment>[];
      for (final e in entries) {
        final s = await isarService.segmentByUuid(e.segmentUuid);
        if (s != null) segs.add(s);
      }
      _roadmapSegmentsCache = segs;
      _roadmapSegmentsCacheKey = trace.localUuid;
    }

    for (final s in _roadmapSegmentsCache) {
      if (s.points.length < 2) continue;
      final poly =
          s.points.map((p) => (lat: p.latitude, lon: p.longitude)).toList();
      if (GeoUtils.snapToPolyline(
              position.latitude, position.longitude, poly, 30.0) !=
          null) {
        return s;
      }
    }
    return null;
  }

  /// Altitude interpolée au point de [segment] le plus proche de [position]
  /// (`null` si la position n'est pas sur le segment, ou si les deux points
  /// encadrants n'ont pas d'altitude).
  double? _nearestAltitudeOnSegment(Segment segment, geo.Position position) {
    final poly = segment.points
        .map((p) => (lat: p.latitude, lon: p.longitude))
        .toList();
    final snap = GeoUtils.snapToPolyline(
        position.latitude, position.longitude, poly, 30.0);
    if (snap == null) return null;

    final a = segment.points[snap.segmentIndex].altitude;
    final b = segment.points[snap.segmentIndex + 1].altitude;
    if (a == null && b == null) return null;
    if (a == null) return b;
    if (b == null) return a;
    return a + (b - a) * snap.t;
  }

  /// Comble les altitudes `null` d'un segment via un modèle de terrain
  /// ([ElevationService]), recalcule son dénivelé et celui des traces qui le
  /// référencent. Événement unique par segment et par exécution de l'app
  /// (garde-fou mémoire [_elevationEnrichmentAttempted]). Correction de cache
  /// locale : ne touche jamais `syncStatus`.
  Future<void> _tryEnrichSegmentElevation(Segment segment) async {
    if (_elevationEnrichmentAttempted.contains(segment.localUuid)) return;

    final missing = <int>[
      for (var i = 0; i < segment.points.length; i++)
        if (segment.points[i].altitude == null) i
    ];
    if (missing.isEmpty) return;

    _elevationEnrichmentAttempted.add(segment.localUuid);

    final coords = missing
        .map((i) => (
              lat: segment.points[i].latitude,
              lon: segment.points[i].longitude
            ))
        .toList();
    final elevations = await ElevationService.fetchElevations(coords);

    var anyFilled = false;
    for (var j = 0; j < missing.length; j++) {
      final ele = elevations[j];
      if (ele != null) {
        segment.points[missing[j]].altitude = ele;
        anyFilled = true;
      }
    }
    if (!anyFilled) {
      // Tout a échoué (hors-ligne...) : on autorise une nouvelle tentative
      // plus tard plutôt que de figer l'échec pour la session.
      _elevationEnrichmentAttempted.remove(segment.localUuid);
      return;
    }

    final elev = GeoUtils.elevationGainLoss(
        segment.points.map((p) => p.altitude).toList());
    segment.elevationGainMeters = elev.gain;
    segment.elevationLossMeters = elev.loss;
    segment.updatedAt = DateTime.now();

    await isarService.isar
        .writeTxn(() => isarService.isar.segments.put(segment));
    await isarService.recomputeTraceElevationTotals(segment.localUuid);
  }

  void _updateSolarInfo(geo.Position position) {
    final now = DateTime.now();
    final solar = SolarCalculator(
      Instant(
        year: now.year,
        month: now.month,
        day: now.day,
        hour: now.hour,
        minute: now.minute,
        second: now.second,
      ),
      position.latitude,
      position.longitude,
      now.timeZoneOffset.inHours.toDouble(),
    );

    // Utilisation des propriétés Instant du package
    final sunrise = solar.sunriseTime.toUtcDateTime().toLocal();
    final sunset = solar.sunsetTime.toUtcDateTime().toLocal();
    final twilight = solar.eveningCivilTwilight.ending.toUtcDateTime().toLocal();

    solarTimes.value = 'L: ${_formatTime(sunrise)}\nC: ${_formatTime(sunset)}\nCr: ${_formatTime(twilight)}';
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> setDestination(String? uuid) async {
    final prefs = await SharedPreferences.getInstance();
    if (uuid == null) {
      await prefs.remove('nav_wp_uuid');
    } else {
      await prefs.setString('nav_wp_uuid', uuid);
    }

    await _updateNavigationStats(currentPosition.value);
  }

  /// Recalcule les outils de navigation (prochain waypoint, destination) à
  /// partir de la trace actuellement chargée dans le Roadmap, sans attendre
  /// un nouveau point GPS. À appeler dès qu'une trace est chargée/déchargée
  /// du Roadmap : tant qu'aucune position n'est encore connue, les distances
  /// par défaut sont calculées depuis le DÉBUT de la trace (cf.
  /// _updateNavigationStats), pour que "Prochain Waypoint" affiche tout de
  /// suite le premier waypoint plutôt que de rester vide en attendant un fix.
  Future<void> refreshNavigationStats() => _updateNavigationStats(currentPosition.value);

  Future<void> _updateNavigationStats(geo.Position? position) async {
    final prefs = await SharedPreferences.getInstance();
    final roadmapTrace = prefs.getString('roadmap_trace_name');
    final destUuid = prefs.getString('nav_wp_uuid');

    if (_activeTrace?.name != roadmapTrace) {
      if (roadmapTrace == null) {
        _activeTrace = null;
        _activePolyline = [];
        _traceWaypoints = [];
      } else {
        _activeTrace = await isarService.isar.traces.filter().nameEqualTo(roadmapTrace).findFirst();
        if (_activeTrace != null) {
          _activePolyline = await isarService.getTracePolyline(_activeTrace!);
          _traceWaypoints = await isarService.searchWaypoints(filterGpxName: roadmapTrace);
        } else {
          _activePolyline = [];
          _traceWaypoints = [];
        }
      }
    }

    if (_activePolyline.isEmpty) {
      trackDistanceDoneMeters.value = 0;
      trackDistanceRemainingMeters.value = 0;
      nextWaypoint.value = null;
      distanceToNextWaypointMeters.value = 0;

      // Pas de trace chargée dans le Roadmap : distance directe si une
      // destination a été choisie manuellement, sinon rien à afficher.
      if (destUuid != null) {
        final dest = await isarService.isar.waypoints.filter().localUuidEqualTo(destUuid).findFirst();
        destinationWaypoint.value = dest;
        distanceToDestinationMeters.value = (dest != null && position != null)
            ? geo.Geolocator.distanceBetween(position.latitude, position.longitude, dest.latitude, dest.longitude)
            : 0;
      } else {
        destinationWaypoint.value = null;
        distanceToDestinationMeters.value = 0;
      }
      return;
    }

    // Tant qu'aucune position GPS n'est encore connue (pas de fix depuis le
    // démarrage, permission en attente...), on se comporte comme si la
    // position était hors de la marge de 50m : les distances par défaut sont
    // calculées depuis le DÉBUT de la trace (voir doneDist plus bas).
    final snap = position != null
        ? GeoUtils.snapToPolyline(
            position.latitude,
            position.longitude,
            _activePolyline,
            50.0
          )
        : null;

    final totalDist = GeoUtils.polylineLengthMeters(_activePolyline);
    // Tant que la position GPS n'est pas détectée sur la trace (hors de la
    // marge de 50m), on calcule les distances par défaut depuis le DÉBUT
    // de la trace plutôt que de ne rien afficher : dès que la position est
    // détectée sur la trace, tout se recalcule par rapport à elle.
    final doneDist = snap != null
        ? GeoUtils.distanceToSnapMeters(_activePolyline, snap)
        : 0.0;

    trackDistanceDoneMeters.value = doneDist;
    trackDistanceRemainingMeters.value = totalDist - doneDist;

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

    // Destination : waypoint choisi explicitement, sinon repli sur la fin
    // de la trace chargée (qui n'a pas forcément de waypoint dessus — et
    // qui, pour une boucle, coïncide déjà avec le point de départ).
    if (destUuid != null) {
      final dest = await isarService.isar.waypoints.filter().localUuidEqualTo(destUuid).findFirst();
      if (dest != null) {
        final destSnap = GeoUtils.snapToPolyline(dest.latitude, dest.longitude, _activePolyline, 100);
        destinationWaypoint.value = dest;
        if (destSnap != null) {
          distanceToDestinationMeters.value =
              (GeoUtils.distanceToSnapMeters(_activePolyline, destSnap) - doneDist).abs();
        } else if (snap != null && position != null) {
          // Le point d'étape est hors trace (ex: POI à proximité) : distance
          // directe depuis la position, mais seulement si cette position a
          // été détectée SUR la trace (snap != null) — sinon (pas de fix,
          // hors marge...) on retombe sur le DÉBUT de la trace, comme pour
          // "prochain waypoint" et la destination par défaut ci-dessous.
          distanceToDestinationMeters.value =
              geo.Geolocator.distanceBetween(position.latitude, position.longitude, dest.latitude, dest.longitude);
        } else {
          final startPoint = _activePolyline.first;
          distanceToDestinationMeters.value =
              geo.Geolocator.distanceBetween(startPoint.lat, startPoint.lon, dest.latitude, dest.longitude);
        }
      } else {
        destinationWaypoint.value = null;
        distanceToDestinationMeters.value = 0;
      }
    } else {
      final endPoint = _activePolyline.last;
      destinationWaypoint.value = Waypoint()
        ..localUuid = ''
        ..name = 'Fin de trace'
        ..latitude = endPoint.lat
        ..longitude = endPoint.lon;
      distanceToDestinationMeters.value = totalDist - doneDist;
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
    _resetPedometerCalibrationBaseline();
    _positionSub = geo.Geolocator
        .getPositionStream(locationSettings: _buildLocationSettings())
        .listen(_onPosition);
    status.value = RecordingStatus.recording;
  }

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
    _liveTrackPoints.clear();
    livePoints.value = [];
    return result;
  }

  Future<RecordingDraft?> findAbandonedDraft() {
    return isarService.currentRecordingDraft();
  }

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

    final result = await engine.segment(
      gpx: parsed,
      nearbyExistingSegments: nearbySegments,
      // Un enregistrement live ne produit jamais de <wpt> (voir `parsed`
      // ci-dessus, waypoints: const []) : rien a resoudre, inutile
      // d'interroger Isar pour ca.
      nearbyExistingWaypoints: const [],
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

  Future<void> discard(String sessionUuid) async {
    await isarService.isar.writeTxn(() async {
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
    });
    _sessionUuid = null;
    status.value = RecordingStatus.idle;
    _liveTrackPoints.clear();
    livePoints.value = [];
  }

  void dispose() {
    unawaited(_positionSub?.cancel());
    unawaited(_gnssSub?.cancel());
    status.dispose();
    magnetEnabled.dispose();
    pointCount.dispose();
  }
}
