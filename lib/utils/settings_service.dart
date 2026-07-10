import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum UnitSystem { metric, imperial }

enum MeasurementMode { none, fromGps, betweenPoints }

class AppSettings {
  final double barOpacity;
  final UnitSystem unitSystem;
  final bool useCelsius;
  final List<String> favoriteMapIds;

  AppSettings({
    required this.barOpacity,
    required this.unitSystem,
    required this.useCelsius,
    required this.favoriteMapIds,
  });
}

class SettingsService extends ChangeNotifier {
  late SharedPreferences _prefs;
  
  double _barOpacity = 0.6;
  UnitSystem _unitSystem = UnitSystem.metric;
  bool _useCelsius = true;
  bool _showScale = true;
  bool _reversePanels = false;
  bool _showAllWaypoints = true;
  double _waypointIconSize = 30.0;
  double _edgeSwipeWidth = 40.0;
  List<String> _favoriteMapIds = ['osm_standard', 'opentopo', 'cyclosm', 'google_sat', 'arcgis_sat'];

  // État de navigation
  String? _activeGpxName; // Trace actuellement suivie
  String? _navigationWaypointUuid; // Destination choisie

  MeasurementMode _measurementMode = MeasurementMode.none;
  ({double lat, double lon})? _measurePoint1;
  ({double lat, double lon})? _measurePoint2;

  double get barOpacity => _barOpacity;
  UnitSystem get unitSystem => _unitSystem;
  bool get useCelsius => _useCelsius;
  bool get showScale => _showScale;
  bool get reversePanels => _reversePanels;
  bool get showAllWaypoints => _showAllWaypoints;
  double get waypointIconSize => _waypointIconSize;
  double get edgeSwipeWidth => _edgeSwipeWidth;
  List<String> get favoriteMapIds => _favoriteMapIds;
  String? get activeGpxName => _activeGpxName;
  String? get navigationWaypointUuid => _navigationWaypointUuid;
  MeasurementMode get measurementMode => _measurementMode;
  ({double lat, double lon})? get measurePoint1 => _measurePoint1;
  ({double lat, double lon})? get measurePoint2 => _measurePoint2;

  // Index de la carte actuellement affichée parmi les favoris
  int _currentMapIndex = 0;
  int get currentMapIndex => _currentMapIndex;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _barOpacity = _prefs.getDouble('bar_opacity') ?? 0.6;
    _unitSystem = UnitSystem.values[_prefs.getInt('unit_system') ?? 0];
    _useCelsius = _prefs.getBool('use_celsius') ?? true;
    _showScale = _prefs.getBool('show_scale') ?? true;
    _reversePanels = _prefs.getBool('reverse_panels') ?? false;
    _showAllWaypoints = _prefs.getBool('show_all_waypoints') ?? true;
    _waypointIconSize = _prefs.getDouble('waypoint_icon_size') ?? 30.0;
    _edgeSwipeWidth = _prefs.getDouble('edge_swipe_width') ?? 40.0;
    _favoriteMapIds = _prefs.getStringList('favorite_maps') ?? ['osm_standard', 'opentopo', 'cyclosm', 'google_sat', 'arcgis_sat'];
    
    _activeGpxName = _prefs.getString('active_gpx');
    _navigationWaypointUuid = _prefs.getString('nav_wp_uuid');
    notifyListeners();
  }

  void setMeasurementMode(MeasurementMode mode) {
    _measurementMode = mode;
    _measurePoint1 = null;
    _measurePoint2 = null;
    notifyListeners();
  }

  void setMeasurePoint1(double lat, double lon) {
    _measurePoint1 = (lat: lat, lon: lon);
    notifyListeners();
  }

  void setMeasurePoint2(double lat, double lon) {
    _measurePoint2 = (lat: lat, lon: lon);
    notifyListeners();
  }

  void clearMeasurement() {
    _measurementMode = MeasurementMode.none;
    _measurePoint1 = null;
    _measurePoint2 = null;
    notifyListeners();
  }

  Future<void> setActiveGpx(String? name) async {
    _activeGpxName = name;
    if (name == null) {
      await _prefs.remove('active_gpx');
    } else {
      await _prefs.setString('active_gpx', name);
    }
    notifyListeners();
  }

  Future<void> setNavigationWaypoint(String? uuid) async {
    _navigationWaypointUuid = uuid;
    if (uuid == null) {
      await _prefs.remove('nav_wp_uuid');
    } else {
      await _prefs.setString('nav_wp_uuid', uuid);
    }
    notifyListeners();
  }

  Future<void> setShowAllWaypoints(bool value) async {
    _showAllWaypoints = value;
    await _prefs.setBool('show_all_waypoints', value);
    notifyListeners();
  }

  Future<void> setWaypointIconSize(double value) async {
    _waypointIconSize = value;
    await _prefs.setDouble('waypoint_icon_size', value);
    notifyListeners();
  }

  Future<void> setEdgeSwipeWidth(double value) async {
    _edgeSwipeWidth = value;
    await _prefs.setDouble('edge_swipe_width', value);
    notifyListeners();
  }

  Future<void> setFavoriteMaps(List<String> ids) async {
    _favoriteMapIds = ids;
    await _prefs.setStringList('favorite_maps', ids);
    _currentMapIndex = 0; // Reset si la liste change
    notifyListeners();
  }

  void cycleMap() {
    if (_favoriteMapIds.isEmpty) return;
    _currentMapIndex = (_currentMapIndex + 1) % _favoriteMapIds.length;
    notifyListeners();
  }

  Future<void> setReversePanels(bool value) async {
    _reversePanels = value;
    await _prefs.setBool('reverse_panels', value);
    notifyListeners();
  }

  Future<void> setShowScale(bool value) async {
    _showScale = value;
    await _prefs.setBool('show_scale', value);
    notifyListeners();
  }

  Future<void> setBarOpacity(double value) async {
    _barOpacity = value;
    await _prefs.setDouble('bar_opacity', value);
    notifyListeners();
  }

  Future<void> setUnitSystem(UnitSystem system) async {
    _unitSystem = system;
    await _prefs.setInt('unit_system', system.index);
    notifyListeners();
  }

  Future<void> setTemperatureUnit(bool celsius) async {
    _useCelsius = celsius;
    await _prefs.setBool('use_celsius', celsius);
    notifyListeners();
  }
}
