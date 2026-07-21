import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../map/map_screen.dart';
import '../map/map_view_model.dart';
import '../models/waypoint.dart';
import '../database/isar_service.dart';
import '../recording/recording_service.dart';
import '../search/local_search_engine.dart';
import '../utils/settings_service.dart';
import '../utils/pedometer_service.dart';
import 'settings/maps_settings_screen.dart';
import 'settings/display_settings_screen.dart';
import 'settings/account_settings_screen.dart';
import 'settings/system_settings_screen.dart';
import 'tracks/track_manager_screen.dart';
import 'segments/segment_manager_screen.dart';
import 'waypoints/waypoint_manager_screen.dart';
import 'settings/about_screen.dart';

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
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const _gestureExclusionChannel = MethodChannel('meshiker/system_gestures');

  bool _showOnboarding = false;

  late final AnimationController _leftPanelController;
  late final AnimationController _rightPanelController;
  late final AnimationController _centerPanelController;

  late final Animation<Offset> _leftPanelOffset;
  late final Animation<Offset> _rightPanelOffset;
  late final Animation<Offset> _centerPanelOffset;

  @override
  void initState() {
    super.initState();
    
    _leftPanelController = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    _rightPanelController = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    _centerPanelController = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));

    _leftPanelOffset = Tween<Offset>(begin: const Offset(-1, 0), end: Offset.zero).animate(CurvedAnimation(parent: _leftPanelController, curve: Curves.easeOut));
    _rightPanelOffset = Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: _rightPanelController, curve: Curves.easeOut));
    _centerPanelOffset = Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: _centerPanelController, curve: Curves.easeOut));

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
    _leftPanelController.dispose();
    _rightPanelController.dispose();
    _centerPanelController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _updateGestureExclusion(widget.settingsService.edgeSwipeWidth);
  }

  void _onSettingsChanged() {
    _updateGestureExclusion(widget.settingsService.edgeSwipeWidth);
    setState(() {});
  }

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
    _gestureExclusionChannel.invokeMethod('setExclusionRects', rects).catchError((_) {});
  }

  Future<void> _checkFirstRun() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('is_first_run') ?? true) {
      setState(() => _showOnboarding = true);
      await prefs.setBool('is_first_run', false);
    }
  }

  void _handleDrag(DragUpdateDetails details, double width) {
    final delta = details.delta.dx / width;
    
    // Si on est sur la carte (tous les panels fermés)
    if (_leftPanelController.value == 0 && _rightPanelController.value == 0 && _centerPanelController.value == 0) {
      if (delta > 0) {
        // Drag vers la droite -> on ouvre le panel gauche
        _leftPanelController.value = (_leftPanelController.value + delta).clamp(0, 1);
      } else {
        // Drag vers la gauche -> on ouvre le panel central (Navigation)
        _centerPanelController.value = (_centerPanelController.value - delta).clamp(0, 1);
      }
    } 
    // Si panel gauche ouvert
    else if (_leftPanelController.value > 0) {
      _leftPanelController.value = (_leftPanelController.value + delta).clamp(0, 1);
    }
    // Si panel central ouvert
    else if (_centerPanelController.value > 0 && _rightPanelController.value == 0) {
      if (delta < 0) {
        // Drag vers la gauche -> on ouvre le panel droit (Waypoints)
        _rightPanelController.value = (_rightPanelController.value - delta).clamp(0, 1);
      } else {
        // Drag vers la droite -> on ferme le panel central
        _centerPanelController.value = (_centerPanelController.value - delta).clamp(0, 1);
      }
    }
    // Si panel droit ouvert
    else if (_rightPanelController.value > 0) {
      _rightPanelController.value = (_rightPanelController.value + delta).clamp(0, 1);
    }
  }

  void _handleDragEnd() {
    _snapController(_leftPanelController);
    _snapController(_centerPanelController);
    _snapController(_rightPanelController);
  }

  void _snapController(AnimationController controller) {
    if (controller.value > 0.5) {
      controller.forward();
    } else {
      controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<SettingsService, List<ConnectivityResult>>(
      builder: (context, settings, connectivity, _) {
        final isOffline = connectivity.contains(ConnectivityResult.none) || connectivity.isEmpty;
        final screenWidth = MediaQuery.of(context).size.width;

        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              // 1. LA CARTE (Toujours en fond, reçoit les gestes si pas de panel dessus)
              MapScreen(
                viewModel: widget.mapViewModel,
                isarService: widget.isarService,
                searchEngine: widget.searchEngine,
                settingsService: widget.settingsService,
                recordingService: widget.recordingService,
                ownerUuid: widget.ownerUuid,
              ),

              if (isOffline)
                IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: const Text(
                        'En attente de connexion',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),

              // 2. LES VOLETS COULISSANTS (CSS-like)
              // Panel Gauche (Paramètres)
              SlideTransition(
                position: _leftPanelOffset,
                child: SizedBox(
                  width: screenWidth,
                  child: _buildSettingsPage(settings),
                ),
              ),

              // Panel Central (Navigation)
              SlideTransition(
                position: _centerPanelOffset,
                child: SizedBox(
                  width: screenWidth,
                  child: _buildContextualPage(settings),
                ),
              ),

              // Panel Droit (Waypoints)
              SlideTransition(
                position: _rightPanelOffset,
                child: SizedBox(
                  width: screenWidth,
                  child: const WaypointManagerScreen(isTransparent: true),
                ),
              ),

              // 3. CAPTURE DU SWIPE SUR LES BORDS (Zones étroites qui ne bloquent pas le centre)
              // Bande Gauche
              Positioned(
                left: 0, top: 0, bottom: 0, width: settings.edgeSwipeWidth,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: (details) => _handleDrag(details, screenWidth),
                  onHorizontalDragEnd: (_) => _handleDragEnd(),
                ),
              ),
              // Bande Droite
              Positioned(
                right: 0, top: 0, bottom: 0, width: settings.edgeSwipeWidth,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: (details) => _handleDrag(details, screenWidth),
                  onHorizontalDragEnd: (_) => _handleDragEnd(),
                ),
              ),

              if (_showOnboarding) _buildOnboarding(settings.reversePanels),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSettingsPage(SettingsService settings) {
    return Container(
      color: Colors.black.withValues(alpha: settings.barOpacity),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Row(children: [
            Icon(Icons.terrain, color: Colors.greenAccent, size: 28),
            SizedBox(width: 12),
            Text('Meshiker', style: TextStyle(fontWeight: FontWeight.bold)),
          ]),
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => _leftPanelController.reverse(),
          ),
        ),
        body: ListView(
          children: [
            _buildSettingsTile(icon: Icons.account_circle_outlined, title: 'Mon compte', subtitle: 'Gérer mon abonnement',
                onTap: () => _pushSettings(const AccountSettingsScreen())),
            const Divider(color: Colors.white12),
            _buildSettingsTile(icon: Icons.display_settings, title: 'Affichage et Unités', subtitle: 'Transparence, échelle, métrique/impérial',
                onTap: () => _pushSettings(const DisplaySettingsScreen())),
            _buildSettingsTile(icon: Icons.map_outlined, title: 'Mes cartes', subtitle: 'Sélectionner vos favoris',
                onTap: () => _pushSettings(const MapsSettingsScreen())),
            _buildSettingsTile(icon: Icons.settings_suggest_outlined, title: 'Paramètres système', subtitle: 'Stockage GPX, Cache des cartes',
                onTap: () => _pushSettings(const SystemSettingsScreen())),
            _buildSettingsTile(icon: Icons.route_outlined, title: 'Track Manager', subtitle: 'Gérer vos pistes GPX',
                onTap: () => _pushSettings(const TrackManagerScreen())),
            _buildSettingsTile(icon: Icons.timeline_outlined, title: 'Mesh manager', subtitle: 'Gérer les segments',
                onTap: () => _pushSettings(const SegmentManagerScreen())),
            _buildSettingsTile(icon: Icons.location_on_outlined, title: 'Waypoint Manager', subtitle: 'Gérer vos waypoints',
                onTap: () => _pushSettings(const WaypointManagerScreen())),
            const Divider(color: Colors.white12),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('MODE D\'AFFICHAGE', style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  _buildDisplayModeSelector(settings),
                ],
              ),
            ),
            const Divider(color: Colors.white12),
            _buildSettingsTile(icon: Icons.info_outline, title: 'À propos', subtitle: 'Version, légal et contact',
                onTap: () => _pushSettings(const AboutScreen())),
          ],
        ),
      ),
    );
  }

  Widget _buildContextualPage(SettingsService settings) {
    return Container(
      color: Colors.black.withValues(alpha: settings.barOpacity),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Navigation'), 
          backgroundColor: Colors.transparent, 
          elevation: 0, 
          foregroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => _centerPanelController.reverse(),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.arrow_forward),
              onPressed: () => _rightPanelController.forward(),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            _buildLiveStatsGrid(settings),
            const SizedBox(height: 24),
            const Divider(color: Colors.white24),
            if (settings.navShowNextWaypoint) ...[
              _buildNavSection('PROCHAIN WAYPOINT', Colors.greenAccent, widget.recordingService.nextWaypoint, widget.recordingService.distanceToNextWaypointMeters, true),
              const SizedBox(height: 24),
            ],
            if (settings.navShowDestination) ...[
              _buildNavSection('DESTINATION', Colors.blueAccent, widget.recordingService.destinationWaypoint, widget.recordingService.distanceToDestinationMeters, false),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () {
                  widget.settingsService.setWaypointSelectionMode(true);
                  _centerPanelController.reverse();
                },
                icon: const Icon(Icons.navigation), label: const Text('Choisir un point'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.white10, foregroundColor: Colors.white),
              ),
              const Divider(color: Colors.white24, height: 40),
            ],
            if (settings.navShowMeasureTools) ...[
              const Text('AZIMUT ET DISTANCE', style: TextStyle(color: Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              _buildMeasureButton(context, label: 'Depuis ma position GPS', icon: Icons.gps_fixed, onPressed: () {
                widget.settingsService.setMeasurementMode(MeasurementMode.fromGps);
                _centerPanelController.reverse();
              }),
              const SizedBox(height: 8),
              _buildMeasureButton(context, label: 'Entre deux points', icon: Icons.straighten, onPressed: () {
                widget.settingsService.setMeasurementMode(MeasurementMode.betweenPoints);
                _centerPanelController.reverse();
              }),
              const Divider(color: Colors.white24, height: 40),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildNavSection(String label, Color color, ValueNotifier<Waypoint?> wpNotifier, ValueNotifier<double> distNotifier, bool isNext) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      ValueListenableBuilder<Waypoint?>(
          valueListenable: wpNotifier,
          builder: (context, wp, _) {
            if (wp == null) return (isNext ? const Text('Aucun point', style: TextStyle(color: Colors.white38)) : const SizedBox.shrink());
            return ValueListenableBuilder<double>(
              valueListenable: distNotifier,
              builder: (context, dist, _) {
                final speed = widget.recordingService.averageSpeedGlobalMps.value;
                final eta = (speed > 0.5)
                    ? _formatDuration(dist / speed) : '--:--';
                return _buildNavigationInfo(name: wp.name, type: wp.category.value?.name ?? 'Point', distance: _formatDistance(dist), eta: eta, isNext: isNext);
              },
            );
          }),
    ]);
  }

  Widget _buildLiveStatsGrid(SettingsService settings) {
    final recording = widget.recordingService;
    return GridView.count(
      shrinkWrap: true, 
      physics: const NeverScrollableScrollPhysics(), 
      crossAxisCount: 3,
      mainAxisSpacing: 10, 
      crossAxisSpacing: 10,
      childAspectRatio: 0.9,
      children: [
        if (settings.navShowSpeed)
          AnimatedBuilder(animation: Listenable.merge([recording.currentSpeedMps, recording.averageSpeedDailyMps, recording.averageSpeedGlobalMps]), builder: (context, _) => _buildSpeedCard()),
        
        if (settings.navShowDailyDist)
          ValueListenableBuilder<double>(valueListenable: recording.dailyDistanceMeters, builder: (context, dist, _) => _buildStatCard('Aujourd\'hui', _formatDistanceKm(dist), Icons.today)),
        
        if (settings.navShowGpsAccuracy)
          ValueListenableBuilder<double>(valueListenable: recording.gpsAccuracyMeters, builder: (context, acc, _) => _buildStatCard('Précision GPS', '${acc.round()} m', Icons.satellite_alt)),
        
        if (settings.navShowTraceDist)
          ValueListenableBuilder<double>(valueListenable: recording.trackDistanceDoneMeters, builder: (context, done, _) =>
              ValueListenableBuilder<double>(valueListenable: recording.trackDistanceRemainingMeters, builder: (context, rem, _) =>
                  _buildStatCard('Trace', '${_formatDistanceKm(done)} parc.\n${_formatDistanceKm(rem)} rest.', Icons.route, multiLine: true))),
        
        if (settings.navShowPedometer)
          AnimatedBuilder(animation: widget.pedometerService, builder: (context, _) =>
              _buildStatCard('Podomètre', '${widget.pedometerService.steps}', Icons.directions_walk, isActive: widget.pedometerService.isActive, onTap: () => widget.pedometerService.togglePedometer())),
        
        if (settings.navShowSatellites)
          ValueListenableBuilder<String>(
            valueListenable: recording.gpsStatus, 
            builder: (context, status, _) => _buildStatCard(
              'Satellites', 
              status, 
              Icons.satellite_alt, 
              multiLine: status.contains('\n'),
              onTap: () => _showSatelliteDetails(context),
            )
          ),
        
        ValueListenableBuilder<String>(
          valueListenable: recording.solarTimes,
          builder: (context, times, _) => _buildStatCard(
            'Soleil', 
            times, 
            Icons.wb_sunny_outlined,
            multiLine: true,
          ),
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
        title: const Text('Satellites détectés', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: breakdown.entries.map((e) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4.0),
            child: Text('${e.key}: ${e.value}', style: const TextStyle(color: Colors.white70, fontSize: 16)),
          )).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('FERMER', style: TextStyle(color: Colors.greenAccent)),
          ),
        ],
      ),
    );
  }

  Widget _buildSpeedCard() {
    final recording = widget.recordingService;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, 
        children: [
          const Row(children: [Icon(Icons.speed, color: Colors.greenAccent, size: 14), SizedBox(width: 4), Text('Vitesse', style: TextStyle(color: Colors.white38, fontSize: 10))]),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(_formatSpeed(recording.currentSpeedMps.value), style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text('Jour: ${_formatSpeed(recording.averageSpeedDailyMps.value)}', style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w500)),
                  Text('Gén.: ${_formatSpeed(recording.averageSpeedGlobalMps.value)}', style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon, {bool isActive = false, VoidCallback? onTap, bool multiLine = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: isActive ? Colors.greenAccent : Colors.white10, width: isActive ? 2.0 : 1.0)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Icon(icon, color: isActive ? Colors.greenAccent : Colors.white38, size: 14), const SizedBox(width: 4), Expanded(child: Text(label, style: TextStyle(color: isActive ? Colors.greenAccent : Colors.white38, fontSize: 10), overflow: TextOverflow.ellipsis))]),
          Expanded(
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value, 
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white, 
                    fontSize: multiLine ? 11 : 16, 
                    fontWeight: FontWeight.bold
                  )
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  String _formatSpeed(double mps) => widget.settingsService.unitSystem == UnitSystem.metric ? (mps * 3.6).toStringAsFixed(1) : (mps * 2.23694).toStringAsFixed(1);
  String _formatDistance(double m) => widget.settingsService.unitSystem == UnitSystem.metric ? (m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m') : (m * 3.28084 >= 5280 ? '${(m * 3.28084 / 5280).toStringAsFixed(1)} mi' : '${(m * 3.28084).round()} ft');
  String _formatDistanceKm(double m) {
    if (widget.settingsService.unitSystem == UnitSystem.metric) {
      return '${(m / 1000).toStringAsFixed(2)} km';
    } else {
      return '${(m * 0.000621371).toStringAsFixed(2)} mi';
    }
  }
  String _formatDuration(double seconds) { if (seconds.isInfinite || seconds.isNaN || seconds < 0) return '--:--'; final d = Duration(seconds: seconds.round()); final h = d.inHours; final m = d.inMinutes.remainder(60); return h > 0 ? '${h}h ${m.toString().padLeft(2, '0')}m' : '${m}m'; }

  Widget _buildNavigationInfo({required String name, required String type, required String distance, required String eta, required bool isNext}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(8), border: Border.all(color: isNext ? Colors.greenAccent.withValues(alpha: 0.2) : Colors.blueAccent.withValues(alpha: 0.2))),
      child: Row(children: [
        Icon(isNext ? Icons.redo : Icons.flag, color: isNext ? Colors.greenAccent : Colors.blueAccent),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), Text(type, style: const TextStyle(color: Colors.white38, fontSize: 12))])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [Text(distance, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)), Text(eta, style: const TextStyle(color: Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.bold))]),
      ]),
    );
  }

  Widget _buildMeasureButton(BuildContext context, {required String label, required IconData icon, required VoidCallback onPressed}) => ElevatedButton.icon(onPressed: onPressed, icon: Icon(icon, size: 18), label: Text(label), style: ElevatedButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.05), foregroundColor: Colors.white, alignment: Alignment.centerLeft, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)));
  Widget _buildSettingsTile({required IconData icon, required String title, required String subtitle, required VoidCallback onTap}) => ListTile(leading: Icon(icon, color: Colors.greenAccent), title: Text(title, style: const TextStyle(color: Colors.white)), subtitle: Text(subtitle, style: const TextStyle(color: Colors.white60)), trailing: const Icon(Icons.chevron_right, color: Colors.white24), onTap: onTap);

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

  void _pushSettings(Widget screen) {
    Navigator.push(context, PageRouteBuilder(
      pageBuilder: (context, animation, secondaryAnimation) => screen,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return SlideTransition(
          position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(animation),
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
        child: const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.touch_app, color: Colors.white, size: 80),
          SizedBox(height: 20),
          Text('Bienvenue !', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
          SizedBox(height: 40),
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _HintGesture(icon: Icons.arrow_back, text: 'Swipe vers la droite\nParamètres'),
            _HintGesture(icon: Icons.arrow_forward, text: 'Swipe vers la gauche\nNavigation')
          ]),
          SizedBox(height: 60),
          Text('Appuyez pour commencer', style: TextStyle(color: Colors.white70)),
        ])),
      ),
    );
  }
}

class _HintGesture extends StatelessWidget {
  final IconData icon; final String text;
  const _HintGesture({required this.icon, required this.text});
  @override Widget build(BuildContext context) => Column(children: [Icon(icon, color: Colors.blueAccent, size: 40), const SizedBox(height: 8), Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white))]);
}

class _ModeBtn extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModeBtn({required this.label, required this.isSelected, required this.onTap});

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
