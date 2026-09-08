import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../map/osm_poi_categories.dart';

enum UnitSystem { metric, imperial }

/// Couleur du marqueur de position (flèche de cap / point) sur la carte.
enum LocationMarkerColor { blue, red }

extension LocationMarkerColorX on LocationMarkerColor {
  Color get color => switch (this) {
        LocationMarkerColor.blue => Colors.blue,
        LocationMarkerColor.red => Colors.red,
      };

  String get label => switch (this) {
        LocationMarkerColor.blue => 'Bleu',
        LocationMarkerColor.red => 'Rouge',
      };
}

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

/// Durée d'immobilité avant qu'un arrêt soit considéré comme une "pause"
/// par `StationaryDetector` (cf. `spec-filtrage-gps-centralise.md` §6.1).
/// En dessous, ce n'est pas une pause, juste du bruit GPS filtré
/// normalement.
enum StationaryWindowPreset { s30, min1, min2, min3 }

extension StationaryWindowPresetX on StationaryWindowPreset {
  Duration get duration => switch (this) {
        StationaryWindowPreset.s30 => const Duration(seconds: 30),
        StationaryWindowPreset.min1 => const Duration(minutes: 1),
        StationaryWindowPreset.min2 => const Duration(minutes: 2),
        StationaryWindowPreset.min3 => const Duration(minutes: 3),
      };

  String get label => switch (this) {
        StationaryWindowPreset.s30 => '30 secondes',
        StationaryWindowPreset.min1 => '1 minute',
        StationaryWindowPreset.min2 => '2 minutes',
        StationaryWindowPreset.min3 => '3 minutes',
      };
}

/// Rayon utilisé par `StationaryDetector` pour regrouper les fixes d'une
/// fenêtre comme "au même endroit" (cf. `spec-filtrage-gps-centralise.md`
/// §6.1).
enum StationaryRadiusPreset { m10, m25, m50 }

extension StationaryRadiusPresetX on StationaryRadiusPreset {
  double get meters => switch (this) {
        StationaryRadiusPreset.m10 => 10.0,
        StationaryRadiusPreset.m25 => 25.0,
        StationaryRadiusPreset.m50 => 50.0,
      };

  String get label => switch (this) {
        StationaryRadiusPreset.m10 => '10 mètres',
        StationaryRadiusPreset.m25 => '25 mètres',
        StationaryRadiusPreset.m50 => '50 mètres',
      };
}

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
  // Système d'unités unique pour toute l'application, météo comprise :
  // transmis tel quel en `unitsSystem` à la Weather API (bascule tout le
  // payload, aucune conversion côté client). Remplace l'ancien toggle
  // Celsius/Fahrenheit.
  UnitSystem _unitSystem = UnitSystem.metric;
  bool _showScale = true;
  // Cercle matérialisant le périmètre d'imprécision GPS autour de la
  // position, quand la précision annoncée dépasse
  // [accuracyCircleThresholdMeters]. Désactivé par défaut.
  bool _showAccuracyCircle = false;

  /// En dessous de ce rayon (m), l'imprécision reste évaluable à vue et le
  /// cercle n'est pas tracé même si l'option est active. Valeur provisoire,
  /// ajustable ultérieurement.
  static const accuracyCircleThresholdMeters = 25.0;
  bool _reversePanels = false;
  bool _showAllWaypoints = true;
  // Volontairement jamais persisté ni initialisé à true au démarrage :
  // "afficher l'intégralité des waypoints" (appui long sur le bouton, cf.
  // showAllWaypoints/roadmapTraceName pour le mode normal) est une
  // consultation ponctuelle, pas une préférence durable.
  bool _showEveryWaypoint = false;
  bool _showAllGpx = true;
  DisplayMode _displayMode = DisplayMode.gpx;
  bool _showGpxWaypoints = true;
  bool _flattenWaypointFolders = false;

  // Annonces vocales des waypoints en cours de navigation (géofencing local,
  // sans IA — cf. spec-assistant-vocal-ia.md §2). Deux contextes indépendants :
  // "waypoint manager" (waypoints affichés sur la carte) et "roadmap" (trace
  // chargée pour la navigation) — mêmes réglages, activables séparément.
  bool _waypointAnnouncementsEnabled = false;
  bool _waypointAnnounceOnApproach = true;
  bool _waypointAnnounceOnSpot = true;
  double _waypointAnnounceDistanceMeters = 300.0;
  bool _waypointAnnounceTitle = true;
  bool _waypointAnnounceType = true;
  bool _waypointAnnounceDescription = false;

  bool _roadmapAnnouncementsEnabled = false;
  bool _roadmapAnnounceOnApproach = true;
  bool _roadmapAnnounceOnSpot = true;
  double _roadmapAnnounceDistanceMeters = 300.0;
  bool _roadmapAnnounceTitle = true;
  bool _roadmapAnnounceType = true;
  bool _roadmapAnnounceDescription = false;

  bool _locationEnabled = true;
  // Couleur d'accent appliquée aux cadres/titres/icônes de l'écran Outils
  // de navigation (et, à terme, à d'autres éléments des paramètres).
  // Colors.greenAccent par défaut.
  int _accentColorHex = 0xFF69F0AE;
  double _waypointIconSize = 30.0;
  // Épaisseur du trait des traces GPX (et de la trace en cours
  // d'enregistrement) affichées sur la carte, en pixels logiques.
  double _traceStrokeWidth = 4.0;
  // Couleur de repli des traces GPX/KML sur la carte : utilisée pour toute
  // trace sans couleur propre (`Trace.colorHex`). Rouge par défaut, pour
  // rester identique au comportement historique.
  int _defaultTraceColorHex = 0xFFF44336;
  // Couleur du marqueur de position (flèche de cap, point, halo). Bleu par
  // défaut.
  LocationMarkerColor _locationMarkerColor = LocationMarkerColor.blue;
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
  bool _navShowPois = true;
  bool _navShowMeasureTools = true;

  /// Calibrage podomètre par pente actif : quand `false`, aucun profil
  /// n'intègre plus de nouvelle mesure (les stats de calibrage restent
  /// figées à leur dernière valeur).
  bool _pedometerCalibrationEnabled = true;

  // Filtrage centralisé du bruit GPS (spec-filtrage-gps-centralise.md §6.1).
  // Par défaut, les points détectés `isStationary` sont exclus du stockage
  // de la trace enregistrée -- `recordPauses` permet de les inclure pour
  // que la trace reflète fidèlement les pauses (repas, photo...).
  bool _recordPauses = false;
  StationaryWindowPreset _stationaryWindowPreset = StationaryWindowPreset.s30;
  StationaryRadiusPreset _stationaryRadiusPreset = StationaryRadiusPreset.m10;

  double _edgeSwipeWidth = 40.0;
  String? _gpxStoragePath;
  String? _recordingSubPath; // Nouveau : dossier d'enregistrement par défaut
  double _tileCacheLimitMb = 500.0;
  bool _wifiOnlyDownload = true;
  bool _aiAssistantDisabled = false;
  // Favoris pilotant le bouton MAP (choisis PARMI les cartes visibles,
  // section 1 de « Mes cartes »). CyclOSM n'en fait plus partie par défaut.
  List<String> _favoriteMapIds = List.of(_defaultVisibleMapIds);

  // Fonds de carte affichés dans la 1re section de « Mes cartes » : ceux
  // proposés à l'installation + la carte nationale du pays (semence unique,
  // cf. init()). Piloté ensuite par la 2e section « Gérer les fonds de
  // carte » — sans aucun lien avec le bouton MAP.
  List<String> _visibleMapIds = List.of(_defaultVisibleMapIds);

  /// Cartes proposées par défaut : les fonds génériques d'avant les cartes
  /// nationales, CyclOSM exclu.
  static const List<String> _defaultVisibleMapIds = [
    'osm_standard',
    'opentopo',
    'google_sat',
    'arcgis_sat',
  ];

  /// Carte nationale ajoutée automatiquement à la 1re section selon le code
  /// pays de la locale de l'appareil. Semence unique à la 1re exécution.
  static const Map<String, String> _countryMapSourceIds = {
    'US': 'usgs_topo',
    'NO': 'kartverket_topo',
    'SE': 'lantmateriet_topowebb',
    'FI': 'mml_maastokartta',
    'FR': 'ign_france',
  };

  /// Code pays ISO (majuscules) déduit de la locale de l'appareil, ou
  /// `null`. Ex: `Platform.localeName` == 'fr_FR' -> 'FR'.
  static String? _deviceCountryCode() {
    try {
      final match =
          RegExp(r'[_-]([A-Za-z]{2})').firstMatch(Platform.localeName);
      return match?.group(1)?.toUpperCase();
    } catch (_) {
      return null;
    }
  }

  // Rapports de crash (spec-crash-reporting.md)
  bool _crashReportingEnabled = true;
  // Copie persistée du dernier statut premium connu (RevenueCat), mise à
  // jour à chaque résolution de `SubscriptionService` : sert de "cache
  // local synchrone" pour `CrashReportingService.beforeSend`, car
  // l'initialisation RevenueCat elle-même est asynchrone et réseau (donc
  // pas encore résolue si un crash survient tôt au démarrage).
  bool _lastKnownPremiumStatus = false;

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
  bool get showScale => _showScale;
  bool get showAccuracyCircle => _showAccuracyCircle;
  bool get reversePanels => _reversePanels;
  bool get showAllWaypoints => _showAllWaypoints;
  bool get showEveryWaypoint => _showEveryWaypoint;
  DisplayMode get displayMode => _displayMode;
  bool get showAllGpx => _showAllGpx;
  bool get showMesh => _displayMode == DisplayMode.mesh;
  bool get showGpxWaypoints => _showGpxWaypoints;
  bool get flattenWaypointFolders => _flattenWaypointFolders;
  bool get waypointAnnouncementsEnabled => _waypointAnnouncementsEnabled;
  bool get waypointAnnounceOnApproach => _waypointAnnounceOnApproach;
  bool get waypointAnnounceOnSpot => _waypointAnnounceOnSpot;
  double get waypointAnnounceDistanceMeters => _waypointAnnounceDistanceMeters;
  bool get waypointAnnounceTitle => _waypointAnnounceTitle;
  bool get waypointAnnounceType => _waypointAnnounceType;
  bool get waypointAnnounceDescription => _waypointAnnounceDescription;
  bool get roadmapAnnouncementsEnabled => _roadmapAnnouncementsEnabled;
  bool get roadmapAnnounceOnApproach => _roadmapAnnounceOnApproach;
  bool get roadmapAnnounceOnSpot => _roadmapAnnounceOnSpot;
  double get roadmapAnnounceDistanceMeters => _roadmapAnnounceDistanceMeters;
  bool get roadmapAnnounceTitle => _roadmapAnnounceTitle;
  bool get roadmapAnnounceType => _roadmapAnnounceType;
  bool get roadmapAnnounceDescription => _roadmapAnnounceDescription;
  bool get locationEnabled => _locationEnabled;
  Color get accentColor => Color(_accentColorHex);
  double get waypointIconSize => _waypointIconSize;
  double get traceStrokeWidth => _traceStrokeWidth;
  Color get defaultTraceColor => Color(_defaultTraceColorHex);
  LocationMarkerColor get locationMarkerColor => _locationMarkerColor;
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
  bool get navShowPois => _navShowPois;
  bool get navShowMeasureTools => _navShowMeasureTools;
  bool get pedometerCalibrationEnabled => _pedometerCalibrationEnabled;
  bool get recordPauses => _recordPauses;
  StationaryWindowPreset get stationaryWindowPreset => _stationaryWindowPreset;
  StationaryRadiusPreset get stationaryRadiusPreset => _stationaryRadiusPreset;
  double get edgeSwipeWidth => _edgeSwipeWidth;
  String? get gpxStoragePath => _gpxStoragePath;
  String? get recordingSubPath => _recordingSubPath;
  double get tileCacheLimitMb => _tileCacheLimitMb;
  bool get wifiOnlyDownload => _wifiOnlyDownload;
  /// Masque les points d'entrée de l'assistant IA conversationnel (page
  /// Aide, volet Navigation) — sans effet sur les annonces vocales de
  /// waypoints, fonctionnalité déterministe indépendante (voir
  /// `waypoint_announcement_settings_section.dart`).
  bool get aiAssistantDisabled => _aiAssistantDisabled;
  bool get crashReportingEnabled => _crashReportingEnabled;
  bool get lastKnownPremiumStatus => _lastKnownPremiumStatus;
  List<String> get favoriteMapIds => _favoriteMapIds;
  List<String> get visibleMapIds => _visibleMapIds;
  List<String> get activeGpxNames => _activeGpxNames;
  String? get navigationWaypointUuid => _navigationWaypointUuid;
  bool get waypointSelectionMode => _waypointSelectionMode;
  String? get roadmapTraceName => _roadmapTraceName;

  /// Vrai si une trace est chargée pour la navigation (Roadmap) ET reste
  /// affichée sur la carte. `roadmapTraceName` n'est jamais remis à `null`
  /// après un `setRoadmapTraceName` (pas de "quitter la navigation"
  /// explicite dans l'app) : si l'utilisateur désactive ensuite l'affichage
  /// de cette trace depuis le Track Manager, elle reste techniquement
  /// "chargée" mais ne doit plus compter comme telle pour l'affichage des
  /// waypoints (cf. logique d'affichage des waypoints).
  bool get hasActiveRoadmapTrace =>
      _roadmapTraceName != null && _activeGpxNames.contains(_roadmapTraceName);

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
    _showScale = _prefs.getBool('show_scale') ?? true;
    _showAccuracyCircle = _prefs.getBool('show_accuracy_circle') ?? false;
    _reversePanels = _prefs.getBool('reverse_panels') ?? false;
    _showAllWaypoints = _prefs.getBool('show_all_waypoints') ?? true;
    _showAllGpx = _prefs.getBool('show_all_gpx') ?? true;
    // On force le mode GPX au démarrage (ne pas charger depuis les préférences)
    _displayMode = DisplayMode.gpx;
    _showGpxWaypoints = _prefs.getBool('show_gpx_waypoints') ?? true;
    _flattenWaypointFolders = _prefs.getBool('flatten_waypoint_folders') ?? false;
    _waypointAnnouncementsEnabled = _prefs.getBool('waypoint_announcements_enabled') ?? false;
    _waypointAnnounceOnApproach = _prefs.getBool('waypoint_announce_on_approach') ?? true;
    _waypointAnnounceOnSpot = _prefs.getBool('waypoint_announce_on_spot') ?? true;
    _waypointAnnounceDistanceMeters = _prefs.getDouble('waypoint_announce_distance_m') ?? 300.0;
    _waypointAnnounceTitle = _prefs.getBool('waypoint_announce_title') ?? true;
    _waypointAnnounceType = _prefs.getBool('waypoint_announce_type') ?? true;
    _waypointAnnounceDescription = _prefs.getBool('waypoint_announce_description') ?? false;
    _roadmapAnnouncementsEnabled = _prefs.getBool('roadmap_announcements_enabled') ?? false;
    _roadmapAnnounceOnApproach = _prefs.getBool('roadmap_announce_on_approach') ?? true;
    _roadmapAnnounceOnSpot = _prefs.getBool('roadmap_announce_on_spot') ?? true;
    _roadmapAnnounceDistanceMeters = _prefs.getDouble('roadmap_announce_distance_m') ?? 300.0;
    _roadmapAnnounceTitle = _prefs.getBool('roadmap_announce_title') ?? true;
    _roadmapAnnounceType = _prefs.getBool('roadmap_announce_type') ?? true;
    _roadmapAnnounceDescription = _prefs.getBool('roadmap_announce_description') ?? false;
    _locationEnabled = _prefs.getBool('location_enabled') ?? true;
    _accentColorHex = _prefs.getInt('accent_color') ?? 0xFF69F0AE;
    _waypointIconSize = _prefs.getDouble('waypoint_icon_size') ?? 30.0;
    _traceStrokeWidth = _prefs.getDouble('trace_stroke_width') ?? 4.0;
    _defaultTraceColorHex = _prefs.getInt('default_trace_color') ?? 0xFFF44336;
    _locationMarkerColor = LocationMarkerColor
        .values[_prefs.getInt('location_marker_color') ?? 0];
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
    _navShowPois = _prefs.getBool('nav_show_pois') ?? true;
    _navShowMeasureTools = _prefs.getBool('nav_show_measure_tools') ?? true;
    _pedometerCalibrationEnabled =
        _prefs.getBool('pedometer_calibration_enabled') ?? true;

    _recordPauses = _prefs.getBool('record_pauses_enabled') ?? false;
    _stationaryWindowPreset = StationaryWindowPreset
        .values[_prefs.getInt('stationary_min_duration_preset') ?? 0];
    _stationaryRadiusPreset = StationaryRadiusPreset
        .values[_prefs.getInt('stationary_radius_preset') ?? 0];

    _edgeSwipeWidth = _prefs.getDouble('edge_swipe_width') ?? 40.0;
    _gpxStoragePath = _prefs.getString('gpx_storage_path');
    _recordingSubPath = _prefs.getString('recording_sub_path');
    _tileCacheLimitMb = _prefs.getDouble('tile_cache_limit_mb') ?? 500.0;
    _wifiOnlyDownload = _prefs.getBool('wifi_only_download') ?? true;
    _aiAssistantDisabled = _prefs.getBool('ai_assistant_disabled') ?? false;
    _crashReportingEnabled = _prefs.getBool('crash_reporting_enabled') ?? true;
    _lastKnownPremiumStatus = _prefs.getBool('last_known_premium_status') ?? false;
    _favoriteMapIds = _prefs.getStringList('favorite_maps') ??
        List.of(_defaultVisibleMapIds);

    // Section 1 de « Mes cartes ». Semence unique à la 1re exécution :
    // fonds par défaut + carte nationale du pays (locale).
    final storedVisible = _prefs.getStringList('visible_maps');
    if (storedVisible != null) {
      _visibleMapIds = storedVisible;
    } else {
      final seed = List<String>.of(_defaultVisibleMapIds);
      final countryMap = _countryMapSourceIds[_deviceCountryCode() ?? ''];
      if (countryMap != null && !seed.contains(countryMap)) seed.add(countryMap);
      _visibleMapIds = seed;
      await _prefs.setStringList('visible_maps', _visibleMapIds);
    }

    // Un favori doit toujours être une carte visible (migration : retire
    // CyclOSM, ou toute carte héritée non visible, des favoris du bouton
    // MAP).
    final reconciledFav =
        _favoriteMapIds.where(_visibleMapIds.contains).toList();
    if (reconciledFav.length != _favoriteMapIds.length) {
      _favoriteMapIds = reconciledFav.isEmpty
          ? _visibleMapIds.take(3).toList()
          : reconciledFav;
      await _prefs.setStringList('favorite_maps', _favoriteMapIds);
    }


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

  /// Mode "appui long" du bouton d'affichage des waypoints : montre
  /// l'intégralité des waypoints (toutes traces et dossiers confondus),
  /// sans persistance -- un appui simple suivant y met fin.
  void setShowEveryWaypoint(bool value) {
    if (_showEveryWaypoint == value) return;
    _showEveryWaypoint = value;
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

  Future<void> setFlattenWaypointFolders(bool value) async {
    _flattenWaypointFolders = value;
    await _prefs.setBool('flatten_waypoint_folders', value);
    notifyListeners();
  }

  Future<void> setWaypointAnnouncementsEnabled(bool value) async {
    _waypointAnnouncementsEnabled = value;
    await _prefs.setBool('waypoint_announcements_enabled', value);
    notifyListeners();
  }

  Future<void> setWaypointAnnounceTrigger(String key, bool value) async {
    switch (key) {
      case 'approach':
        _waypointAnnounceOnApproach = value;
        await _prefs.setBool('waypoint_announce_on_approach', value);
        break;
      case 'onSpot':
        _waypointAnnounceOnSpot = value;
        await _prefs.setBool('waypoint_announce_on_spot', value);
        break;
    }
    notifyListeners();
  }

  Future<void> setWaypointAnnounceDistanceMeters(double value) async {
    _waypointAnnounceDistanceMeters = value;
    await _prefs.setDouble('waypoint_announce_distance_m', value);
    notifyListeners();
  }

  Future<void> setWaypointAnnounceContent(String key, bool value) async {
    switch (key) {
      case 'title':
        _waypointAnnounceTitle = value;
        await _prefs.setBool('waypoint_announce_title', value);
        break;
      case 'type':
        _waypointAnnounceType = value;
        await _prefs.setBool('waypoint_announce_type', value);
        break;
      case 'description':
        _waypointAnnounceDescription = value;
        await _prefs.setBool('waypoint_announce_description', value);
        break;
    }
    notifyListeners();
  }

  Future<void> setRoadmapAnnouncementsEnabled(bool value) async {
    _roadmapAnnouncementsEnabled = value;
    await _prefs.setBool('roadmap_announcements_enabled', value);
    notifyListeners();
  }

  Future<void> setRoadmapAnnounceTrigger(String key, bool value) async {
    switch (key) {
      case 'approach':
        _roadmapAnnounceOnApproach = value;
        await _prefs.setBool('roadmap_announce_on_approach', value);
        break;
      case 'onSpot':
        _roadmapAnnounceOnSpot = value;
        await _prefs.setBool('roadmap_announce_on_spot', value);
        break;
    }
    notifyListeners();
  }

  Future<void> setRoadmapAnnounceDistanceMeters(double value) async {
    _roadmapAnnounceDistanceMeters = value;
    await _prefs.setDouble('roadmap_announce_distance_m', value);
    notifyListeners();
  }

  Future<void> setRoadmapAnnounceContent(String key, bool value) async {
    switch (key) {
      case 'title':
        _roadmapAnnounceTitle = value;
        await _prefs.setBool('roadmap_announce_title', value);
        break;
      case 'type':
        _roadmapAnnounceType = value;
        await _prefs.setBool('roadmap_announce_type', value);
        break;
      case 'description':
        _roadmapAnnounceDescription = value;
        await _prefs.setBool('roadmap_announce_description', value);
        break;
    }
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
      case 'pois': _navShowPois = value; break;
      case 'measureTools': _navShowMeasureTools = value; break;
    }
    await _prefs.setBool('nav_show_$key', value);
    notifyListeners();
  }

  Future<void> setPedometerCalibrationEnabled(bool value) async {
    _pedometerCalibrationEnabled = value;
    await _prefs.setBool('pedometer_calibration_enabled', value);
    notifyListeners();
  }

  Future<void> setRecordPauses(bool value) async {
    _recordPauses = value;
    await _prefs.setBool('record_pauses_enabled', value);
    notifyListeners();
  }

  Future<void> setStationaryWindowPreset(StationaryWindowPreset preset) async {
    _stationaryWindowPreset = preset;
    await _prefs.setInt('stationary_min_duration_preset', preset.index);
    notifyListeners();
  }

  Future<void> setStationaryRadiusPreset(StationaryRadiusPreset preset) async {
    _stationaryRadiusPreset = preset;
    await _prefs.setInt('stationary_radius_preset', preset.index);
    notifyListeners();
  }

  Future<void> setWaypointIconSize(double value) async {
    _waypointIconSize = value;
    await _prefs.setDouble('waypoint_icon_size', value);
    notifyListeners();
  }

  Future<void> setTraceStrokeWidth(double value) async {
    _traceStrokeWidth = value;
    await _prefs.setDouble('trace_stroke_width', value);
    notifyListeners();
  }

  Future<void> setDefaultTraceColor(Color color) async {
    _defaultTraceColorHex = color.toARGB32();
    await _prefs.setInt('default_trace_color', _defaultTraceColorHex);
    notifyListeners();
  }

  Future<void> setLocationMarkerColor(LocationMarkerColor value) async {
    _locationMarkerColor = value;
    await _prefs.setInt('location_marker_color', value.index);
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

  /// Met à jour la liste des fonds de carte affichés dans la 1re section de
  /// « Mes cartes » (pilotée par la 2e section « Gérer les fonds de
  /// carte »). Aucun lien avec le bouton MAP — sauf qu'une carte retirée
  /// d'ici ne peut plus être un favori : elle est alors aussi retirée de
  /// `favoriteMapIds`.
  Future<void> setVisibleMaps(List<String> ids) async {
    _visibleMapIds = ids;
    await _prefs.setStringList('visible_maps', ids);

    final reconciled = _favoriteMapIds.where(ids.contains).toList();
    if (reconciled.length != _favoriteMapIds.length) {
      _favoriteMapIds = reconciled;
      await _prefs.setStringList('favorite_maps', _favoriteMapIds);
      _currentMapIndex = _favoriteMapIds.isEmpty
          ? 0
          : _currentMapIndex % _favoriteMapIds.length;
    }
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

  Future<void> setShowAccuracyCircle(bool value) async {
    _showAccuracyCircle = value;
    await _prefs.setBool('show_accuracy_circle', value);
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

  Future<void> setAiAssistantDisabled(bool value) async {
    _aiAssistantDisabled = value;
    await _prefs.setBool('ai_assistant_disabled', value);
    notifyListeners();
  }

  /// Toggle système de désactivation des rapports de crash (spec §4). Le
  /// SDK Sentry n'étant (dés)activé qu'au prochain cold start (spec §3.1),
  /// c'est à l'appelant UI de déclencher la purge silencieuse de la file
  /// en attente quand `value == false` (voir `CrashReportingService`).
  Future<void> setCrashReportingEnabled(bool value) async {
    _crashReportingEnabled = value;
    await _prefs.setBool('crash_reporting_enabled', value);
    notifyListeners();
  }

  /// Mis à jour par `SubscriptionService` à chaque résolution du statut
  /// RevenueCat (succès réseau ou lecture de son propre cache), pour que
  /// `CrashReportingService.beforeSend` dispose d'une valeur synchrone même
  /// avant que RevenueCat n'ait fini de s'initialiser dans cette session.
  Future<void> setLastKnownPremiumStatus(bool value) async {
    if (_lastKnownPremiumStatus == value) return;
    _lastKnownPremiumStatus = value;
    await _prefs.setBool('last_known_premium_status', value);
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
