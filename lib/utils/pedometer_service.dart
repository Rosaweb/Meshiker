import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:shared_preferences/shared_preferences.dart';

class PedometerProfile {
  final String id;
  final double minSlope;
  final double maxSlope;
  double metersPerStep;
  int totalSteps;
  double totalDistance;

  PedometerProfile({
    required this.id,
    required this.minSlope,
    required this.maxSlope,
    required this.metersPerStep,
    this.totalSteps = 0,
    this.totalDistance = 0,
  });

  Map<String, dynamic> toJson() => {
    'metersPerStep': metersPerStep,
    'totalSteps': totalSteps,
    'totalDistance': totalDistance,
  };

  void updateFromJson(Map<String, dynamic> json) {
    metersPerStep = json['metersPerStep'] ?? metersPerStep;
    totalSteps = json['totalSteps'] ?? totalSteps;
    totalDistance = json['totalDistance'] ?? totalDistance;
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

  int get steps => _steps;

  /// Cumul de pas persistant, toutes activations confondues (survit aux
  /// redémarrages de l'app, contrairement à [steps] qui ne compte que
  /// depuis la dernière activation).
  int get totalStepsAllTime => _totalStepsAllTime;

  String get status => _status;
  bool get isActive => _isActive;
  bool get permissionDenied => _permissionDenied;
  bool get sensorUnavailable => _sensorUnavailable;

  /// Profils de calibrage (lecture seule), exposés pour l'écran de détail
  /// podomètre. Triés du plus raide en montée au plus raide en descente.
  List<PedometerProfile> get profiles => _profiles.values.toList(growable: false);

  /// Distance estimée pour les pas de la session courante (pente supposée
  /// plate, faute de mieux hors enregistrement).
  double get sessionDistanceMeters => estimateDistanceMeters(_steps);

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
      final jsonStr = prefs.getString('pedometer_profile_${profile.id}');
      if (jsonStr != null) {
        // Simple manual parsing to avoid dependencies for now
        // Format: metersPerStep|totalSteps|totalDistance
        final parts = jsonStr.split('|');
        if (parts.length == 3) {
          profile.metersPerStep = double.tryParse(parts[0]) ?? profile.metersPerStep;
          profile.totalSteps = int.tryParse(parts[1]) ?? profile.totalSteps;
          profile.totalDistance = double.tryParse(parts[2]) ?? profile.totalDistance;
        }
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

  /// Calibrage intelligent basé sur la pente
  void calibrateWithSlope(double distanceDelta, double elevationDelta, int stepsDelta) {
    if (stepsDelta <= 0 || distanceDelta <= 0) return;
    
    final slope = elevationDelta / distanceDelta;
    PedometerProfile? target;
    
    for (var p in _profiles.values) {
      if (slope >= p.minSlope && slope < p.maxSlope) {
        target = p;
        break;
      }
    }
    
    target ??= _profiles['flat'];
    
    if (target != null) {
      target.totalDistance += distanceDelta;
      target.totalSteps += stepsDelta;
      target.metersPerStep = target.totalDistance / target.totalSteps;
      _saveProfile(target);
    }
  }

  Future<void> _saveProfile(PedometerProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    final value = '${profile.metersPerStep}|${profile.totalSteps}|${profile.totalDistance}';
    await prefs.setString('pedometer_profile_${profile.id}', value);
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
