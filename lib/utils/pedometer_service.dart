import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';

class PedometerService extends ChangeNotifier {
  late Stream<StepCount> _stepCountStream;
  int _stepsAtStart = 0;
  int _currentSteps = 0;
  bool _isActive = false;

  int get steps => _currentSteps;
  bool get isActive => _isActive;

  void togglePedometer() async {
    if (_isActive) {
      _isActive = false;
      _currentSteps = 0;
      _stepsAtStart = 0;
      notifyListeners();
    } else {
      if (await Permission.activityRecognition.request().isGranted) {
        _isActive = true;
        _initPedometer();
        notifyListeners();
      }
    }
  }

  void _initPedometer() {
    _stepCountStream = Pedometer.stepCountStream;
    _stepCountStream.listen(_onStepCount).onError(_onStepCountError);
  }

  void _onStepCount(StepCount event) {
    if (!_isActive) return;

    if (_stepsAtStart == 0) {
      _stepsAtStart = event.steps;
    }
    
    _currentSteps = event.steps - _stepsAtStart;
    notifyListeners();
  }

  void _onStepCountError(error) {
    debugPrint('Pedometer Error: $error');
  }
}
