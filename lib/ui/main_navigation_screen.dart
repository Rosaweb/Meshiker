import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:latlong2/latlong.dart';
import '../map/map_screen.dart';
import '../map/map_view_model.dart';
import '../map/osm_poi_categories.dart';
import '../models/waypoint.dart';
import '../database/isar_service.dart';
import '../recording/recording_service.dart';
import '../search/local_search_engine.dart';
import '../utils/settings_service.dart';
import '../utils/geo_utils.dart';
import '../utils/pedometer_service.dart';
import '../utils/weather_service.dart';
import '../utils/subscription_service.dart';
import 'weather_screen.dart';
import 'settings/maps_settings_screen.dart';
import 'settings/display_settings_screen.dart';
import 'settings/account_settings_screen.dart';
import 'settings/system_settings_screen.dart';
import 'settings/help_screen.dart';
import 'tracks/track_manager_screen.dart';
import 'tracks/roadmap_screen.dart';
import 'segments/segment_manager_screen.dart';
import 'waypoints/waypoint_manager_screen.dart';
import 'assistant/assistant_prompt_bar.dart';

class MainNavigationScreen extends StatefulWidget {
  final IsarService isarService;
  final LocalSearchEngine searchEngine;
  final MapViewModel mapViewModel;
  final RecordingService recordingService;
  final SettingsService settingsService;
  final PedometerService pedometerService;
  final WeatherService weatherService;
  final String ownerUuid;

  const MainNavigationScreen({
    super.key,
    required this.isarService,
    required this.searchEngine,
    required this.mapViewModel,
    required this.recordingService,
    required this.settingsService,
    required this.pedometerService,
    required this.weatherService,
    required this.ownerUuid,
  });

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const _gestureExclusionChannel =
      MethodChannel('meshiker/system_gestures');

  bool _showOnboarding = false;
  bool _poiCategoriesExpanded = false;

  late final AnimationController _scrollController;
  late double _targetScroll;
  late bool _lastReversePanels;
  late MapCreationStep _lastMapCreationStep;
  late bool _lastPickingStartupCenter;
  late String? _lastLocatingWaypointUuid;
  late String? _lastLocatingTraceUuid;

  @override
  void initState() {
    super.initState();

    final isReversed = widget.settingsService.reversePanels;
    _lastReversePanels = isReversed;
    _targetScroll = isReversed ? 2.0 : 1.0;
    _lastMapCreationStep = widget.settingsService.mapCreationStep;
    _lastPickingStartupCenter = widget.settingsService.pickingStartupCenter;
    _lastLocatingWaypointUuid = widget.settingsService.locatingWaypointUuid;
    _lastLocatingTraceUuid = widget.settingsService.locatingTraceUuid;

    _scrollController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      // Le carrousel a 4 pages (index 0-3) : sans ces bornes explicites,
      // AnimationController retombe sur ses bornes par défaut [0.0, 1.0],
      // ce qui bloque silencieusement tout scroll au-delà de 1.0 (impossible
      // d'atteindre les pages d'index 2/3, ex. le panneau "Navigation").
      lowerBound: 0.0,
      upperBound: 3.0,
      value: _targetScroll,
    );

    widget.settingsService.addListener(_onSettingsChanged);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateGestureExclusion(widget.settingsService.edgeSwipeWidth);
      widget.recordingService.startPositionMonitoring();
    });
    _checkFirstRun();
  }

  @override
  void dispose() {
    widget.settingsService.removeListener(_onSettingsChanged);
    _scrollController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _updateGestureExclusion(widget.settingsService.edgeSwipeWidth);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // On mémorise la position affichée dès que l'app quitte le premier
    // plan (pause = point de sortie fiable ; "detached" arrive trop tard,
    // le process peut déjà être en cours de destruction) pour la
    // retrouver à la prochaine ouverture (MapStartupMode.lastPosition).
    if (state == AppLifecycleState.paused) {
      final cam = widget.mapViewModel.liveCamera.value;
      if (cam != null) {
        widget.settingsService.setLastMapPosition(cam.lat, cam.lon, cam.zoom);
      }
    }
  }

  void _onSettingsChanged() {
    _updateGestureExclusion(widget.settingsService.edgeSwipeWidth);

    final isReversed = widget.settingsService.reversePanels;
    if (isReversed != _lastReversePanels) {
      _lastReversePanels = isReversed;
      // Basculer le mode gaucher inverse l'ordre du carrousel de volets
      // (cf. build()) : l'index qui pointait vers un panneau donné pointe
      // désormais vers son symétrique. On remiroir la position courante
      // pour que l'utilisateur reste sur le même panneau (typiquement les
      // paramètres, d'où ce toggle est actionné) plutôt que de se retrouver
      // téléporté sur un autre volet en revenant à l'écran principal.
      _scrollController.value = 3.0 - _scrollController.value;
      _targetScroll = 3.0 - _targetScroll;
    }

    final mapCreationStep = widget.settingsService.mapCreationStep;
    if (mapCreationStep != MapCreationStep.none &&
        _lastMapCreationStep == MapCreationStep.none) {
      // Démarrer la création d'une carte hors-ligne se fait depuis un écran
      // de paramètres poussé par-dessus ce widget (cf. MapsSettingsScreen).
      // Le simple Navigator.pop qui le referme ne suffit pas à ramener le
      // carrousel de volets sur la carte : sans ce recentrage explicite, le
      // volet paramètres (resté à son ancienne position de scroll) reste
      // affiché par-dessus la carte et masque les étapes de création.
      _targetScroll = isReversed ? 2.0 : 1.0;
      _scrollController.animateTo(_targetScroll,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
    _lastMapCreationStep = mapCreationStep;

    final pickingStartupCenter = widget.settingsService.pickingStartupCenter;
    if (pickingStartupCenter && !_lastPickingStartupCenter) {
      // Démarrage du choix du point d'ouverture personnalisé, déclenché
      // depuis DisplaySettingsScreen (déjà refermé par son propre
      // Navigator.pop) : on ramène le carrousel sur la carte pour révéler
      // la croix rouge et le bandeau simplifié.
      _targetScroll = isReversed ? 2.0 : 1.0;
      _scrollController.animateTo(_targetScroll,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    } else if (!pickingStartupCenter && _lastPickingStartupCenter) {
      // Validation ou annulation : on rouvre automatiquement les
      // paramètres d'affichage d'où le choix a été lancé.
      _pushSettings(const DisplaySettingsScreen());
    }
    _lastPickingStartupCenter = pickingStartupCenter;

    final locatingWaypointUuid = widget.settingsService.locatingWaypointUuid;
    if (locatingWaypointUuid != null && _lastLocatingWaypointUuid == null) {
      // "Localiser sur la carte" déclenché depuis la fenêtre contextuelle
      // d'un waypoint (WaypointEditScreen a déjà dépilé jusqu'à cet écran
      // via Navigator.popUntil) : on ramène le carrousel sur la carte pour
      // révéler le bouton "Retour" flottant.
      _targetScroll = isReversed ? 2.0 : 1.0;
      _scrollController.animateTo(_targetScroll,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
    _lastLocatingWaypointUuid = locatingWaypointUuid;

    final locatingTraceUuid = widget.settingsService.locatingTraceUuid;
    if (locatingTraceUuid != null && _lastLocatingTraceUuid == null) {
      // "Localiser sur la carte" déclenché depuis la fiche d'une trace GPX :
      // on ramène le carrousel sur la carte pour révéler le bouton "Retour"
      // flottant, comme pour un waypoint.
      _targetScroll = isReversed ? 2.0 : 1.0;
      _scrollController.animateTo(_targetScroll,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
    _lastLocatingTraceUuid = locatingTraceUuid;

    setState(() {});
  }

  void _updateGestureExclusion(double edgeWidth) {
    if (!mounted) return;
    final view = View.of(context);
    final size = view.physicalSize;
    final dpr = view.devicePixelRatio;
    // Android réserve inconditionnellement une bande le long des bords pour
    // son propre geste "retour" (systemGestureInsets) : toute exclusion
    // demandée à l'intérieur de cette bande est ignorée par l'OS. Il faut
    // donc positionner notre bande d'exclusion juste APRÈS cette réserve
    // système, sinon l'OS intercepte le swipe avant même que Flutter le voie.
    final systemInsets = MediaQuery.of(context).systemGestureInsets;
    final widthPx = (edgeWidth * dpr).round();
    final leftInsetPx = (systemInsets.left * dpr).round();
    final rightInsetPx = (systemInsets.right * dpr).round();
    final heightPx = size.height.round();
    final rects = [
      {
        'left': leftInsetPx,
        'top': 0,
        'right': leftInsetPx + widthPx,
        'bottom': heightPx
      },
      {
        'left': (size.width.round() - rightInsetPx - widthPx),
        'top': 0,
        'right': size.width.round() - rightInsetPx,
        'bottom': heightPx,
      },
    ];
    _gestureExclusionChannel
        .invokeMethod('setExclusionRects', rects)
        .catchError((_) {});
  }

  Future<void> _checkFirstRun() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('is_first_run') ?? true) {
      setState(() => _showOnboarding = true);
      await prefs.setBool('is_first_run', false);
    }
  }

  void _handleDrag(DragUpdateDetails details, double width) {
    // Delta positif = doigt vers la droite -> scroll diminue
    final delta = details.delta.dx / width;
    _scrollController.value = (_scrollController.value - delta).clamp(0.0, 3.0);
  }

  void _handleDragEnd() {
    _targetScroll = _scrollController.value.round().toDouble();
    _scrollController.animateTo(_targetScroll,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);

    final mapIndex = widget.settingsService.reversePanels ? 2.0 : 1.0;
    if (_targetScroll != mapIndex &&
        widget.settingsService.locatingWaypointUuid != null) {
      // L'utilisateur a quitté la carte pour un volet latéral : ce n'est
      // plus une simple manipulation de la carte, le bouton "Retour" du
      // mode "Localiser sur la carte" n'a plus lieu d'être.
      widget.settingsService.dismissLocateWaypointBackButton();
    }
    if (_targetScroll != mapIndex &&
        widget.settingsService.locatingTraceUuid != null) {
      widget.settingsService.dismissLocateTraceBackButton();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<SettingsService, List<ConnectivityResult>>(
      builder: (context, settings, connectivity, _) {
        final isOffline = connectivity.contains(ConnectivityResult.none) ||
            connectivity.isEmpty;
        final screenWidth = MediaQuery.of(context).size.width;
        final isReversed = settings.reversePanels;
        final systemGestureInsets = MediaQuery.of(context).systemGestureInsets;

        final List<Widget> pages = isReversed
            ? [
                const RoadmapScreen(isTransparent: true),
                _buildContextualPage(settings),
                const SizedBox.shrink(), // Trou pour la carte à l'index 2
                _buildSettingsPage(settings),
              ]
            : [
                _buildSettingsPage(settings),
                const SizedBox.shrink(), // Trou pour la carte à l'index 1
                _buildContextualPage(settings),
                const RoadmapScreen(isTransparent: true),
              ];

        final mapIndex = isReversed ? 2 : 1;

        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              // 1. LA CARTE (Toujours en fond)
              MapScreen(
                viewModel: widget.mapViewModel,
                isarService: widget.isarService,
                searchEngine: widget.searchEngine,
                settingsService: widget.settingsService,
                recordingService: widget.recordingService,
                ownerUuid: widget.ownerUuid,
                panelScrollAnimation: _scrollController,
                mapPageIndex: mapIndex,
                initialCenter: _initialMapCenter(settings),
                initialZoom: _initialMapZoom(settings),
              ),

              if (isOffline)
                IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: const Text(
                        'En attente de connexion',
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),

              // 2. LES VOLETS COULISSANTS (Bande horizontale exclusive)
              // Positioned.fill est indispensable ici : un Stack imbriqué,
              // placé tel quel comme enfant non positionné du Stack parent,
              // se dimensionne uniquement d'après ses propres enfants NON
              // positionnés. Or ici tous les enfants non positionnés sont des
              // SizedBox.shrink() (le "trou" pour la carte) - le panneau
              // réellement visible est toujours un Positioned.fill, qui ne
              // compte pas dans ce calcul de taille. Sans ce wrapper, le
              // Stack imbriqué s'effondre à 0x0 et les panneaux, bien que
              // construits, sont rendus invisibles.
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _scrollController,
                  builder: (context, _) {
                    final scroll = _scrollController.value;
                    return Stack(
                      children: List.generate(pages.length, (index) {
                        if (index == mapIndex) return const SizedBox.shrink();

                        final offset = index - scroll;
                        if (offset <= -1.0 || offset >= 1.0) {
                          return const SizedBox.shrink();
                        }

                        return Positioned.fill(
                          left: offset * screenWidth,
                          right: -offset * screenWidth,
                          child: Container(
                            color: Colors.black
                                .withValues(alpha: settings.barOpacity),
                            child: pages[index],
                          ),
                        );
                      }),
                    );
                  },
                ),
              ),

              // 3. CAPTURE DU SWIPE (ZONES TACTILES)
              AnimatedBuilder(
                animation: _scrollController,
                builder: (context, _) {
                  final currentScroll = _scrollController.value;
                  final isAtMap = currentScroll == mapIndex;

                  return Stack(
                    children: [
                      // Zone Gauche (décalée au-delà de la bande réservée par
                      // l'OS pour son geste "retour" - cf. _updateGestureExclusion)
                      Positioned(
                        left: systemGestureInsets.left,
                        top: 0,
                        bottom: 0,
                        width: isAtMap
                            ? settings.edgeSwipeWidth
                            : screenWidth * 0.5 - systemGestureInsets.left,
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onHorizontalDragUpdate: (details) =>
                              _handleDrag(details, screenWidth),
                          onHorizontalDragEnd: (_) => _handleDragEnd(),
                        ),
                      ),
                      // Zone Droite
                      Positioned(
                        right: systemGestureInsets.right,
                        top: 0,
                        bottom: 0,
                        width: isAtMap
                            ? settings.edgeSwipeWidth
                            : screenWidth * 0.5 - systemGestureInsets.right,
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onHorizontalDragUpdate: (details) =>
                              _handleDrag(details, screenWidth),
                          onHorizontalDragEnd: (_) => _handleDragEnd(),
                        ),
                      ),
                    ],
                  );
                },
              ),

              if (_showOnboarding) _buildOnboarding(settings.reversePanels),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSettingsPage(SettingsService settings) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Row(children: [
          const Icon(Icons.terrain, color: Colors.greenAccent, size: 28),
          const SizedBox(width: 12),
          Text(
            context.watch<SubscriptionService>().isPremium ? 'Meshiker Pro' : 'Meshiker',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ]),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            _targetScroll = settings.reversePanels ? 2.0 : 1.0;
            _scrollController.animateTo(_targetScroll,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut);
          },
        ),
      ),
      body: ListView(
        children: [
          _buildSettingsTile(
              icon: Icons.account_circle_outlined,
              title: 'Mon compte',
              subtitle: 'Gérer mon abonnement',
              onTap: () => _pushSettings(const AccountSettingsScreen())),
          const Divider(color: Colors.white12),
          _buildSettingsTile(
              icon: Icons.settings_suggest_outlined,
              title: 'Paramètres système',
              subtitle: 'Stockage GPX, Cache des cartes',
              onTap: () => _pushSettings(const SystemSettingsScreen())),
          _buildSettingsTile(
              icon: Icons.display_settings,
              title: 'Paramètres d\'affichage',
              subtitle: 'Transparence, échelle',
              onTap: () => _pushSettings(const DisplaySettingsScreen())),
          _buildSettingsTile(
              icon: Icons.map_outlined,
              title: 'Mes cartes',
              subtitle: 'Sélectionner vos favoris',
              onTap: () => _pushSettings(const MapsSettingsScreen())),
          _buildSettingsTile(
              icon: Icons.route_outlined,
              title: 'Track Manager',
              subtitle: 'Gérer vos pistes GPX',
              onTap: () => _pushSettings(const TrackManagerScreen())),
          _buildSettingsTile(
              icon: Icons.location_on_outlined,
              title: 'Waypoint Manager',
              subtitle: 'Gérer vos waypoints',
              onTap: () => _pushSettings(const WaypointManagerScreen())),
          _buildSettingsTile(
              icon: Icons.timeline_outlined,
              title: 'Mesh manager',
              subtitle: 'Gérer les segments',
              onTap: () => _pushSettings(const SegmentManagerScreen())),
          _buildSettingsTile(
              icon: Icons.help_outline,
              title: 'Aide',
              subtitle: 'Assistance et prise en main',
              onTap: () => _pushSettings(const HelpScreen())),
          const Divider(color: Colors.white12),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('MODE D\'AFFICHAGE',
                    style: TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                _buildDisplayModeSelector(settings),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContextualPage(SettingsService settings) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Navigation'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            _targetScroll = settings.reversePanels ? 2.0 : 1.0;
            _scrollController.animateTo(_targetScroll,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut);
          },
        ),
        actions: [
          IconButton(
            icon: Icon(settings.reversePanels
                ? Icons.arrow_back
                : Icons.arrow_forward),
            onPressed: () {
              _targetScroll = settings.reversePanels ? 0.0 : 3.0;
              _scrollController.animateTo(_targetScroll,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut);
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _buildLiveStatsGrid(settings),
          const SizedBox(height: 12),
          if (settings.navShowNextWaypoint) ...[
            _buildNavSection(
                'PROCHAIN WAYPOINT',
                settings.accentColor,
                widget.recordingService.nextWaypoint,
                widget.recordingService.distanceToNextWaypointMeters,
                true),
            const SizedBox(height: 12),
          ],
          if (settings.navShowDestination) ...[
            _buildNavSection(
                'POINT D\'ÉTAPE',
                settings.accentColor,
                widget.recordingService.destinationWaypoint,
                widget.recordingService.distanceToDestinationMeters,
                false,
                trailing: ElevatedButton.icon(
                  onPressed: () => _pushSettings(
                      const RoadmapScreen(isSelectionMode: true)),
                  icon: const Icon(Icons.navigation),
                  label: const Text('Choisir un point'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white10,
                      foregroundColor: Colors.white),
                )),
            const SizedBox(height: 12),
          ],
          if (settings.navShowPois) ...[
            _buildPoiBlock(settings),
            const SizedBox(height: 12),
          ],
          if (settings.navShowMeasureTools) ...[
            _buildToolBlock(
              title: 'AZIMUT ET DISTANCE',
              color: settings.accentColor,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildMeasureButton(context,
                      label: 'Depuis ma position GPS',
                      icon: Icons.gps_fixed, onPressed: () {
                    widget.settingsService
                        .setMeasurementMode(MeasurementMode.fromGps);
                    _targetScroll = settings.reversePanels ? 2.0 : 1.0;
                    _scrollController.animateTo(_targetScroll,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOut);
                  }),
                  const SizedBox(height: 8),
                  _buildMeasureButton(context,
                      label: 'Entre deux points',
                      icon: Icons.straighten, onPressed: () {
                    widget.settingsService
                        .setMeasurementMode(MeasurementMode.betweenPoints);
                    _targetScroll = settings.reversePanels ? 2.0 : 1.0;
                    _scrollController.animateTo(_targetScroll,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOut);
                  }),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (settings.locationEnabled)
            _buildToolBlock(
              title: 'POSITION',
              color: settings.accentColor,
              child: _buildCoordinatesContent(),
            ),
          const SizedBox(height: 12),
          const AssistantPromptBar(title: 'ASSISTANT DE NAVIGATION'),
        ],
      ),
    );
  }

  Widget _buildToolBlock(
      {required String title, required Color color, required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.2))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _buildCoordinatesContent() {
    return ValueListenableBuilder(
      valueListenable: widget.recordingService.currentPosition,
      builder: (context, pos, _) {
        if (pos == null) {
          return const Text('En attente de position GPS...',
              style: TextStyle(color: Colors.white38, fontSize: 12));
        }
        final utm = GeoUtils.latLonToUtm(pos.latitude, pos.longitude);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildCoordinateRow('Lat/Lon',
                      '${pos.latitude.toStringAsFixed(6)}, ${pos.longitude.toStringAsFixed(6)}'),
                  const SizedBox(height: 6),
                  _buildCoordinateRow('UTM',
                      '${utm.zone}${utm.hemisphere} ${utm.easting.round()}E ${utm.northing.round()}N'),
                ],
              ),
            ),
            IconButton(
              onPressed: () =>
                  _copyCoordinates(context, pos.latitude, pos.longitude, utm),
              icon: const Icon(Icons.copy, color: Colors.white70, size: 20),
              tooltip: 'Copier',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        );
      },
    );
  }

  void _copyCoordinates(
      BuildContext context,
      double lat,
      double lon,
      ({int zone, String hemisphere, double easting, double northing}) utm) {
    final latDms = GeoUtils.toDms(lat, isLatitude: true);
    final lonDms = GeoUtils.toDms(lon, isLatitude: false);
    final mapsLink = 'https://www.google.com/maps/place/$latDms+$lonDms';
    final text = '$mapsLink\n'
        'Lat/Lon : ${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}\n'
        'UTM : ${utm.zone}${utm.hemisphere} ${utm.easting.round()}E ${utm.northing.round()}N';
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Coordonnées copiées dans le presse-papiers')),
    );
  }

  Widget _buildCoordinateRow(String label, String value) {
    return Row(
      children: [
        SizedBox(
          width: 60,
          child: Text(label,
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ),
        Expanded(
          child: Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }

  Widget _buildNavSection(
      String label,
      Color color,
      ValueNotifier<Waypoint?> wpNotifier,
      ValueNotifier<double> distNotifier,
      bool isNext,
      {Widget? trailing}) {
    return _buildToolBlock(
      title: label,
      color: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValueListenableBuilder<Waypoint?>(
              valueListenable: wpNotifier,
              builder: (context, wp, _) {
                if (wp == null) {
                  // "Point d'étape" n'affiche rien de plus quand aucune
                  // destination n'est choisie : le titre du bloc et le
                  // bouton "Choisir un point" suffisent.
                  return isNext
                      ? const Text('Aucun point',
                          style: TextStyle(color: Colors.white38))
                      : const SizedBox.shrink();
                }
                return ValueListenableBuilder<double>(
                  valueListenable: distNotifier,
                  builder: (context, dist, _) {
                    final speed =
                        widget.recordingService.averageSpeedGlobalMps.value;
                    final eta = (speed > 0.5)
                        ? _formatDuration(dist / speed)
                        : '--:--';
                    return _buildNavigationInfo(
                        name: wp.name,
                        type: wp.category.value?.name ?? 'Point',
                        distance: _formatDistance(dist),
                        eta: eta,
                        isNext: isNext);
                  },
                );
              }),
          if (trailing != null) ...[
            const SizedBox(height: 12),
            trailing,
          ],
        ],
      ),
    );
  }

  /// Bloc "Points d'intérêt OSM" du volet de navigation : interrupteur
  /// principal (fetch/affichage OSM en direct, voir SettingsService.
  /// showOsmPois) + liste dépliable des catégories actives. Le bloc lui-
  /// même n'apparaît que si navShowPois est activé (Personnaliser la
  /// navigation), sur le même principe que les autres blocs de ce volet.
  /// Titre, interrupteur et chevron partagent la même ligne (pas de
  /// sous-titre) -- distinct des autres blocs de ce volet (via
  /// _buildToolBlock) qui n'ont besoin que d'un titre simple.
  Widget _buildPoiBlock(SettingsService settings) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: settings.accentColor.withValues(alpha: 0.2))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text("POINTS D'INTÉRÊT OSM",
                    style: TextStyle(
                        color: settings.accentColor,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
              ),
              Switch(
                value: settings.showOsmPois,
                activeThumbColor: Colors.greenAccent,
                onChanged: (v) => settings.setShowOsmPois(v),
              ),
              IconButton(
                icon: Icon(
                    _poiCategoriesExpanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.white70),
                onPressed: () => setState(() => _poiCategoriesExpanded = !_poiCategoriesExpanded),
              ),
            ],
          ),
          if (_poiCategoriesExpanded)
            ...kOsmPoiCategories.map((cat) => CheckboxListTile(
                  title: Text(cat.label, style: const TextStyle(color: Colors.white, fontSize: 13)),
                  secondary: Icon(cat.icon, color: cat.color, size: 20),
                  value: settings.enabledOsmPoiCategoryIds.contains(cat.id),
                  activeColor: Colors.greenAccent,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (checked) {
                    final updated = Set<String>.from(settings.enabledOsmPoiCategoryIds);
                    checked == true ? updated.add(cat.id) : updated.remove(cat.id);
                    settings.setEnabledOsmPoiCategories(updated);
                  },
                )),
        ],
      ),
    );
  }

  Widget _buildLiveStatsGrid(SettingsService settings) {
    final recording = widget.recordingService;
    return GridView.count(
      shrinkWrap: true,
      // Sans ça, ce GridView imbriqué est traité comme le scroll "primary"
      // (pas de controller, axe vertical) et applique automatiquement
      // l'inset système (barre de navigation Android) en padding bas,
      // créant une marge bien plus grande que le SizedBox(12) qui sépare
      // les autres blocs.
      primary: false,
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 3,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      // Les blocs s'étirent en hauteur quand le texte est grossi
      // (cf. SettingsService.fontScale) pour éviter tout débordement.
      childAspectRatio: 1.25 / settings.fontScale,
      children: [
        if (settings.navShowSpeed)
          AnimatedBuilder(
              animation: Listenable.merge([
                recording.currentSpeedMps,
                recording.averageSpeedDailyMps,
                recording.averageSpeedGlobalMps
              ]),
              builder: (context, _) => _buildSpeedCard()),
        if (settings.navShowDailyDist)
          ValueListenableBuilder<double>(
              valueListenable: recording.dailyDistanceMeters,
              builder: (context, dist, _) => _buildStatCard(
                  'Aujourd\'hui', _formatDistanceKm(dist), Icons.today)),
        if (settings.navShowGpsAccuracy)
          ValueListenableBuilder<double>(
              valueListenable: recording.gpsAccuracyMeters,
              builder: (context, acc, _) => _buildStatCard(
                  'Précision GPS', '${acc.round()} m', Icons.satellite_alt)),
        if (settings.navShowTraceDist)
          ValueListenableBuilder<double>(
              valueListenable: recording.trackDistanceDoneMeters,
              builder: (context, done, _) => ValueListenableBuilder<double>(
                  valueListenable: recording.trackDistanceRemainingMeters,
                  builder: (context, rem, _) => _buildStatCard(
                      'Trace',
                      '${_formatDistanceKm(done)} parc.\n${_formatDistanceKm(rem)} rest.',
                      Icons.route,
                      multiLine: true))),
        if (settings.navShowPedometer)
          AnimatedBuilder(
              animation: widget.pedometerService,
              builder: (context, _) => _buildStatCard('Podomètre',
                  '${widget.pedometerService.steps}', Icons.directions_walk,
                  isActive: widget.pedometerService.isActive,
                  onTap: () async {
                    await widget.pedometerService.togglePedometer();
                    if (!context.mounted) return;
                    if (widget.pedometerService.permissionDenied) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text(
                                'Autorisez "Activité physique" dans les paramètres Android pour utiliser le podomètre.')),
                      );
                    } else if (widget.pedometerService.sensorUnavailable) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text(
                                'Aucun capteur de pas détecté sur cet appareil.')),
                      );
                    }
                  })),
        if (settings.navShowSatellites)
          ValueListenableBuilder<String>(
              valueListenable: recording.gpsStatus,
              builder: (context, status, _) => _buildStatCard(
                    'Satellites',
                    status,
                    Icons.satellite_alt,
                    multiLine: status.contains('\n'),
                    onTap: () => _showSatelliteDetails(context),
                  )),
        ValueListenableBuilder<String>(
          valueListenable: recording.solarTimes,
          builder: (context, times, _) => _buildStatCard(
            'Soleil',
            times,
            Icons.wb_sunny_outlined,
            multiLine: true,
          ),
        ),
        AnimatedBuilder(
          animation: widget.weatherService,
          builder: (context, _) {
            final weather = widget.weatherService;
            final code = weather.next4HoursWeatherCode;
            final label = !weather.isActive
                ? 'Météo'
                : (weather.isLoading
                    ? 'Chargement...'
                    : (weather.error ??
                        (code != null ? weatherCodeLabel(code) : 'Météo')));
            return _buildStatCard(
              label,
              '',
              code != null ? weatherCodeIcon(code) : Icons.cloud_outlined,
              isActive: weather.isActive,
              valueWidget: (weather.isActive && code != null)
                  ? Icon(weatherCodeIcon(code), color: Colors.white, size: 30)
                  : null,
              onTap: () async {
                final pos = widget.recordingService.currentPosition.value;
                await weather.toggle(pos?.latitude, pos?.longitude);
                if (context.mounted && weather.error != null) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(weather.error!)));
                }
              },
              onDoubleTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const WeatherScreen())),
            );
          },
        ),
        ValueListenableBuilder(
          valueListenable: recording.currentPosition,
          builder: (context, pos, _) {
            final available = settings.locationEnabled && pos != null;
            // Pas de cadre épaissi ici : contrairement au podomètre ou à la
            // météo, ce bloc n'est pas activé par un tap — il reflète
            // simplement l'état de la localisation.
            return _buildStatCard(
              'Altitude',
              available ? _formatAltitude(pos.altitude) : '--',
              Icons.terrain,
            );
          },
        ),
      ],
    );
  }

  void _showSatelliteDetails(BuildContext context) {
    final recording = widget.recordingService;
    final breakdown = recording.constellationBreakdown;

    if (breakdown.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Aucune donnée satellite disponible')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Satellites détectés',
            style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: breakdown.entries
              .map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Text('${e.key}: ${e.value}',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 16)),
                  ))
              .toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('FERMER',
                style: TextStyle(color: Colors.greenAccent)),
          ),
        ],
      ),
    );
  }

  Widget _buildSpeedCard() {
    final recording = widget.recordingService;
    final accent = widget.settingsService.accentColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accent.withValues(alpha: 0.2))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.speed, color: accent, size: 15),
            const SizedBox(width: 4),
            Text('Vitesse', style: TextStyle(color: accent, fontSize: 11))
          ]),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(_formatSpeed(recording.currentSpeedMps.value),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text(
                      'Jour: ${_formatSpeed(recording.averageSpeedDailyMps.value)}',
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w500)),
                  Text(
                      'Gén.: ${_formatSpeed(recording.averageSpeedGlobalMps.value)}',
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// [isActive] ne doit servir qu'aux cadres "à activer par un tap" (ex :
  /// podomètre, météo) : il épaissit juste le cadre pour indiquer l'état
  /// activé/désactivé. Titre et icône restent toujours en couleur d'accent,
  /// que le bloc soit actif ou non.
  Widget _buildStatCard(String label, String value, IconData icon,
      {bool isActive = false,
      VoidCallback? onTap,
      VoidCallback? onDoubleTap,
      bool multiLine = false,
      Widget? valueWidget}) {
    final accent = widget.settingsService.accentColor;
    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: isActive ? accent : accent.withValues(alpha: 0.2),
                width: isActive ? 2.0 : 1.0)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: accent, size: 15),
            const SizedBox(width: 4),
            Expanded(
                child: Text(label,
                    style: TextStyle(color: accent, fontSize: 11),
                    overflow: TextOverflow.ellipsis))
          ]),
          Expanded(
            child: Center(
              child: valueWidget ??
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(value,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: multiLine ? 12 : 18,
                            fontWeight: FontWeight.bold)),
                  ),
            ),
          ),
        ]),
      ),
    );
  }

  String _formatAltitude(double meters) =>
      widget.settingsService.unitSystem == UnitSystem.metric
          ? '${meters.round()} m'
          : '${(meters * 3.28084).round()} ft';
  String _formatSpeed(double mps) =>
      widget.settingsService.unitSystem == UnitSystem.metric
          ? (mps * 3.6).toStringAsFixed(1)
          : (mps * 2.23694).toStringAsFixed(1);
  String _formatDistance(double m) => widget.settingsService.unitSystem ==
          UnitSystem.metric
      ? (m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m')
      : (m * 3.28084 >= 5280
          ? '${(m * 3.28084 / 5280).toStringAsFixed(1)} mi'
          : '${(m * 3.28084).round()} ft');
  String _formatDistanceKm(double m) {
    if (widget.settingsService.unitSystem == UnitSystem.metric) {
      return '${(m / 1000).toStringAsFixed(2)} km';
    } else {
      return '${(m * 0.000621371).toStringAsFixed(2)} mi';
    }
  }

  String _formatDuration(double seconds) {
    if (seconds.isInfinite || seconds.isNaN || seconds < 0) return '--:--';
    final d = Duration(seconds: seconds.round());
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    return h > 0 ? '${h}h ${m.toString().padLeft(2, '0')}m' : '${m}m';
  }

  Widget _buildNavigationInfo(
      {required String name,
      required String type,
      required String distance,
      required String eta,
      required bool isNext}) {
    return Row(children: [
      Icon(isNext ? Icons.redo : Icons.flag,
          color: widget.settingsService.accentColor),
      const SizedBox(width: 12),
      Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
        Text(type, style: const TextStyle(color: Colors.white38, fontSize: 12))
      ])),
      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(distance,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
        Text(eta,
            style: const TextStyle(
                color: Colors.orangeAccent,
                fontSize: 12,
                fontWeight: FontWeight.bold))
      ]),
    ]);
  }

  Widget _buildMeasureButton(BuildContext context,
          {required String label,
          required IconData icon,
          required VoidCallback onPressed}) =>
      ElevatedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 18),
          label: Text(label),
          style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.05),
              foregroundColor: Colors.white,
              alignment: Alignment.centerLeft,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12)));
  Widget _buildSettingsTile(
          {required IconData icon,
          required String title,
          required String subtitle,
          required VoidCallback onTap}) =>
      ListTile(
          leading: Icon(icon, color: Colors.greenAccent),
          title: Text(title, style: const TextStyle(color: Colors.white)),
          subtitle:
              Text(subtitle, style: const TextStyle(color: Colors.white60)),
          trailing: const Icon(Icons.chevron_right, color: Colors.white24),
          onTap: onTap);

  Widget _buildDisplayModeSelector(SettingsService settings) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ModeBtn(
              label: 'GPX',
              isSelected: settings.displayMode == DisplayMode.gpx,
              onTap: () => settings.setDisplayMode(DisplayMode.gpx),
            ),
          ),
          Expanded(
            child: _ModeBtn(
              label: 'MESH',
              isSelected: settings.displayMode == DisplayMode.mesh,
              onTap: () => settings.setDisplayMode(DisplayMode.mesh),
            ),
          ),
        ],
      ),
    );
  }

  // Point de repli si aucune position n'a jamais été enregistrée (premier
  // lancement de l'app, avant toute fermeture) : Mont Blanc, valeur
  // historique par défaut de MapScreen.
  static const _fallbackCenter = LatLng(45.8326, 6.8652);
  static const _fallbackZoom = 13.0;

  /// Centre de la carte à utiliser au démarrage : le point personnalisé si
  /// l'utilisateur l'a choisi (MapStartupMode.customPoint), sinon la
  /// dernière position mémorisée à la fermeture précédente, sinon le repli
  /// Mont Blanc (première installation uniquement).
  LatLng _initialMapCenter(SettingsService settings) {
    if (settings.mapStartupMode == MapStartupMode.customPoint) {
      final custom = settings.customMapCenter;
      if (custom != null) return LatLng(custom.lat, custom.lon);
    }
    final last = settings.lastMapPosition;
    if (last != null) return LatLng(last.lat, last.lon);
    return _fallbackCenter;
  }

  double _initialMapZoom(SettingsService settings) {
    if (settings.mapStartupMode == MapStartupMode.customPoint) {
      final custom = settings.customMapCenter;
      if (custom != null) return custom.zoom;
    }
    final last = settings.lastMapPosition;
    if (last != null) return last.zoom;
    return _fallbackZoom;
  }

  void _pushSettings(Widget screen) {
    Navigator.push(
        context,
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) => screen,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return SlideTransition(
              position:
                  Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
                      .animate(animation),
              child: child,
            );
          },
        ));
  }

  Widget _buildOnboarding(bool isReversed) {
    return GestureDetector(
      onTap: () => setState(() => _showOnboarding = false),
      child: Container(
        color: Colors.black.withValues(alpha: 0.8),
        child: const Center(
            child:
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.touch_app, color: Colors.white, size: 80),
          SizedBox(height: 20),
          Text('Bienvenue !',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold)),
          SizedBox(height: 40),
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _HintGesture(
                icon: Icons.arrow_forward,
                text: 'Swipe vers la droite\nParamètres'),
            _HintGesture(
                icon: Icons.arrow_back,
                text: 'Swipe vers la gauche\nNavigation'),
          ]),
          SizedBox(height: 60),
          Text('Appuyez pour commencer',
              style: TextStyle(color: Colors.white70)),
            SizedBox(height: 60),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _HintGesture(
                    icon: Icons.arrow_upward,
                    text: 'Swipe vers le haut\nMenu étendu'),
              ]),
        ])),
      ),
    );
  }
}

class _HintGesture extends StatelessWidget {
  final IconData icon;
  final String text;
  const _HintGesture({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Column(children: [
        Icon(icon, color: Colors.blueAccent, size: 40),
        const SizedBox(height: 8),
        Text(text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white))
      ]);
}

class _ModeBtn extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModeBtn(
      {required this.label, required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? Colors.greenAccent : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: isSelected ? Colors.black : Colors.white38,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}
