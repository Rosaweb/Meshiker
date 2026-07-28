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
  late Stream<StepCount> _stepCountStream;
  late Stream<PedestrianStatus> _pedestrianStatusStream;
  
  int _steps = 0;
  int _lastEventSteps = 0;
  String _status = '?';
  bool _isActive = false;
  bool _permissionDenied = false;

  int get steps => _steps;
  String get status => _status;
  bool get isActive => _isActive;
  bool get permissionDenied => _permissionDenied;

  final Map<String, PedometerProfile> _profiles = {
    'steep_uphill': PedometerProfile(id: 'steep_uphill', minSlope: 0.15, maxSlope: 1.0, metersPerStep: 0.5),
    'uphill': PedometerProfile(id: 'uphill', minSlope: 0.05, maxSlope: 0.15, metersPerStep: 0.65),
    'flat': PedometerProfile(id: 'flat', minSlope: -0.05, maxSlope: 0.05, metersPerStep: 0.75),
    'downhill': PedometerProfile(id: 'downhill', minSlope: -0.15, maxSlope: -0.05, metersPerStep: 0.85),
    'steep_downhill': PedometerProfile(id: 'steep_downhill', minSlope: -1.0, maxSlope: -0.15, metersPerStep: 0.7),
  };

  PedometerService() {
    _loadCalibration();
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
    }
    notifyListeners();
  }

  void _initPedometer() {
    _pedestrianStatusStream = Pedometer.pedestrianStatusStream;
    _pedestrianStatusStream.listen(_onPedestrianStatus).onError(_onPedestrianStatusError);

    _stepCountStream = Pedometer.stepCountStream;
    _stepCountStream.listen(_onStepCount).onError(_onStepCountError);
  }

  void _onStepCount(StepCount event) {
    if (_lastEventSteps > 0) {
      _steps += (event.steps - _lastEventSteps);
    }
    _lastEventSteps = event.steps;
    notifyListeners();
  }

  void _onPedestrianStatus(PedestrianStatus event) {
    _status = event.status;
    notifyListeners();
  }

  void _onPedestrianStatusError(error) {
    _status = 'Pedestrian Status not available';
  }

  void _onStepCountError(error) {
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
