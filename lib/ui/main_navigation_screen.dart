import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import '../map/map_screen.dart';
import '../map/map_view_model.dart';
import '../map/vector_tile_source.dart';
import '../models/waypoint.dart';
import '../database/isar_service.dart';
import '../recording/recording_service.dart';
import '../search/local_search_engine.dart';
import '../utils/settings_service.dart';
import '../utils/pedometer_service.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'settings/maps_settings_screen.dart';
import 'settings/display_settings_screen.dart';
import 'settings/units_settings_screen.dart';
import 'tracks/track_manager_screen.dart';
import 'waypoints/waypoint_manager_screen.dart';

class MainNavigationScreen extends StatefulWidget {
  final IsarService isarService;
  final LocalSearchEngine searchEngine;
  final MapViewModel mapViewModel;
  final RecordingService recordingService;
  final SettingsService settingsService;
  final PedometerService pedometerService;
  final String ownerUuid;

  const MainNavigationScreen({
    super.key,
    required this.isarService,
    required this.searchEngine,
    required this.mapViewModel,
    required this.recordingService,
    required this.settingsService,
    required this.pedometerService,
    required this.ownerUuid,
  });

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen>
    with WidgetsBindingObserver {
  static const _gestureExclusionChannel = MethodChannel('rando/system_gestures');

  late PageController _pageController;
  bool _showOnboarding = false;
  late bool _reversePanelsCache;

  // Index de la page "trou" qui laisse passer les gestes vers la carte.
  int _mapPageIndex(bool reversed) => reversed ? 2 : 1;

  @override
  void initState() {
    super.initState();
    _reversePanelsCache = widget.settingsService.reversePanels;
    _pageController =
        PageController(initialPage: _mapPageIndex(_reversePanelsCache));
    widget.settingsService.addListener(_onSettingsChanged);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _updateGestureExclusion(widget.settingsService.edgeSwipeWidth));
    _checkFirstRun();
  }

  @override
  void dispose() {
    widget.settingsService.removeListener(_onSettingsChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _updateGestureExclusion(widget.settingsService.edgeSwipeWidth);
  }

  void _onSettingsChanged() {
    final reversed = widget.settingsService.reversePanels;
    if (reversed != _reversePanelsCache) {
      _reversePanelsCache = reversed;
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_mapPageIndex(reversed));
      }
    }
    _updateGestureExclusion(widget.settingsService.edgeSwipeWidth);
  }

  // Empêche le geste "retour" d'Android (navigation gestuelle) de voler les swipes de bord.
  void _updateGestureExclusion(double edgeWidth) {
    if (!mounted) return;
    final view = View.of(context);
    final size = view.physicalSize;
    final dpr = view.devicePixelRatio;
    final widthPx = (edgeWidth * dpr).round();
    final heightPx = size.height.round();
    final rects = [
      {'left': 0, 'top': 0, 'right': widthPx, 'bottom': heightPx},
      {
        'left': (size.width.round() - widthPx),
        'top': 0,
        'right': size.width.round(),
        'bottom': heightPx,
      },
    ];
    _gestureExclusionChannel
        .invokeMethod('setExclusionRects', rects)
        .catchError((_) {});
  }

  Future<void> _checkFirstRun() async {
    final prefs = await SharedPreferences.getInstance();
    final isFirstRun = prefs.getBool('is_first_run') ?? true;
    if (isFirstRun) {
      setState(() => _showOnboarding = true);
      await prefs.setBool('is_first_run', false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsService>(
      builder: (context, settings, _) {
        final settingsPage = Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            title: const Row(
              children: [
                Icon(Icons.terrain, color: Colors.greenAccent, size: 28),
                SizedBox(width: 12),
                Text('Rando Offline',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
          ),
          body: ListView(
            children: [
              _buildSettingsTile(
                icon: Icons.display_settings,
                title: 'Affichage',
                subtitle: 'Transparence, échelle, mode gaucher',
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const DisplaySettingsScreen())),
              ),
              _buildSettingsTile(
                icon: Icons.straighten,
                title: 'Unités de mesure',
                subtitle: 'Métrique / Impérial, Température',
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const UnitsSettingsScreen())),
              ),
              _buildSettingsTile(
                icon: Icons.map_outlined,
                title: 'Mes cartes',
                subtitle: 'Sélectionner vos fonds de carte favoris',
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const MapsSettingsScreen())),
              ),
              _buildSettingsTile(
                icon: Icons.route_outlined,
                title: 'Track Manager',
                subtitle: 'Gérer vos pistes GPX',
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const TrackManagerScreen())),
              ),
              _buildSettingsTile(
                icon: Icons.location_on_outlined,
                title: 'Waypoint Manager',
                subtitle: 'Gérer, filtrer et classer vos points',
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const WaypointManagerScreen())),
              ),
            ],
          ),
        );

        final contextualPage = Container(
          color: Colors.black.withValues(alpha: 0.85),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              title: const Text('Navigation'),
              backgroundColor: Colors.transparent,
              elevation: 0,
              foregroundColor: Colors.white,
            ),
            body: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _buildLiveStatsGrid(),
                const SizedBox(height: 24),
                const Divider(color: Colors.white24),
                const Text('PROCHAIN WAYPOINT',
                    style: TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                ValueListenableBuilder<Waypoint?>(
                    valueListenable: widget.recordingService.nextWaypoint,
                    builder: (context, wp, _) {
                      if (wp == null)
                        return const Text('Aucun waypoint à venir',
                            style: TextStyle(color: Colors.white38));
                      return ValueListenableBuilder<double>(
                        valueListenable: widget
                            .recordingService.distanceToNextWaypointMeters,
                        builder: (context, dist, _) {
                          final avgGlobal = widget
                              .recordingService.averageSpeedGlobalMps.value;
                          final eta = (avgGlobal > 0.5)
                              ? _formatDuration(dist / avgGlobal)
                              : '--:--';
                          return _buildNavigationInfo(
                              name: wp.name,
                              type: wp.category.value?.name ?? 'Point',
                              distance: _formatDistance(dist),
                              eta: eta,
                              isNext: true);
                        },
                      );
                    }),
                const SizedBox(height: 24),
                const Text('DESTINATION',
                    style: TextStyle(
                        color: Colors.blueAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                ValueListenableBuilder<Waypoint?>(
                    valueListenable:
                        widget.recordingService.destinationWaypoint,
                    builder: (context, wp, _) {
                      if (wp == null)
                        return const Text('Aucune destination choisie',
                            style: TextStyle(color: Colors.white38));
                      return ValueListenableBuilder<double>(
                        valueListenable:
                            widget.recordingService.distanceToDestinationMeters,
                        builder: (context, dist, _) {
                          final avgGlobal = widget
                              .recordingService.averageSpeedGlobalMps.value;
                          final eta = (avgGlobal > 0.5)
                              ? _formatDuration(dist / avgGlobal)
                              : '--:--';
                          return _buildNavigationInfo(
                              name: wp.name,
                              type: wp.category.value?.name ?? 'Destination',
                              distance: _formatDistance(dist),
                              eta: eta,
                              isNext: false);
                        },
                      );
                    }),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => WaypointManagerScreen(
                                isSelectionMode: true,
                                filterGpxName: settings.activeGpxName,
                              ))),
                  icon: const Icon(Icons.navigation),
                  label: const Text('Choisir un point de navigation'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white10,
                      foregroundColor: Colors.white),
                ),
                const Divider(color: Colors.white24, height: 40),
                const Text('AZIMUT ET DISTANCE',
                    style: TextStyle(
                        color: Colors.orangeAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                _buildMeasureButton(
                  context,
                  label: 'Depuis ma position GPS',
                  icon: Icons.gps_fixed,
                  onPressed: () {
                    settings.setMeasurementMode(MeasurementMode.fromGps);
                    _pageController.animateToPage(
                        _mapPageIndex(settings.reversePanels),
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOut);
                  },
                ),
                const SizedBox(height: 8),
                _buildMeasureButton(
                  context,
                  label: 'Entre deux points',
                  icon: Icons.straighten,
                  onPressed: () {
                    settings.setMeasurementMode(MeasurementMode.betweenPoints);
                    _pageController.animateToPage(
                        _mapPageIndex(settings.reversePanels),
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOut);
                  },
                ),
                const Divider(color: Colors.white24, height: 40),
                SwitchListTile(
                  title: const Text('Afficher les Waypoints sur la carte',
                      style: TextStyle(color: Colors.white, fontSize: 14)),
                  value: settings.showAllWaypoints,
                  onChanged: (v) => settings.setShowAllWaypoints(v),
                  activeThumbColor: Colors.greenAccent,
                ),
              ],
            ),
          ),
        );

        const wpManagerPage = WaypointManagerScreen();

        final mapBase = MapScreen(
          viewModel: widget.mapViewModel,
          isarService: widget.isarService,
          searchEngine: widget.searchEngine,
          settingsService: widget.settingsService,
          recordingService: widget.recordingService,
          ownerUuid: widget.ownerUuid,
          vectorTileSource: const VectorTileSource(
            theme: null,
            tileProviders: TileProviders({}),
          ),
        );

        // Ordre des pages pour le PageView
        final List<Widget> pages = settings.reversePanels
            ? [
                wpManagerPage,
                contextualPage,
                const IgnorePointer(
                    child: SizedBox.expand()), // Trou pour la carte à l'index 2
                settingsPage
              ]
            : [
                settingsPage,
                const IgnorePointer(
                    child: SizedBox.expand()), // Trou pour la carte à l'index 1
                contextualPage,
                wpManagerPage
              ];

        return Scaffold(
          body: Stack(
            children: [
              // 1. LA CARTE (Toujours en fond)
              mapBase,

              // 2. LES VOLETS COULISSANTS
              PageView(
                controller: _pageController,
                physics:
                    const NeverScrollableScrollPhysics(), // Désactive le swipe natif
                children: pages,
              ),

              // 3. CAPTURE DU SWIPE SUR LES BORDS (largeur réglable)
              // Bande Gauche
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: settings.edgeSwipeWidth,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: (details) => _dragPageView(details),
                  onHorizontalDragEnd: (details) => _snapPageView(),
                ),
              ),
              // Bande Droite
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: settings.edgeSwipeWidth,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: (details) => _dragPageView(details),
                  onHorizontalDragEnd: (details) => _snapPageView(),
                ),
              ),

              if (_showOnboarding) _buildOnboarding(settings.reversePanels),
            ],
          ),
        );
      },
    );
  }

  void _dragPageView(DragUpdateDetails details) {
    final position = _pageController.position;
    final newOffset = (position.pixels - details.delta.dx)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    position.jumpTo(newOffset);
  }

  void _snapPageView() {
    final position = _pageController.position;
    final page = position.pixels / MediaQuery.of(context).size.width;
    final maxPage = (position.maxScrollExtent / MediaQuery.of(context).size.width);
    final target = page.round().clamp(0, maxPage.round());
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Widget _buildLiveStatsGrid() {
    final recording = widget.recordingService;
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 3,
      childAspectRatio: 1.0,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      children: [
        AnimatedBuilder(
          animation: Listenable.merge([
            recording.currentSpeedMps,
            recording.averageSpeedDailyMps,
            recording.averageSpeedGlobalMps
          ]),
          builder: (context, _) => _buildSpeedCard(),
        ),
        ValueListenableBuilder<double>(
          valueListenable: recording.dailyDistanceMeters,
          builder: (context, dist, _) => _buildStatCard(
              'Aujourd\'hui', _formatDistance(dist), Icons.today),
        ),
        ValueListenableBuilder<double>(
          valueListenable: recording.gpsAccuracyMeters,
          builder: (context, acc, _) => _buildStatCard(
              'Précision GPS', '${acc.round()} m', Icons.satellite_alt),
        ),
        ValueListenableBuilder<double>(
          valueListenable: recording.trackDistanceDoneMeters,
          builder: (context, done, _) {
            return ValueListenableBuilder<double>(
                valueListenable: recording.trackDistanceRemainingMeters,
                builder: (context, remaining, _) {
                  final total = done + remaining;
                  return _buildStatCard(
                      'Trace',
                      '${_formatDistance(done)} / ${_formatDistance(total)}',
                      Icons.route);
                });
          },
        ),
        AnimatedBuilder(
          animation: widget.pedometerService,
          builder: (context, _) => _buildStatCard(
              'Pas', '${widget.pedometerService.steps}', Icons.directions_walk,
              isActive: widget.pedometerService.isActive,
              onTap: () => widget.pedometerService.togglePedometer()),
        ),
        ValueListenableBuilder<geo.Position?>(
          valueListenable: widget.recordingService.currentPosition,
          builder: (context, pos, _) => _buildStatCard('Satellites',
              pos != null ? 'FIX OK' : 'RECHERCHE', Icons.satellite_alt),
        ),
      ],
    );
  }

  Widget _buildSpeedCard() {
    final recording = widget.recordingService;
    final current = _formatSpeed(recording.currentSpeedMps.value);
    final avgDaily = _formatSpeed(recording.averageSpeedDailyMps.value);
    final avgGlobal = _formatSpeed(recording.averageSpeedGlobalMps.value);

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Row(children: [
            Icon(Icons.speed, color: Colors.greenAccent, size: 14),
            SizedBox(width: 4),
            Text('Vitesse',
                style: TextStyle(color: Colors.white38, fontSize: 10))
          ]),
          const Spacer(),
          Center(
              child: Text(current,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold))),
          const Spacer(),
          Text('Moy. jour: $avgDaily',
              style: const TextStyle(color: Colors.white70, fontSize: 8)),
          Text('Moy. gén.: $avgGlobal',
              style: const TextStyle(color: Colors.white70, fontSize: 8)),
        ],
      ),
    );
  }

  Widget _buildMeasureButton(BuildContext context,
      {required String label,
      required IconData icon,
      required VoidCallback onPressed}) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white.withValues(alpha: 0.05),
        foregroundColor: Colors.white,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon,
      {bool isActive = false, VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: isActive ? Colors.greenAccent : Colors.white10,
                width: isActive ? 2.0 : 1.0)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(children: [
              Icon(icon,
                  color: isActive ? Colors.greenAccent : Colors.white38,
                  size: 14),
              const SizedBox(width: 4),
              Expanded(
                  child: Text(label,
                      style: TextStyle(
                          color: isActive ? Colors.greenAccent : Colors.white38,
                          fontSize: 10),
                      overflow: TextOverflow.ellipsis))
            ]),
            const SizedBox(height: 4),
            FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(value,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold))),
          ],
        ),
      ),
    );
  }

  String _formatSpeed(double mps) =>
      widget.settingsService.unitSystem == UnitSystem.metric
          ? '${(mps * 3.6).toStringAsFixed(1)} km/h'
          : '${(mps * 2.23694).toStringAsFixed(1)} mph';
  String _formatDistance(double m) => widget.settingsService.unitSystem ==
          UnitSystem.metric
      ? (m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m')
      : (m * 3.28084 >= 5280
          ? '${(m * 3.28084 / 5280).toStringAsFixed(1)} mi'
          : '${(m * 3.28084).round()} ft');

  Widget _buildNavigationInfo(
      {required String name,
      required String type,
      required String distance,
      required String eta,
      required bool isNext}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: isNext
                  ? Colors.greenAccent.withValues(alpha: 0.2)
                  : Colors.blueAccent.withValues(alpha: 0.2))),
      child: Row(
        children: [
          Icon(isNext ? Icons.redo : Icons.flag,
              color: isNext ? Colors.greenAccent : Colors.blueAccent),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(name,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
                Text(type,
                    style: const TextStyle(color: Colors.white38, fontSize: 12))
              ])),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(distance,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16)),
            Text(eta,
                style: const TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold))
          ]),
        ],
      ),
    );
  }

  String _formatDuration(double seconds) {
    if (seconds.isInfinite || seconds.isNaN || seconds < 0) return '--:--';
    final d = Duration(seconds: seconds.round());
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    return h > 0 ? '${h}h ${m.toString().padLeft(2, '0')}m' : '${m}m';
  }

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

  Widget _buildOnboarding(bool isReversed) {
    final leftLabel = isReversed ? 'Waypoints' : 'Paramètres';
    final rightLabel = isReversed ? 'Paramètres' : 'Waypoints';
    return GestureDetector(
      onTap: () => setState(() => _showOnboarding = false),
      child: Container(
        color: Colors.black.withValues(alpha: 0.8),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.touch_app, color: Colors.white, size: 80),
              const SizedBox(height: 20),
              const Text('Bienvenue !',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 40),
              Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                _HintGesture(
                    icon: Icons.arrow_back,
                    text: 'Swipe vers la droite\n$leftLabel'),
                _HintGesture(
                    icon: Icons.arrow_forward,
                    text: 'Swipe vers la gauche\n$rightLabel')
              ]),
              const SizedBox(height: 60),
              const Text('Appuyez pour commencer',
                  style: TextStyle(color: Colors.white70)),
            ],
          ),
        ),
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
