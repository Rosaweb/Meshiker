import 'dart:ffi';
import 'package:latlong2/latlong.dart';
import '../models/gps_point.dart';
import 'dart:io';

/// Modèle de retour d'un point apparié par Valhalla (Meili).
class MatchedPoint {
  final LatLng point;
  final int? osmWayId;
  final String? osmNodeId;
  final double confidence;
  final double distanceMeters;

  MatchedPoint({
    required this.point,
    this.osmWayId,
    this.osmNodeId,
    required this.confidence,
    required this.distanceMeters,
  });

  bool get isConfident => confidence > 0.7 && distanceMeters < 30.0;
}

/// Service de liaison avec le moteur natif Valhalla (C++).
class ValhallaService {
  const ValhallaService._();

  static DynamicLibrary? _lib;

  static DynamicLibrary get _library {
    if (_lib != null) return _lib!;
    if (Platform.isAndroid) {
      _lib = DynamicLibrary.open('libvalhalla.so');
    } else if (Platform.isWindows) {
      _lib = DynamicLibrary.open('valhalla.dll');
    } else {
      throw UnsupportedError('Platform not supported');
    }
    return _lib!;
  }

  /// Projette une trace brute sur le réseau OSM local.
  static Future<List<MatchedPoint>> matchTrace(List<PointGPS> points) async {
    try {
      // Tentative de chargement de la bibliothèque native
      // final library = _library; 
      // TODO: Implémenter les bindings FFI réels une fois libvalhalla.so présente
      
      // Simulation pour le moment si lib non trouvée
      return points.map((p) => MatchedPoint(
        point: LatLng(p.latitude, p.longitude),
        confidence: 0.0, 
        distanceMeters: 999,
      )).toList();
    } catch (e) {
      // Fallback gracieux si la lib native n'est pas chargée
      return points.map((p) => MatchedPoint(
        point: LatLng(p.latitude, p.longitude),
        confidence: 0.0,
        distanceMeters: 999,
      )).toList();
    }
  }
}

