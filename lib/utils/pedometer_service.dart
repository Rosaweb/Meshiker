import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:shared_preferences/shared_preferences.dart';

class PedometerProfile {
  final String id;
  final double minSlope;
  final double maxSlope;

  /// Valeur d'usine (utilisée par [PedometerService.resetProfile]).
  final double defaultMetersPerStep;

  double metersPerStep;
  int totalSteps;
  double totalDistance;

  // --- Stabilisation par convergence -----------------------------------
  //
  // Chaque profil se fige à son propre rythme : quand sa longueur de pas
  // ne dérive plus de [stabilityEpsilon] sur [freezeAfterStableCheckpoints]
  // checkpoints consécutifs (un checkpoint tous les [checkpointEvery]
  // événements de calibrage), il passe `frozen` et n'intègre plus de
  // nouvelle mesure — sauf réactivation explicite.

  /// Cadence d'évaluation de la convergence, en événements de calibrage.
  static const checkpointEvery = 3;

  /// Nombre de checkpoints stables consécutifs avant figement.
  static const freezeAfterStableCheckpoints = 3;

  /// Garde-fou : minimum d'événements de calibrage cumulés avant qu'un
  /// figement soit même envisageable (évite qu'un profil rarement
  /// déclenché se fige sur 2-3 mesures qui se ressemblent par hasard).
  static const minEventsBeforeFreezeEligible = 15;

  /// Variation relative de longueur de pas tolérée entre deux checkpoints.
  static const stabilityEpsilon = 0.02;

  bool frozen = false;
  double? lastCheckpointMetersPerStep;
  int eventsSinceCheckpoint = 0;
  int stableCheckpointStreak = 0;

  /// Nombre de fois où [PedometerService.calibrateWithSlope] a mis à jour
  /// CE profil (chaque événement ≈ 50 m parcourus) — distinct de
  /// [totalSteps], qui compte des pas.
  int totalCalibrationEvents = 0;

  PedometerProfile({
    required this.id,
    required this.minSlope,
    required this.maxSlope,
    required this.metersPerStep,
    this.totalSteps = 0,
    this.totalDistance = 0,
  }) : defaultMetersPerStep = metersPerStep;

  Map<String, dynamic> toJson() => {
    'metersPerStep': metersPerStep,
    'totalSteps': totalSteps,
    'totalDistance': totalDistance,
    'frozen': frozen,
    'lastCheckpointMetersPerStep': lastCheckpointMetersPerStep,
    'eventsSinceCheckpoint': eventsSinceCheckpoint,
    'stableCheckpointStreak': stableCheckpointStreak,
    'totalCalibrationEvents': totalCalibrationEvents,
  };

  void updateFromJson(Map<String, dynamic> json) {
    metersPerStep = (json['metersPerStep'] as num?)?.toDouble() ?? metersPerStep;
    totalSteps = (json['totalSteps'] as num?)?.toInt() ?? totalSteps;
    totalDistance = (json['totalDistance'] as num?)?.toDouble() ?? totalDistance;
    frozen = json['frozen'] as bool? ?? frozen;
    lastCheckpointMetersPerStep =
        (json['lastCheckpointMetersPerStep'] as num?)?.toDouble() ??
            lastCheckpointMetersPerStep;
    eventsSinceCheckpoint =
        (json['eventsSinceCheckpoint'] as num?)?.toInt() ?? eventsSinceCheckpoint;
    stableCheckpointStreak =
        (json['stableCheckpointStreak'] as num?)?.toInt() ?? stableCheckpointStreak;
    totalCalibrationEvents =
        (json['totalCalibrationEvents'] as num?)?.toInt() ?? totalCalibrationEvents;
  }
}

class PedometerService extends ChangeNotifier {
  Stream<StepCount>? _stepCountStream;
  Stream<PedestrianStatus>? _pedestrianStatusStream;
  StreamSubscription<StepCount>? _stepCountSub;
  StreamSubscription<PedestrianStatus>? _pedestrianStatusSub;

  int _steps = 0;
  int _totalStepsAllTime = 0;
  int _lastEventSteps = 0;
  String _status = '?';
  bool _isActive = false;
  bool _permissionDenied = false;
  bool _sensorUnavailable = false;

  /// Reflète `SettingsService.pedometerCalibrationEnabled` — tenu à jour par
  /// l'appelant (RecordingService). Quand `false`, [calibrateWithSlope]
  /// n'intègre plus aucune mesure.
  bool calibrationEnabled = true;

  int get steps => _steps;

  /// Cumul de pas persistant, toutes activations confondues (survit aux
  /// redémarrages de l'app, contrairement à [steps] qui ne compte que
  /// depuis la dernière activation).
  int get totalStepsAllTime => _totalStepsAllTime;

  String get status => _status;
  bool get isActive => _isActive;
  bool get permissionDenied => _permissionDenied;
  bool get sensorUnavailable => _sensorUnavailable;

  /// Profils de calibrage (lecture seule), triés du plus raide en montée au
  /// plus raide en descente, pour l'affichage détaillé (métrique 4).
  List<PedometerProfile> get profilesSortedBySlope =>
      _profiles.values.toList()..sort((a, b) => b.minSlope.compareTo(a.minSlope));

  /// Total de pas comptabilisés lors d'un calibrage (tous profils confondus).
  int get totalCalibratedSteps =>
      _profiles.values.fold(0, (sum, p) => sum + p.totalSteps);

  /// Distance cumulée correspondante, tous profils confondus.
  double get totalCalibratedDistanceMeters =>
      _profiles.values.fold(0.0, (sum, p) => sum + p.totalDistance);

  /// Pas moyen pour 100 m, tous profils confondus. `null` tant qu'aucune
  /// donnée n'a été calibrée.
  double? get avgStepsPer100m {
    if (totalCalibratedDistanceMeters <= 0) return null;
    return totalCalibratedSteps / totalCalibratedDistanceMeters * 100;
  }

  final Map<String, PedometerProfile> _profiles = {
    'steep_uphill': PedometerProfile(id: 'steep_uphill', minSlope: 0.15, maxSlope: 1.0, metersPerStep: 0.5),
    'uphill': PedometerProfile(id: 'uphill', minSlope: 0.05, maxSlope: 0.15, metersPerStep: 0.65),
    'flat': PedometerProfile(id: 'flat', minSlope: -0.05, maxSlope: 0.05, metersPerStep: 0.75),
    'downhill': PedometerProfile(id: 'downhill', minSlope: -0.15, maxSlope: -0.05, metersPerStep: 0.85),
    'steep_downhill': PedometerProfile(id: 'steep_downhill', minSlope: -1.0, maxSlope: -0.15, metersPerStep: 0.7),
  };

  PedometerService() {
    _loadCalibration();
    _loadTotalSteps();
  }

  Future<void> _loadTotalSteps() async {
    final prefs = await SharedPreferences.getInstance();
    _totalStepsAllTime = prefs.getInt('pedometer_total_steps_all_time') ?? 0;
    notifyListeners();
  }

  Future<void> _persistTotalSteps() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('pedometer_total_steps_all_time', _totalStepsAllTime);
  }

  /// Remise à zéro du compteur à vie (action destructive, confirmée côté UI).
  Future<void> resetTotalSteps() async {
    _totalStepsAllTime = 0;
    await _persistTotalSteps();
    notifyListeners();
  }

  Future<void> _loadCalibration() async {
    final prefs = await SharedPreferences.getInstance();
    for (var profile in _profiles.values) {
      final raw = prefs.getString('pedometer_profile_${profile.id}');
      if (raw == null) continue;

      Map<String, dynamic>? decoded;
      try {
        final parsed = jsonDecode(raw);
        if (parsed is Map<String, dynamic>) decoded = parsed;
      } catch (_) {
        // Pas du JSON : ancien format "metersPerStep|totalSteps|totalDistance".
      }

      if (decoded != null) {
        profile.updateFromJson(decoded);
      } else {
        final parts = raw.split('|');
        if (parts.length == 3) {
          profile.metersPerStep =
              double.tryParse(parts[0]) ?? profile.metersPerStep;
          profile.totalSteps = int.tryParse(parts[1]) ?? profile.totalSteps;
          profile.totalDistance =
              double.tryParse(parts[2]) ?? profile.totalDistance;
        }
        // Migration : réécrit tout de suite au nouveau format JSON.
        await _saveProfile(profile);
      }
    }
    notifyListeners();
  }

  /// Le capteur podomètre (TYPE_STEP_COUNTER) exige la permission runtime
  /// ACTIVITY_RECOGNITION sur Android 10+ : sans cette demande explicite,
  /// le flux de pas ne délivre jamais aucun événement (aucune erreur
  /// visible), ce qui donnait l'impression d'un podomètre actif ("carte
  /// verte") mais bloqué à 0 pas.
  Future<void> togglePedometer() async {
    _isActive = !_isActive;
    _permissionDenied = false;
    _sensorUnavailable = false;
    if (_isActive) {
      if (Platform.isAndroid) {
        var granted = (await ph.Permission.activityRecognition.status).isGranted;
        if (!granted) {
          granted = (await ph.Permission.activityRecognition.request()).isGranted;
        }
        if (!granted) {
          _isActive = false;
          _permissionDenied = true;
          notifyListeners();
          return;
        }
      }
      _initPedometer();
    } else {
      // Sans ce désabonnement explicite, le capteur continue d'émettre en
      // arrière-plan malgré la carte "inactive" à l'écran, et les pas pris
      // pendant cette période "off" seraient comptés à la réactivation.
      await _stepCountSub?.cancel();
      await _pedestrianStatusSub?.cancel();
      _stepCountSub = null;
      _pedestrianStatusSub = null;
      // Invalide le baseline : le premier événement après réactivation ne
      // fera que re-caler _lastEventSteps sans ajouter de delta (même
      // garde-fou que pour un redémarrage d'app).
      _lastEventSteps = 0;
    }
    notifyListeners();
  }

  /// Sur un appareil (ou émulateur) sans capteur de pas matériel, le plugin
  /// `pedometer` lève une PlatformException CÔTÉ ANDROID -- mais son
  /// `_androidStream()` interne écoute le stream brut avec un `.listen()`
  /// SANS `onError`, donc cette exception ne remonte jamais comme une
  /// simple erreur de stream : c'est une erreur asynchrone non rattrapée
  /// dans la Zone courante, qu'aucun try/catch classique ne peut intercepter
  /// ici. On isole l'appel dans sa propre Zone (runZonedGuarded) pour que
  /// cette erreur reste locale au podomètre au lieu de remonter jusqu'au
  /// gestionnaire d'erreurs global de l'app (qui traite toute erreur de
  /// Zone non rattrapée comme fatale, voir main.dart) et de faire planter
  /// tout l'écran.
  void _initPedometer() {
    runZonedGuarded(() {
      _pedestrianStatusStream = Pedometer.pedestrianStatusStream;
      _pedestrianStatusSub = _pedestrianStatusStream!
          .listen(_onPedestrianStatus, onError: _onPedestrianStatusError);

      _stepCountStream = Pedometer.stepCountStream;
      _stepCountSub =
          _stepCountStream!.listen(_onStepCount, onError: _onStepCountError);
    }, (error, stack) {
      debugPrint('PedometerService: capteur indisponible: $error');
      _isActive = false;
      _sensorUnavailable = true;
      _status = 'Capteur indisponible';
      notifyListeners();
    });
  }

  void _onStepCount(StepCount event) {
    if (_lastEventSteps > 0) {
      final delta = event.steps - _lastEventSteps;
      _steps += delta;
      _totalStepsAllTime += delta;
      _persistTotalSteps();
    }
    _lastEventSteps = event.steps;
    notifyListeners();
  }

  void _onPedestrianStatus(PedestrianStatus event) {
    _status = event.status;
    notifyListeners();
  }

  void _onPedestrianStatusError(Object error) {
    _status = 'Pedestrian Status not available';
  }

  void _onStepCountError(Object error) {
    _status = 'Step Count not available';
  }

  /// Calibrage intelligent basé sur la pente. Retourne `true` si la fenêtre
  /// a été intégrée -- l'appelant (RecordingService._updatePedometerCalibration)
  /// n'avance son point de référence que dans ce cas, pour reporter sur la
  /// fenêtre suivante la distance d'une fenêtre non exploitable (capteur de
  /// pas calé) plutôt que de la perdre définitivement du total affiché.
  bool calibrateWithSlope(double distanceDelta, double elevationDelta, int stepsDelta) {
    if (distanceDelta <= 0) return false;
    if (!calibrationEnabled) return false;
    // Le capteur de pas natif (TYPE_STEP_COUNTER) peut caler sur une
    // fenêtre de ~50 m (montée lente, bâtons, téléphone dans le sac...) :
    // sans mesure de pas, on ne peut pas en tirer de longueur de pas.
    if (stepsDelta <= 0) return false;

    final slope = elevationDelta / distanceDelta;
    PedometerProfile? target;

    for (var p in _profiles.values) {
      if (slope >= p.minSlope && slope < p.maxSlope) {
        target = p;
        break;
      }
    }

    target ??= _profiles['flat'];
    if (target == null) return false;

    // Le total affiché dans le rapport doit refléter toute la distance
    // couverte, même une fois le profil figé (convergé) -- seul
    // l'apprentissage de `metersPerStep` s'arrête alors, pas le décompte.
    target.totalDistance += distanceDelta;
    target.totalSteps += stepsDelta;

    if (!target.frozen) {
      target.metersPerStep = target.totalDistance / target.totalSteps;
      target.eventsSinceCheckpoint++;
      target.totalCalibrationEvents++;

      if (target.eventsSinceCheckpoint >= PedometerProfile.checkpointEvery) {
        _evaluateCheckpoint(target);
        target.eventsSinceCheckpoint = 0;
      }
    }

    _saveProfile(target);
    notifyListeners();
    return true;
  }

  /// Compare la longueur de pas courante au dernier checkpoint : si elle n'a
  /// pas dérivé de plus de [PedometerProfile.stabilityEpsilon] sur
  /// [PedometerProfile.freezeAfterStableCheckpoints] checkpoints d'affilée
  /// (et une fois passé le minimum d'échantillons), le profil se fige.
  void _evaluateCheckpoint(PedometerProfile p) {
    final prev = p.lastCheckpointMetersPerStep;
    p.lastCheckpointMetersPerStep = p.metersPerStep;

    if (prev == null ||
        prev == 0 ||
        p.totalCalibrationEvents <
            PedometerProfile.minEventsBeforeFreezeEligible) {
      return;
    }

    final relativeDelta = (p.metersPerStep - prev).abs() / prev;
    if (relativeDelta < PedometerProfile.stabilityEpsilon) {
      p.stableCheckpointStreak++;
    } else {
      p.stableCheckpointStreak = 0;
    }

    if (p.stableCheckpointStreak >=
        PedometerProfile.freezeAfterStableCheckpoints) {
      p.frozen = true;
    }
  }

  /// Sort un profil de l'état figé pour qu'il recommence à intégrer des
  /// mesures, sans effacer ses données accumulées.
  Future<void> unfreezeProfile(String id) async {
    final p = _profiles[id];
    if (p == null) return;
    p.frozen = false;
    p.stableCheckpointStreak = 0;
    await _saveProfile(p);
    notifyListeners();
  }

  Future<void> unfreezeAllProfiles() async {
    for (final p in _profiles.values) {
      p.frozen = false;
      p.stableCheckpointStreak = 0;
      await _saveProfile(p);
    }
    notifyListeners();
  }

  /// Remet un profil à ses valeurs d'usine (action destructive, confirmée
  /// côté UI).
  Future<void> resetProfile(String id) async {
    final p = _profiles[id];
    if (p == null) return;
    p.metersPerStep = p.defaultMetersPerStep;
    p.totalSteps = 0;
    p.totalDistance = 0;
    p.frozen = false;
    p.lastCheckpointMetersPerStep = null;
    p.eventsSinceCheckpoint = 0;
    p.stableCheckpointStreak = 0;
    p.totalCalibrationEvents = 0;
    await _saveProfile(p);
    notifyListeners();
  }

  Future<void> resetAllProfiles() async {
    for (final id in _profiles.keys) {
      await resetProfile(id);
    }
  }

  Future<void> _saveProfile(PedometerProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'pedometer_profile_${profile.id}', jsonEncode(profile.toJson()));
  }

  /// Estime la distance pour un nombre de pas donné et une pente supposée
  double estimateDistanceMeters(int stepsCount, {double assumedSlope = 0.0}) {
    PedometerProfile? target;
    for (var p in _profiles.values) {
      if (assumedSlope >= p.minSlope && assumedSlope < p.maxSlope) {
        target = p;
        break;
      }
    }
    target ??= _profiles['flat'];
    return stepsCount * (target?.metersPerStep ?? 0.75);
  }
}
