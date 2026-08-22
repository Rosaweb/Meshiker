import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../map/osm_poi_categories.dart';

enum UnitSystem { metric, imperial }

enum MeasurementMode { none, fromGps, betweenPoints }

enum MapCreationStep { none, selectOrigin, stretchArea, adjustArea, finalize }

/// Mode de positionnement de la carte à l'ouverture de l'application :
/// soit on reprend la dernière position affichée avant fermeture, soit on
/// revient toujours à un point fixe choisi par l'utilisateur.
enum MapStartupMode { lastPosition, customPoint }

enum DisplayMode { gpx, mesh }

/// Écran d'où "Localiser sur la carte" a été déclenché depuis la fenêtre
/// contextuelle d'un waypoint : détermine quel écran le bouton "Retour"
/// flottant de la carte doit rouvrir derrière la fiche du waypoint.
enum WaypointLocateOrigin { map, trackManager, roadmap }

/// Niveau de grossissement du texte appliqué à toute l'application
/// (accessibilité). `normal` est la taille par défaut (la plus petite) ;
/// `large`/`extraLarge` sont les deux niveaux de grossissement.
enum FontScaleLevel { normal, large, extraLarge }

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
  double _mainMenuOpacity = 0.6;
  UnitSystem _unitSystem = UnitSystem.metric;
  bool _useCelsius = true;
  bool _showScale = true;
  bool _reversePanels = false;
  bool _showAllWaypoints = true;
  bool _showAllGpx = true;
  DisplayMode _displayMode = DisplayMode.gpx;
  bool _showGpxWaypoints = true;
  bool _locationEnabled = true;
  // Couleur d'accent appliquée aux cadres/titres/icônes de l'écran Outils
  // de navigation (et, à terme, à d'autres éléments des paramètres).
  // Colors.greenAccent par défaut.
  int _accentColorHex = 0xFF69F0AE;
  double _waypointIconSize = 30.0;
  FontScaleLevel _fontScaleLevel = FontScaleLevel.normal;
  bool _showOsmPois = false;
  Set<String> _enabledOsmPoiCategoryIds = kOsmPoiCategories.map((c) => c.id).toSet();
  bool _useWaypointCategoryIcons = true;

  // Visibilité des éléments du volet de navigation
  bool _navShowSpeed = true;
  bool _navShowDailyDist = true;
  bool _navShowTraceDist = true;
  bool _navShowGpsAccuracy = true;
  bool _navShowSatellites = true;
  bool _navShowPedometer = true;
  bool _navShowNextWaypoint = true;
  bool _navShowDestination = true;
  bool _navShowMeasureTools = true;
  double _edgeSwipeWidth = 40.0;
  String? _gpxStoragePath;
  String? _recordingSubPath; // Nouveau : dossier d'enregistrement par défaut
  double _tileCacheLimitMb = 500.0;
  bool _wifiOnlyDownload = true;
  List<String> _favoriteMapIds = ['osm_standard', 'opentopo', 'cyclosm', 'google_sat', 'arcgis_sat'];

  // État de navigation
  List<String> _activeGpxNames = []; // Traces actuellement suivies
  String? _navigationWaypointUuid; // Destination choisie
  bool _waypointSelectionMode = false;
  String? _roadmapTraceName; // Trace unique chargée dans le Roadmap

  // État de création de carte hors ligne
  MapCreationStep _mapCreationStep = MapCreationStep.none;
  ({double lat, double lon})? _mapOrigin;
  ({double lat, double lon})? _mapTarget; // Le point opposé (croix rouge)
  int _minZoomDownload = 10;
  int _maxZoomDownload = 15;

  MeasurementMode _measurementMode = MeasurementMode.none;
  ({double lat, double lon})? _measurePoint1;
  ({double lat, double lon})? _measurePoint2;

  // Position de la carte à l'ouverture de l'application.
  MapStartupMode _mapStartupMode = MapStartupMode.lastPosition;
  double? _lastMapLat;
  double? _lastMapLon;
  double? _lastMapZoom;
  double? _customMapLat;
  double? _customMapLon;
  double? _customMapZoom;
  bool _pickingStartupCenter = false;

  // Fond de carte utilisé pour générer les aperçus de traces GPX (Track
  // Manager, écran de partage, etc). `null` = suit le fond de carte actif
  // de la carte principale (comportement historique).
  String? _tracePreviewMapSourceId;

  // "Localiser sur la carte" depuis la fenêtre contextuelle d'un waypoint :
  // uuid du waypoint concerné tant que le bouton "Retour" flottant est
  // affiché sur la carte, null sinon.
  String? _locatingWaypointUuid;
  WaypointLocateOrigin _locatingWaypointOrigin = WaypointLocateOrigin.map;

  // "Localiser sur la carte" depuis la fiche d'une trace GPX : même
  // principe, mais processus volontairement distinct de "Naviguer"
  // (roadmapTraceName) pour ne jamais perturber une trace de navigation
  // déjà en cours pendant qu'on prévisualise une autre trace. On retient
  // si la trace était déjà affichée (activeGpxNames) avant le déclenchement
  // pour savoir si on doit la retirer à la fermeture du bouton "Retour".
  String? _locatingTraceUuid;
  String? _locatingTraceName;
  bool _locatingTraceWasAlreadyActive = false;

  double get barOpacity => _barOpacity;
  double get mainMenuOpacity => _mainMenuOpacity;
  UnitSystem get unitSystem => _unitSystem;
  bool get useCelsius => _useCelsius;
  bool get showScale => _showScale;
  bool get reversePanels => _reversePanels;
  bool get showAllWaypoints => _showAllWaypoints;
  DisplayMode get displayMode => _displayMode;
  bool get showAllGpx => _showAllGpx;
  bool get showMesh => _displayMode == DisplayMode.mesh;
  bool get showGpxWaypoints => _showGpxWaypoints;
  bool get locationEnabled => _locationEnabled;
  Color get accentColor => Color(_accentColorHex);
  double get waypointIconSize => _waypointIconSize;
  FontScaleLevel get fontScaleLevel => _fontScaleLevel;
  bool get showOsmPois => _showOsmPois;
  Set<String> get enabledOsmPoiCategoryIds => _enabledOsmPoiCategoryIds;
  bool get useWaypointCategoryIcons => _useWaypointCategoryIcons;
  double get fontScale {
    switch (_fontScaleLevel) {
      case FontScaleLevel.normal:
        return 1.0;
      case FontScaleLevel.large:
        return 1.15;
      case FontScaleLevel.extraLarge:
        return 1.3;
    }
  }

  bool get navShowSpeed => _navShowSpeed;
  bool get navShowDailyDist => _navShowDailyDist;
  bool get navShowTraceDist => _navShowTraceDist;
  bool get navShowGpsAccuracy => _navShowGpsAccuracy;
  bool get navShowSatellites => _navShowSatellites;
  bool get navShowPedometer => _navShowPedometer;
  bool get navShowNextWaypoint => _navShowNextWaypoint;
  bool get navShowDestination => _navShowDestination;
  bool get navShowMeasureTools => _navShowMeasureTools;
  double get edgeSwipeWidth => _edgeSwipeWidth;
  String? get gpxStoragePath => _gpxStoragePath;
  String? get recordingSubPath => _recordingSubPath;
  double get tileCacheLimitMb => _tileCacheLimitMb;
  bool get wifiOnlyDownload => _wifiOnlyDownload;
  List<String> get favoriteMapIds => _favoriteMapIds;
  List<String> get activeGpxNames => _activeGpxNames;
  String? get navigationWaypointUuid => _navigationWaypointUuid;
  bool get waypointSelectionMode => _waypointSelectionMode;
  String? get roadmapTraceName => _roadmapTraceName;
  final MapCreationStep _mapCreationStepProp = MapCreationStep.none;
  MapCreationStep get mapCreationStep => _mapCreationStep;
  ({double lat, double lon})? get mapOrigin => _mapOrigin;
  ({double lat, double lon})? get mapTarget => _mapTarget;
  int get minZoomDownload => _minZoomDownload;
  int get maxZoomDownload => _maxZoomDownload;
  MeasurementMode get measurementMode => _measurementMode;
  ({double lat, double lon})? get measurePoint1 => _measurePoint1;
  ({double lat, double lon})? get measurePoint2 => _measurePoint2;

  MapStartupMode get mapStartupMode => _mapStartupMode;
  String? get tracePreviewMapSourceId => _tracePreviewMapSourceId;
  bool get pickingStartupCenter => _pickingStartupCenter;
  String? get locatingWaypointUuid => _locatingWaypointUuid;
  WaypointLocateOrigin get locatingWaypointOrigin => _locatingWaypointOrigin;
  String? get locatingTraceUuid => _locatingTraceUuid;

  ({double lat, double lon, double zoom})? get lastMapPosition =>
      (_lastMapLat != null && _lastMapLon != null && _lastMapZoom != null)
          ? (lat: _lastMapLat!, lon: _lastMapLon!, zoom: _lastMapZoom!)
          : null;

  ({double lat, double lon, double zoom})? get customMapCenter =>
      (_customMapLat != null && _customMapLon != null && _customMapZoom != null)
          ? (lat: _customMapLat!, lon: _customMapLon!, zoom: _customMapZoom!)
          : null;

  // Index de la carte actuellement affichée parmi les favoris
  int _currentMapIndex = 0;
  int get currentMapIndex => _currentMapIndex;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _barOpacity = _prefs.getDouble('bar_opacity') ?? 0.6;
    _mainMenuOpacity = _prefs.getDouble('main_menu_opacity') ?? 0.6;
    _unitSystem = UnitSystem.values[_prefs.getInt('unit_system') ?? 0];
    _useCelsius = _prefs.getBool('use_celsius') ?? true;
    _showScale = _prefs.getBool('show_scale') ?? true;
    _reversePanels = _prefs.getBool('reverse_panels') ?? false;
    _showAllWaypoints = _prefs.getBool('show_all_waypoints') ?? true;
    _showAllGpx = _prefs.getBool('show_all_gpx') ?? true;
    // On force le mode GPX au démarrage (ne pas charger depuis les préférences)
    _displayMode = DisplayMode.gpx;
    _showGpxWaypoints = _prefs.getBool('show_gpx_waypoints') ?? true;
    _locationEnabled = _prefs.getBool('location_enabled') ?? true;
    _accentColorHex = _prefs.getInt('accent_color') ?? 0xFF69F0AE;
    _waypointIconSize = _prefs.getDouble('waypoint_icon_size') ?? 30.0;
    _fontScaleLevel = FontScaleLevel.values[_prefs.getInt('font_scale_level') ?? 0];
    _showOsmPois = _prefs.getBool('show_osm_pois') ?? false;
    final enabledOsmCats = _prefs.getStringList('enabled_osm_poi_categories');
    _enabledOsmPoiCategoryIds = enabledOsmCats != null
        ? enabledOsmCats.toSet()
        : kOsmPoiCategories.map((c) => c.id).toSet();
    _useWaypointCategoryIcons = _prefs.getBool('use_waypoint_category_icons') ?? true;

    _navShowSpeed = _prefs.getBool('nav_show_speed') ?? true;
    _navShowDailyDist = _prefs.getBool('nav_show_daily_dist') ?? true;
    _navShowTraceDist = _prefs.getBool('nav_show_trace_dist') ?? true;
    _navShowGpsAccuracy = _prefs.getBool('nav_show_gps_accuracy') ?? true;
    _navShowSatellites = _prefs.getBool('nav_show_satellites') ?? true;
    _navShowPedometer = _prefs.getBool('nav_show_pedometer') ?? true;
    _navShowNextWaypoint = _prefs.getBool('nav_show_next_waypoint') ?? true;
    _navShowDestination = _prefs.getBool('nav_show_destination') ?? true;
    _navShowMeasureTools = _prefs.getBool('nav_show_measure_tools') ?? true;

    _edgeSwipeWidth = _prefs.getDouble('edge_swipe_width') ?? 40.0;
    _gpxStoragePath = _prefs.getString('gpx_storage_path');
    _recordingSubPath = _prefs.getString('recording_sub_path');
    _tileCacheLimitMb = _prefs.getDouble('tile_cache_limit_mb') ?? 500.0;
    _wifiOnlyDownload = _prefs.getBool('wifi_only_download') ?? true;
    _favoriteMapIds = _prefs.getStringList('favorite_maps') ?? ['osm_standard', 'opentopo', 'cyclosm', 'google_sat', 'arcgis_sat'];
    
    _activeGpxNames = _prefs.getStringList('active_gpx_list') ?? [];
    // Migration depuis l'ancien format unique
    final oldActive = _prefs.getString('active_gpx');
    if (oldActive != null && _activeGpxNames.isEmpty) {
      _activeGpxNames = [oldActive];
      await _prefs.setStringList('active_gpx_list', _activeGpxNames);
      await _prefs.remove('active_gpx');
    }

    _navigationWaypointUuid = _prefs.getString('nav_wp_uuid');
    _roadmapTraceName = _prefs.getString('roadmap_trace_name');

    _mapStartupMode =
        MapStartupMode.values[_prefs.getInt('map_startup_mode') ?? 0];
    _tracePreviewMapSourceId = _prefs.getString('trace_preview_map_source_id');
    _lastMapLat = _prefs.getDouble('last_map_lat');
    _lastMapLon = _prefs.getDouble('last_map_lon');
    _lastMapZoom = _prefs.getDouble('last_map_zoom');
    _customMapLat = _prefs.getDouble('custom_map_lat');
    _customMapLon = _prefs.getDouble('custom_map_lon');
    _customMapZoom = _prefs.getDouble('custom_map_zoom');
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

  Future<void> setGpxStoragePath(String? path) async {
    _gpxStoragePath = path;
    if (path == null) {
      await _prefs.remove('gpx_storage_path');
      await setRecordingSubPath(null); // Reset sub-path if root changes
    } else {
      await _prefs.setString('gpx_storage_path', path);
    }
    notifyListeners();
  }

  Future<void> setRecordingSubPath(String? path) async {
    _recordingSubPath = path;
    if (path == null) {
      await _prefs.remove('recording_sub_path');
    } else {
      await _prefs.setString('recording_sub_path', path);
    }
    notifyListeners();
  }

  Future<void> toggleActiveGpx(String name) async {
    if (_activeGpxNames.contains(name)) {
      _activeGpxNames.remove(name);
    } else {
      _activeGpxNames.add(name);
    }
    await _prefs.setStringList('active_gpx_list', _activeGpxNames);
    notifyListeners();
  }

  Future<void> setActiveGpxList(List<String> names) async {
    _activeGpxNames = List.from(names);
    await _prefs.setStringList('active_gpx_list', _activeGpxNames);
    notifyListeners();
  }

  Future<void> clearActiveGpx() async {
    _activeGpxNames.clear();
    await _prefs.remove('active_gpx_list');
    notifyListeners();
  }

  Future<void> setNavigationWaypoint(String? uuid) async {
    _navigationWaypointUuid = uuid;
    _waypointSelectionMode = false; // Désactive le mode sélection une fois choisi
    if (uuid == null) {
      await _prefs.remove('nav_wp_uuid');
    } else {
      await _prefs.setString('nav_wp_uuid', uuid);
    }
    notifyListeners();
  }

  void setWaypointSelectionMode(bool value) {
    _waypointSelectionMode = value;
    notifyListeners();
  }

  Future<void> setRoadmapTraceName(String? name) async {
    _roadmapTraceName = name;
    if (name == null) {
      await _prefs.remove('roadmap_trace_name');
    } else {
      await _prefs.setString('roadmap_trace_name', name);
    }
    notifyListeners();
  }

  Future<void> setShowAllWaypoints(bool value) async {
    _showAllWaypoints = value;
    await _prefs.setBool('show_all_waypoints', value);
    notifyListeners();
  }

  Future<void> setDisplayMode(DisplayMode mode) async {
    _displayMode = mode;
    await _prefs.setInt('display_mode', mode.index);
    notifyListeners();
  }

  Future<void> setShowAllGpx(bool value) async {
    _showAllGpx = value;
    await _prefs.setBool('show_all_gpx', value);
    notifyListeners();
  }

  Future<void> setShowGpxWaypoints(bool value) async {
    _showGpxWaypoints = value;
    await _prefs.setBool('show_gpx_waypoints', value);
    notifyListeners();
  }

  Future<void> setLocationEnabled(bool value) async {
    _locationEnabled = value;
    await _prefs.setBool('location_enabled', value);
    notifyListeners();
  }

  Future<void> setAccentColor(Color color) async {
    _accentColorHex = color.toARGB32();
    await _prefs.setInt('accent_color', _accentColorHex);
    notifyListeners();
  }

  Future<void> setNavVisibility(String key, bool value) async {
    switch (key) {
      case 'speed': _navShowSpeed = value; break;
      case 'dailyDist': _navShowDailyDist = value; break;
      case 'traceDist': _navShowTraceDist = value; break;
      case 'gpsAccuracy': _navShowGpsAccuracy = value; break;
      case 'satellites': _navShowSatellites = value; break;
      case 'pedometer': _navShowPedometer = value; break;
      case 'nextWaypoint': _navShowNextWaypoint = value; break;
      case 'destination': _navShowDestination = value; break;
      case 'measureTools': _navShowMeasureTools = value; break;
    }
    await _prefs.setBool('nav_show_$key', value);
    notifyListeners();
  }

  Future<void> setWaypointIconSize(double value) async {
    _waypointIconSize = value;
    await _prefs.setDouble('waypoint_icon_size', value);
    notifyListeners();
  }

  Future<void> setFontScaleLevel(FontScaleLevel level) async {
    _fontScaleLevel = level;
    await _prefs.setInt('font_scale_level', level.index);
    notifyListeners();
  }

  Future<void> setShowOsmPois(bool value) async {
    _showOsmPois = value;
    await _prefs.setBool('show_osm_pois', value);
    notifyListeners();
  }

  Future<void> setEnabledOsmPoiCategories(Set<String> ids) async {
    _enabledOsmPoiCategoryIds = ids;
    await _prefs.setStringList('enabled_osm_poi_categories', ids.toList());
    notifyListeners();
  }

  Future<void> setUseWaypointCategoryIcons(bool value) async {
    _useWaypointCategoryIcons = value;
    await _prefs.setBool('use_waypoint_category_icons', value);
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
    // On s'assure que l'index reste valide si la liste a rétréci
    if (_favoriteMapIds.isNotEmpty) {
      _currentMapIndex = _currentMapIndex % _favoriteMapIds.length;
    } else {
      _currentMapIndex = 0;
    }
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

  Future<void> setMainMenuOpacity(double value) async {
    _mainMenuOpacity = value;
    await _prefs.setDouble('main_menu_opacity', value);
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

  Future<void> setTileCacheLimitMb(double value) async {
    _tileCacheLimitMb = value;
    await _prefs.setDouble('tile_cache_limit_mb', value);
    notifyListeners();
  }

  Future<void> setWifiOnlyDownload(bool value) async {
    _wifiOnlyDownload = value;
    await _prefs.setBool('wifi_only_download', value);
    notifyListeners();
  }

  void startMapCreation() {
    _mapCreationStep = MapCreationStep.selectOrigin;
    _mapOrigin = null;
    _mapTarget = null;
    _minZoomDownload = 10;
    _maxZoomDownload = 15;
    notifyListeners();
  }

  void cancelMapCreation() {
    _mapCreationStep = MapCreationStep.none;
    _mapOrigin = null;
    _mapTarget = null;
    notifyListeners();
  }

  void validateOrigin(double lat, double lon) {
    _mapOrigin = (lat: lat, lon: lon);
    _mapCreationStep = MapCreationStep.stretchArea;
    notifyListeners();
  }

  void validateArea(double lat, double lon) {
    _mapTarget = (lat: lat, lon: lon);
    _mapCreationStep = MapCreationStep.adjustArea;
    notifyListeners();
  }

  void updateMapTarget(double lat, double lon) {
    _mapTarget = (lat: lat, lon: lon);
    notifyListeners();
  }

  void finalizeArea() {
    _mapCreationStep = MapCreationStep.finalize;
    notifyListeners();
  }

  void adjustArea(double dLat, double dLon, {bool fromOrigin = false}) {
    if (fromOrigin && _mapOrigin != null) {
      _mapOrigin = (lat: _mapOrigin!.lat + dLat, lon: _mapOrigin!.lon + dLon);
    } else if (!fromOrigin && _mapTarget != null) {
      _mapTarget = (lat: _mapTarget!.lat + dLat, lon: _mapTarget!.lon + dLon);
    }
    notifyListeners();
  }

  void setZoomRange(int min, int max) {
    _minZoomDownload = min;
    _maxZoomDownload = max;
    notifyListeners();
  }

  Future<void> setMapStartupMode(MapStartupMode mode) async {
    _mapStartupMode = mode;
    await _prefs.setInt('map_startup_mode', mode.index);
    notifyListeners();
  }

  /// [sourceId] doit être un id de [availableSources], ou `null` pour
  /// revenir au comportement par défaut (suivre le fond de carte actif).
  Future<void> setTracePreviewMapSourceId(String? sourceId) async {
    _tracePreviewMapSourceId = sourceId;
    if (sourceId == null) {
      await _prefs.remove('trace_preview_map_source_id');
    } else {
      await _prefs.setString('trace_preview_map_source_id', sourceId);
    }
    notifyListeners();
  }

  /// Enregistre la position de la carte au moment où l'application passe
  /// en arrière-plan, pour la restaurer à la prochaine ouverture (mode
  /// [MapStartupMode.lastPosition]).
  Future<void> setLastMapPosition(double lat, double lon, double zoom) async {
    _lastMapLat = lat;
    _lastMapLon = lon;
    _lastMapZoom = zoom;
    await _prefs.setDouble('last_map_lat', lat);
    await _prefs.setDouble('last_map_lon', lon);
    await _prefs.setDouble('last_map_zoom', zoom);
  }

  /// Démarre le mode sélection du point d'ouverture personnalisé : la carte
  /// affiche une croix rouge centrale et un bandeau simplifié
  /// (annuler/valider), cf. MapScreen.
  void startPickStartupCenter() {
    _pickingStartupCenter = true;
    notifyListeners();
  }

  Future<void> validateStartupCenter(double lat, double lon, double zoom) async {
    _customMapLat = lat;
    _customMapLon = lon;
    _customMapZoom = zoom;
    _pickingStartupCenter = false;
    await _prefs.setDouble('custom_map_lat', lat);
    await _prefs.setDouble('custom_map_lon', lon);
    await _prefs.setDouble('custom_map_zoom', zoom);
    notifyListeners();
  }

  void cancelPickStartupCenter() {
    _pickingStartupCenter = false;
    notifyListeners();
  }

  /// Démarre le mode "Localiser sur la carte" pour le waypoint [uuid] :
  /// affiche le bouton "Retour" flottant sur MapScreen. [origin] indique
  /// quel écran doit être rouvert derrière la fenêtre contextuelle quand
  /// on presse ce bouton (Track Manager, Roadmap, ou rien de plus si on
  /// venait déjà directement de la carte).
  void startLocateWaypoint(String uuid, {WaypointLocateOrigin origin = WaypointLocateOrigin.map}) {
    _locatingWaypointUuid = uuid;
    _locatingWaypointOrigin = origin;
    notifyListeners();
  }

  /// Referme le bouton "Retour", que ce soit parce qu'on l'a pressé (pour
  /// rouvrir la fenêtre contextuelle) ou parce que l'utilisateur a fait
  /// autre chose qu'un zoom/déplacement sur la carte.
  void dismissLocateWaypointBackButton() {
    _locatingWaypointUuid = null;
    notifyListeners();
  }

  /// Démarre le mode "Localiser sur la carte" pour la trace [traceName]
  /// (uuid [traceUuid]) : affiche le bouton "Retour" flottant sur MapScreen,
  /// et ajoute temporairement la trace à [activeGpxNames] si elle n'y était
  /// pas déjà, pour qu'elle apparaisse sur la carte. Mutuellement exclusif
  /// avec le mode "Localiser" d'un waypoint.
  Future<void> startLocateTrace(String traceUuid, String traceName) async {
    _locatingTraceWasAlreadyActive = _activeGpxNames.contains(traceName);
    if (!_locatingTraceWasAlreadyActive) {
      _activeGpxNames.add(traceName);
      await _prefs.setStringList('active_gpx_list', _activeGpxNames);
    }
    _locatingTraceUuid = traceUuid;
    _locatingTraceName = traceName;
    _locatingWaypointUuid = null;
    notifyListeners();
  }

  /// Referme le bouton "Retour" d'une trace localisée, et retire la trace
  /// de [activeGpxNames] si elle n'y était affichée que temporairement pour
  /// cette prévisualisation.
  Future<void> dismissLocateTraceBackButton() async {
    if (_locatingTraceUuid == null) return;
    if (!_locatingTraceWasAlreadyActive && _locatingTraceName != null) {
      _activeGpxNames.remove(_locatingTraceName);
      await _prefs.setStringList('active_gpx_list', _activeGpxNames);
    }
    _locatingTraceUuid = null;
    _locatingTraceName = null;
    notifyListeners();
  }
}
