import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:isar_community/isar.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:vector_map_tiles/vector_map_tiles.dart';
import '../models/gps_point.dart';
import '../ui/waypoints/waypoint_edit_screen.dart';
import '../models/waypoint.dart' as wp_model;

import '../database/isar_service.dart';
import '../models/point_of_interest.dart';
import '../models/segment.dart';
import '../models/offline_map/offline_map.dart';
import '../search/local_search_engine.dart';
import '../utils/offline_map_download_service.dart';
import '../utils/settings_service.dart';
import '../utils/tile_cache_service.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:collection/collection.dart';
import '../utils/overpass_service.dart';
import '../utils/geo_utils.dart';
import '../utils/waypoint_icons.dart';
import 'osm_poi_categories.dart';
import '../ui/waypoints/osm_poi_detail_sheet.dart';
import '../recording/recording_service.dart';
import '../gpx/gpx_import_service.dart';
import '../gpx/gpx_models.dart';
import '../models/trace.dart';
import 'map_style.dart';
import 'map_view_model.dart';
import 'planning_controller.dart';
import 'vector_tile_source.dart';
import '../ui/settings/maps_settings_screen.dart';
import '../ui/tracks/roadmap_screen.dart';
import '../ui/tracks/track_edit_screen.dart';
import '../ui/tracks/track_manager_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    required this.viewModel,
    this.vectorTileSource,
    required this.isarService,
    required this.searchEngine,
    required this.ownerUuid,
    required this.settingsService,
    required this.recordingService,
    required this.panelScrollAnimation,
    required this.mapPageIndex,
    this.planningController,
    this.onPlanFinalized,
    this.initialCenter = const LatLng(45.8326, 6.8652),
    this.initialZoom = 13,
  });

  final MapViewModel viewModel;
  final VectorTileSource? vectorTileSource;
  final IsarService isarService;
  final LocalSearchEngine searchEngine;
  final SettingsService settingsService;
  final RecordingService recordingService;
  final String ownerUuid;
  // Anime le fondu du menu principal en fonction du carrousel de volets
  // latéraux (cf. MainNavigationScreen), pour qu'il ne soit jamais visible
  // en transparence sous un volet ouvert.
  final Animation<double> panelScrollAnimation;
  final int mapPageIndex;
  final PlanningController? planningController;
  final VoidCallback? onPlanFinalized;
  final LatLng initialCenter;
  final double initialZoom;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  late final MapController _mapController;
  final ValueNotifier<SegmentColorMode> _colorMode =
      ValueNotifier(SegmentColorMode.difficulty);

  bool _planningActive = false;
  bool _isFinalizing = false;
  bool _dynamicRotation = false;
  bool _followUser = true; // Mode suivi par défaut
  bool _isMapReady = false;
  MapCamera? _latestCamera;

  bool _tileLoadError = false;
  // Délai de grâce avant d'afficher le bandeau "hors connexion" : une tuile
  // isolée qui échoue (perte réseau très brève, DNS ponctuel...) pendant que
  // le reste continue de charger normalement ne doit pas déclencher l'alerte
  // -- voir _onTileError/_onTileLoaded.
  Timer? _tileErrorDebounceTimer;
  final StreamController<void> _tileResetController =
      StreamController<void>.broadcast();

  StreamSubscription? _compassSubscription;
  double? _currentHeading;

  final ValueNotifier<Set<String>> _selectedSegmentUuids = ValueNotifier({});

  late AnimationController _menuExpandController;
  bool _menuExpanded = false;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _initCompass();
    _menuExpandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    // Écoute de la position pour le mode suivi
    widget.recordingService.currentPosition.addListener(_onLocationUpdate);
    // Requêtes de recentrage ponctuelles (ex: "Localiser sur la carte"
    // depuis la fenêtre contextuelle d'un waypoint).
    widget.viewModel.centerRequest.addListener(_onCenterRequest);
    // Idem, mais cadré sur une étendue (ex: "Localiser sur la carte" depuis
    // la fiche d'une trace GPX).
    widget.viewModel.centerBoundsRequest.addListener(_onCenterBoundsRequest);
  }

  void _onCenterRequest() {
    final req = widget.viewModel.centerRequest.value;
    if (req == null) return;
    setState(() => _followUser = false);
    _mapController.move(LatLng(req.lat, req.lon), 17);
    widget.viewModel.centerRequest.value = null;
  }

  void _onCenterBoundsRequest() {
    final b = widget.viewModel.centerBoundsRequest.value;
    if (b == null) return;
    setState(() => _followUser = false);
    _mapController.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds(LatLng(b.minLat, b.minLon), LatLng(b.maxLat, b.maxLon)),
      padding: const EdgeInsets.all(40),
    ));
    widget.viewModel.centerBoundsRequest.value = null;
  }

  /// À appeler au début de toute action de la carte qui n'est pas un simple
  /// zoom/déplacement, pour faire disparaître le bouton "Retour" du mode
  /// "Localiser sur la carte" (cf. WaypointEditScreen et TrackEditScreen)
  /// s'il est affiché.
  void _dismissLocateBackButton() {
    if (widget.settingsService.locatingWaypointUuid != null) {
      widget.settingsService.dismissLocateWaypointBackButton();
    }
    if (widget.settingsService.locatingTraceUuid != null) {
      widget.settingsService.dismissLocateTraceBackButton();
    }
  }

  Future<void> _returnToWaypointPopup() async {
    final uuid = widget.settingsService.locatingWaypointUuid;
    final origin = widget.settingsService.locatingWaypointOrigin;
    widget.settingsService.dismissLocateWaypointBackButton();
    if (uuid == null) return;
    final wp = await widget.isarService.waypointByUuid(uuid);
    if (wp == null || !mounted) return;

    // Rouvre d'abord l'écran d'où "Localiser sur la carte" avait été
    // déclenché (Track Manager, Roadmap), pour que fermer la fiche du
    // waypoint révèle cet écran plutôt que la carte nue — symétrique au
    // Navigator.popUntil(isFirst) fait à l'aller.
    switch (origin) {
      case WaypointLocateOrigin.trackManager:
        Navigator.push(
            context, MaterialPageRoute(builder: (_) => const TrackManagerScreen()));
      case WaypointLocateOrigin.roadmap:
        Navigator.push(
            context, MaterialPageRoute(builder: (_) => const RoadmapScreen()));
      case WaypointLocateOrigin.map:
        break;
    }
    if (!mounted) return;

    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (context) => WaypointEditScreen(
        waypoint: wp,
        isarService: widget.isarService,
        locateOrigin: origin,
      ),
    ).then((_) => widget.viewModel.refreshNow());
  }

  /// Symétrique de [_returnToWaypointPopup] pour une trace GPX localisée
  /// depuis sa fiche : il n'y a qu'un seul point d'entrée (TrackEditScreen),
  /// donc pas de switch sur une origine, juste une repousse directe.
  Future<void> _returnToTracePopup() async {
    final uuid = widget.settingsService.locatingTraceUuid;
    await widget.settingsService.dismissLocateTraceBackButton();
    if (uuid == null || !mounted) return;
    final trace = await widget.isarService.traceByUuid(uuid);
    if (trace == null || !mounted) return;
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => TrackEditScreen(trace: trace)));
  }

  void _onLocationUpdate() {
    if (!mounted || !_isMapReady) return;

    final pos = widget.recordingService.currentPosition.value;
    if (pos == null) return;

    if (_followUser) {
      debugPrint(
          'MapScreen: AUTO-CENTERING at ${pos.latitude}, ${pos.longitude}');
      _mapController.move(
          LatLng(pos.latitude, pos.longitude), _mapController.camera.zoom);
    }

    // On force le rebuild pour mettre à jour le marqueur de position (LocationMarkerLayer)
    setState(() {});
  }

  void _initCompass() {
    _compassSubscription = FlutterCompass.events?.listen((event) {
      if (!mounted) return;
      setState(() {
        _currentHeading = event.heading;
      });
      if (_dynamicRotation && event.heading != null) {
        _mapController.rotate(-event.heading!);
      }
    });
  }

  @override
  void dispose() {
    widget.recordingService.currentPosition.removeListener(_onLocationUpdate);
    widget.viewModel.centerRequest.removeListener(_onCenterRequest);
    widget.viewModel.centerBoundsRequest.removeListener(_onCenterBoundsRequest);
    _colorMode.dispose();
    _selectedSegmentUuids.dispose();
    _compassSubscription?.cancel();
    _menuExpandController.dispose();
    _tileResetController.close();
    _tileErrorDebounceTimer?.cancel();
    super.dispose();
  }

  void _onTileError(TileImage tile, Object error, StackTrace? stackTrace) {
    if (!mounted || _tileLoadError) return;
    // Ne pas afficher le bandeau immédiatement sur une seule tuile en échec :
    // avec plusieurs tuiles chargées en parallèle, une coupure réseau très
    // brève (quelques centaines de ms) en fait facilement échouer une alors
    // que les autres réussissent -- on attend de voir si l'échec persiste
    // avant d'alerter. `_onTileLoaded` annule ce délai dès qu'une tuile
    // charge avec succès entre-temps.
    _tileErrorDebounceTimer ??= Timer(const Duration(seconds: 3), () {
      _tileErrorDebounceTimer = null;
      if (mounted) setState(() => _tileLoadError = true);
    });
  }

  void _onTileLoaded() {
    _tileErrorDebounceTimer?.cancel();
    _tileErrorDebounceTimer = null;
    if (mounted && _tileLoadError) {
      setState(() => _tileLoadError = false);
    }
  }

  void _retryTiles() {
    _tileErrorDebounceTimer?.cancel();
    _tileErrorDebounceTimer = null;
    setState(() => _tileLoadError = false);
    _tileResetController.add(null);
  }

  void _reloadViewportData(MapCamera camera) {
    final bounds = camera.visibleBounds;
    widget.viewModel.onViewportChanged(
      minLat: bounds.south,
      maxLat: bounds.north,
      minLon: bounds.west,
      maxLon: bounds.east,
      activeGpxNames: widget.settingsService.activeGpxNames,
      zoom: camera.zoom,
      osmPoisEnabled: widget.settingsService.showOsmPois,
      osmPoiCategoryIds: widget.settingsService.enabledOsmPoiCategoryIds,
      roadmapTraceName: widget.settingsService.roadmapTraceName,
      showEveryWaypoint: widget.settingsService.showEveryWaypoint,
      showGpxWaypoints: widget.settingsService.showGpxWaypoints,
    );
    if (widget.settingsService.mapCreationStep == MapCreationStep.stretchArea &&
        widget.settingsService.mapOrigin != null) {
      widget.settingsService
          .updateMapTarget(camera.center.latitude, camera.center.longitude);
    }
  }

  void _onPositionChanged(MapCamera camera, bool hasGesture) {
    if (hasGesture && _followUser) {
      setState(() => _followUser = false);
    }

    setState(() => _latestCamera = camera);
    widget.viewModel.liveCamera.value = (
      lat: camera.center.latitude,
      lon: camera.center.longitude,
      zoom: camera.zoom,
    );
    _reloadViewportData(camera);
    widget.planningController
        ?.updateCandidateSegments(widget.viewModel.segments.value);

    if (widget.recordingService.isActive ||
        widget.settingsService.activeGpxNames.isNotEmpty) {
      context.read<TileCacheService>().checkAndEvict(context);
    }
  }

  void _onTap(TapPosition tapPosition, LatLng point) {
    _dismissLocateBackButton();
    if (_planningActive) {
      widget.planningController?.addTapPoint(point.latitude, point.longitude);
      return;
    }

    if (widget.settingsService.displayMode == DisplayMode.mesh) {
      // Hit testing pour les segments du mesh
      _handleMeshTap(point);
    }
  }

  void _handleMeshTap(LatLng point) {
    // On cherche le segment le plus proche du point cliqué
    // Seuil de proximité augmenté pour faciliter le clic sur mobile (~30-40 mètres)
    const thresholdMeters = 40.0;

    Segment? closestSegment;
    double minDistance = double.infinity;

    debugPrint(
        'MapScreen: Hit-testing for mesh selection at ${point.latitude}, ${point.longitude}');

    for (final segment in widget.viewModel.segments.value) {
      final polyline = segment.points
          .map((p) => (lat: p.latitude, lon: p.longitude))
          .toList();

      final snap = GeoUtils.snapToPolyline(
          point.latitude, point.longitude, polyline, thresholdMeters);

      if (snap != null) {
        final dist = geo.Geolocator.distanceBetween(
            point.latitude, point.longitude, snap.lat, snap.lon);
        if (dist < minDistance) {
          minDistance = dist;
          closestSegment = segment;
        }
      }
    }

    if (closestSegment != null) {
      debugPrint('MapScreen: Segment selected: ${closestSegment.localUuid}');
      final currentSelected = Set<String>.from(_selectedSegmentUuids.value);
      if (currentSelected.contains(closestSegment.localUuid)) {
        currentSelected.remove(closestSegment.localUuid);
      } else {
        currentSelected.add(closestSegment.localUuid);
      }
      _selectedSegmentUuids.value = currentSelected;
    } else {
      debugPrint('MapScreen: No segment found near tap.');
    }
  }

  Future<void> _resegmentTraces() async {
    final scaffold = ScaffoldMessenger.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final importService = GpxImportService(
        isarService: widget.isarService,
        searchEngine: widget.searchEngine,
      );
      await importService.resegmentAll();
      if (mounted) Navigator.pop(context);
      scaffold.showSnackBar(const SnackBar(content: Text('Mesh recalculé !')));
    } catch (e) {
      if (mounted) Navigator.pop(context);
      scaffold.showSnackBar(SnackBar(content: Text('Erreur : $e')));
    }
  }

  void _createTraceFromMesh() {
    final selectedUuids = _selectedSegmentUuids.value;
    if (selectedUuids.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Sélectionnez d\'abord des segments sur la carte.')),
      );
      return;
    }

    final segments = widget.viewModel.segments.value
        .where((s) => selectedUuids.contains(s.localUuid))
        .toList();

    // On ouvre le dialogue d'enregistrement
    _showSaveMeshTraceDialog(segments);
  }

  void _deleteSelectedSegments() {
    // ... existing logic ...
  }

  void _handleToggleRecording() async {
    final recording = widget.recordingService;
    final settings = widget.settingsService;

    if (recording.isActive) {
      // STOP
      _showStopRecordingDialog();
    } else {
      // START
      if (!settings.locationEnabled) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('La localisation n\'est pas activée.'),
            backgroundColor: Colors.orangeAccent,
          ),
        );
        return;
      }

      await recording.start(ownerUuid: widget.ownerUuid);
      if (mounted) setState(() {});
    }
  }

  void _showStopRecordingDialog() {
    final nameController = TextEditingController(
      text: 'Randonnée du ${_formatDate(DateTime.now())}',
    );
    final descController = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Enregistrer la trace',
            style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Nom de la trace',
                labelStyle: TextStyle(color: Colors.white70),
              ),
            ),
            TextField(
              controller: descController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Description',
                labelStyle: TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => _confirmDiscardRecording(context),
            child:
                const Text('ANNULER', style: TextStyle(color: Colors.white38)),
          ),
          TextButton(
            onPressed: () => _confirmSaveRecording(
                context, nameController.text, descController.text),
            child: const Text('ENREGISTRER',
                style: TextStyle(color: Colors.greenAccent)),
          ),
        ],
      ),
    );
  }

  void _confirmDiscardRecording(BuildContext dialogContext) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Annuler l\'enregistrement ?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
            'Toutes les données de cette session seront perdues.',
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('REPRENDRE')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('CONFIRMER ANNULATION',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final draft = await widget.recordingService.findAbandonedDraft();
      if (draft != null) {
        await widget.recordingService.discard(draft.sessionUuid);
      }
      if (mounted) {
        Navigator.pop(dialogContext); // Ferme le dialogue d'édition
        setState(() {});
      }
    }
  }

  void _confirmSaveRecording(
      BuildContext dialogContext, String name, String desc) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Enregistrer la trace ?',
            style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('RETOUR')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('CONFIRMER',
                style: TextStyle(color: Colors.greenAccent)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        final result = await widget.recordingService.stop(
          ownerUuid: widget.ownerUuid,
          searchEngine: widget.searchEngine,
          traceName: name,
        );

        // Mise à jour du chemin source si un dossier d'enregistrement est défini
        final subPath = widget.settingsService.recordingSubPath;
        if (subPath != null) {
          final fileName = '$name.gpx';
          final fullPath = p.join(subPath, fileName);

          result.trace.sourceFilePath = fullPath;
          await widget.isarService.saveTrace(result.trace);

          debugPrint('Recording: Trace source path set to $fullPath');
        }

        if (mounted) {
          Navigator.pop(dialogContext); // Ferme le dialogue d'édition
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Trace enregistrée avec succès !')),
          );
          setState(() {});
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Erreur lors de l\'enregistrement : $e')),
          );
        }
      }
    }
  }

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  void _showSaveMeshTraceDialog(List<Segment> segments) {
    final nameController = TextEditingController();
    final descController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Créer une trace GPX',
            style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Les segments sélectionnés seront fusionnés dans une nouvelle trace.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: nameController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Nom de la trace',
                labelStyle: TextStyle(color: Colors.white70),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24)),
              ),
            ),
            TextField(
              controller: descController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Description',
                labelStyle: TextStyle(color: Colors.white70),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ANNULER'),
          ),
          TextButton(
            onPressed: () async {
              if (nameController.text.isEmpty) return;
              await _saveMergedTrace(
                  nameController.text, descController.text, segments);
              if (mounted) {
                Navigator.pop(context);
                _selectedSegmentUuids.value = {}; // Reset sélection
              }
            },
            child: const Text('ENREGISTRER',
                style: TextStyle(color: Colors.greenAccent)),
          ),
        ],
      ),
    );
  }

  Future<void> _saveMergedTrace(
      String name, String description, List<Segment> selectedSegments) async {
    // Pour fusionner, on récupère tous les points de tous les segments sélectionnés
    // Note: cette fusion est "brute", elle ne garantit pas la continuité topologique parfaite
    // si les segments ne sont pas ordonnés manuellement, mais c'est un début.
    final List<GpxTrackPoint> allPoints = [];
    for (final s in selectedSegments) {
      for (final p in s.points) {
        allPoints.add(GpxTrackPoint(
          latitude: p.latitude,
          longitude: p.longitude,
          elevation: p.altitude,
          time: DateTime.now(),
        ));
      }
    }

    final importService = GpxImportService(
      isarService: widget.isarService,
      searchEngine: widget.searchEngine,
    );

    try {
      // On simule un import à partir des points concaténés
      // On crée le XML GPX minimal
      final gpxContent = _buildGpxString(name, description, allPoints);

      await importService.importXmlString(
        gpxContent,
        ownerUuid: widget.ownerUuid,
        traceNameOverride: name,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Trace "$name" enregistrée avec succès.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur lors de l\'enregistrement : $e')),
        );
      }
    }
  }

  String _buildGpxString(
      String name, String description, List<GpxTrackPoint> points) {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln('<gpx version="1.1" creator="Meshiker">');
    buffer.writeln(
        '  <metadata><name>$name</name><desc>$description</desc></metadata>');
    buffer.writeln('  <trk><name>$name</name><trkseg>');
    for (final p in points) {
      buffer.writeln('    <trkpt lat="${p.latitude}" lon="${p.longitude}">');
      if (p.elevation != null) {
        buffer.writeln('      <ele>${p.elevation}</ele>');
      }
      buffer.writeln('    </trkpt>');
    }
    buffer.writeln('  </trkseg></trk>');
    buffer.writeln('</gpx>');
    return buffer.toString();
  }

  Future<void> _finalizePlan() async {
    final controller = widget.planningController;
    if (controller == null || controller.points.value.length < 2) return;

    setState(() => _isFinalizing = true);
    try {
      await controller.finalizePlan(
        ownerUuid: widget.ownerUuid,
        isarService: widget.isarService,
        searchEngine: widget.searchEngine,
      );
      setState(() => _planningActive = false);
      widget.onPlanFinalized?.call();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Impossible de finaliser le plan : $e')),
      );
    } finally {
      if (mounted) setState(() => _isFinalizing = false);
    }
  }

  void _toggleMenu() {
    _dismissLocateBackButton();
    setState(() {
      _menuExpanded = !_menuExpanded;
      if (_menuExpanded) {
        _menuExpandController.forward();
      } else {
        _menuExpandController.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation:
          Listenable.merge([widget.settingsService, _menuExpandController]),
      builder: (context, _) {
        final bottomMenuHeight = 80.0 + (_menuExpandController.value * 80.0);

        return Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: widget.initialCenter,
                initialZoom: widget.initialZoom,
                onTap: _onTap,
                onLongPress: (tapPosition, point) {
                  _dismissLocateBackButton();
                  showDialog(
                    context: context,
                    barrierColor: Colors.black.withValues(alpha: 0.7),
                    builder: (context) => WaypointEditScreen(
                      latitude: point.latitude,
                      longitude: point.longitude,
                      isarService: widget.isarService,
                      associatedGpxName: widget.settingsService.roadmapTraceName,
                    ),
                  ).then((_) => widget.viewModel.refreshNow());
                },
                onPositionChanged: _onPositionChanged,
                onMapReady: () {
                  setState(() {
                    _isMapReady = true;
                    _latestCamera = _mapController.camera;
                  });
                  widget.viewModel.liveCamera.value = (
                    lat: _mapController.camera.center.latitude,
                    lon: _mapController.camera.center.longitude,
                    zoom: _mapController.camera.zoom,
                  );
                  _reloadViewportData(_mapController.camera);

                  // Correction technique : Recentrer immédiatement si la position est connue au chargement
                  final pos = widget.recordingService.currentPosition.value;
                  if (pos != null && _followUser) {
                    debugPrint('MapScreen: Initial re-centering in onMapReady');
                    _mapController.move(LatLng(pos.latitude, pos.longitude),
                        widget.initialZoom);
                  }
                },
              ),
              children: [
                if (widget.vectorTileSource?.theme != null)
                  VectorTileLayer(
                    theme: widget.vectorTileSource!.theme!,
                    tileProviders: widget.vectorTileSource!.tileProviders,
                  )
                else
                  _buildDynamicTileLayer(),
                if (widget.settingsService.displayMode == DisplayMode.mesh)
                  _MeshLayer(
                    viewModel: widget.viewModel,
                    selectedUuidsNotifier: _selectedSegmentUuids,
                  )
                else
                  _ActiveTracesLayer(
                    viewModel: widget.viewModel,
                    isarService: widget.isarService,
                    strokeWidth: widget.settingsService.traceStrokeWidth,
                  ),
                _PoisLayer(viewModel: widget.viewModel),
                if (widget.settingsService.showAllWaypoints ||
                    widget.settingsService.showEveryWaypoint)
                  _WaypointsLayer(
                    viewModel: widget.viewModel,
                    settings: widget.settingsService,
                    isarService: widget.isarService,
                    recordingService: widget.recordingService,
                  ),
                _OsmPoisLayer(
                  viewModel: widget.viewModel,
                  isarService: widget.isarService,
                  settings: widget.settingsService,
                ),
                if (widget.planningController != null)
                  _PlanningLayer(controller: widget.planningController!),
                _LiveTrackLayer(
                  recordingService: widget.recordingService,
                  strokeWidth: widget.settingsService.traceStrokeWidth,
                ),
                _LocationMarkerLayer(
                    recordingService: widget.recordingService,
                    heading: _currentHeading),
                if (widget.settingsService.measurementMode !=
                    MeasurementMode.none)
                  _MeasurementLayer(
                    mode: widget.settingsService.measurementMode,
                    p1: widget.settingsService.measurePoint1,
                    p2: widget.settingsService.measurePoint2,
                    currentPos: widget.recordingService.currentPosition.value,
                    mapCenter: _mapController.camera.center,
                  ),
                const RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution(
                        "Contributeurs de la toile d'araignee"),
                  ],
                ),
              ],
            ),
            if (widget.settingsService.locatingWaypointUuid != null ||
                widget.settingsService.locatingTraceUuid != null)
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                left: 12,
                child: Material(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(24),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: () => widget.settingsService.locatingTraceUuid != null
                        ? _returnToTracePopup()
                        : _returnToWaypointPopup(),
                    child: const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.arrow_back, color: Colors.white, size: 18),
                          SizedBox(width: 6),
                          Text('Retour',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (_tileLoadError && widget.vectorTileSource?.theme == null)
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                left: 12,
                right: 12,
                child: Material(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.cloud_off,
                            color: Colors.white70, size: 18),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            "Pas de connexion internet : carte indisponible",
                            style: TextStyle(color: Colors.white, fontSize: 12),
                          ),
                        ),
                        TextButton(
                          onPressed: _retryTiles,
                          child: const Text('Réessayer',
                              style: TextStyle(color: Colors.greenAccent)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (widget.settingsService.showScale && _latestCamera != null)
              Positioned(
                bottom: bottomMenuHeight + 10,
                left: 0,
                right: 0,
                child: Center(
                  child: AnimatedBuilder(
                    // Même fondu que le menu principal, pour que l'échelle
                    // disparaisse en même temps que lui sous un volet latéral.
                    animation: widget.panelScrollAnimation,
                    builder: (context, child) {
                      final distance = (widget.panelScrollAnimation.value -
                              widget.mapPageIndex)
                          .abs()
                          .clamp(0.0, 1.0);
                      final menuVisibility = 1.0 - distance;
                      return Opacity(opacity: menuVisibility, child: child);
                    },
                    child: _MapScaleWidget(
                      camera: _latestCamera!,
                      color: Colors.black,
                      unitSystem: widget.settingsService.unitSystem,
                    ),
                  ),
                ),
              ),
            if (_isMapReady && _latestCamera != null)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: widget.settingsService.pickingStartupCenter
                    ? _StartupCenterPickerMenu(
                        settings: widget.settingsService,
                        center: _mapController.camera.center,
                        zoom: _mapController.camera.zoom,
                      )
                    : widget.settingsService.mapCreationStep !=
                        MapCreationStep.none
                    ? _MapCreationMenu(
                        settings: widget.settingsService,
                        center: _mapController.camera.center,
                      )
                    : AnimatedBuilder(
                        animation: widget.panelScrollAnimation,
                        builder: (context, child) {
                          // Fondu du menu principal à mesure qu'un volet latéral
                          // recouvre l'écran, pour qu'il ne transparaisse pas
                          // sous un volet dont l'opacité est réduite.
                          final distance = (widget.panelScrollAnimation.value -
                                  widget.mapPageIndex)
                              .abs()
                              .clamp(0.0, 1.0);
                          final menuVisibility = 1.0 - distance;
                          return IgnorePointer(
                            ignoring: menuVisibility < 0.05,
                            child:
                                Opacity(opacity: menuVisibility, child: child),
                          );
                        },
                        child: GestureDetector(
                          onVerticalDragUpdate: (details) {
                            if ((details.primaryDelta ?? 0) < -10 &&
                                !_menuExpanded) {
                              _toggleMenu();
                            } else if ((details.primaryDelta ?? 0) > 10 &&
                                _menuExpanded) {
                              _toggleMenu();
                            }
                          },
                          child: _BottomControlBar(
                            opacity: widget.settingsService.mainMenuOpacity,
                            reversePanels: widget.settingsService.reversePanels,
                            displayMode: widget.settingsService.displayMode,
                            heading: _currentHeading,
                            dynamicRotation: _dynamicRotation,
                            locationActive:
                                widget.settingsService.locationEnabled,
                            camera: _latestCamera!,
                            unitSystem: widget.settingsService.unitSystem,
                            measurementMode:
                                widget.settingsService.measurementMode,
                            measurePoint1: widget.settingsService.measurePoint1,
                            measurePoint2: widget.settingsService.measurePoint2,
                            currentPosition:
                                widget.recordingService.currentPosition.value,
                            expanded: _menuExpanded,
                            expandProgress: _menuExpandController.value,
                            showAllWaypoints:
                                widget.settingsService.showAllWaypoints,
                            showEveryWaypoint:
                                widget.settingsService.showEveryWaypoint,
                            showAllGpx: widget.settingsService.showAllGpx,
                            showMesh: widget.settingsService.showMesh,
                            onToggleRotation: () {
                              _dismissLocateBackButton();
                              setState(
                                  () => _dynamicRotation = !_dynamicRotation);
                              if (!_dynamicRotation) _mapController.rotate(0);
                            },
                            onRecenter: () {
                              // Recentrer reste une manipulation de la carte
                              // (déplacement) : ne dissipe pas le bouton
                              // "Retour" du mode localisation de waypoint.
                              final pos =
                                  widget.recordingService.currentPosition.value;
                              setState(() => _followUser = true);
                              if (pos != null) {
                                _mapController.move(
                                    LatLng(pos.latitude, pos.longitude),
                                    _mapController.camera.zoom);
                              } else {
                                _mapController.move(widget.initialCenter,
                                    _mapController.camera.zoom);
                              }
                            },
                            onToggleLocation: () {
                              _dismissLocateBackButton();
                              final newStatus =
                                  !widget.settingsService.locationEnabled;
                              widget.settingsService
                                  .setLocationEnabled(newStatus);
                              if (newStatus) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('Localisation activée')),
                                );
                              }
                            },
                            onCycleMap: () {
                              _dismissLocateBackButton();
                              widget.settingsService.cycleMap();
                            },
                            onZoomIn: () {
                              // Zoom : manipulation de la carte, cf. onRecenter.
                              _mapController.move(_mapController.camera.center,
                                  _mapController.camera.zoom + 1);
                            },
                            onZoomOut: () {
                              _mapController.move(_mapController.camera.center,
                                  _mapController.camera.zoom - 1);
                            },
                            onValidatePoint: () {
                              _dismissLocateBackButton();
                              final center = _mapController.camera.center;
                              if (widget.settingsService.measurePoint1 ==
                                  null) {
                                widget.settingsService.setMeasurePoint1(
                                    center.latitude, center.longitude);
                              } else {
                                widget.settingsService.setMeasurePoint2(
                                    center.latitude, center.longitude);
                              }
                            },
                            onCancelMeasure: () {
                              _dismissLocateBackButton();
                              widget.settingsService.clearMeasurement();
                            },
                            onToggleWaypoints: () {
                              _dismissLocateBackButton();
                              // Un appui simple pendant le mode "intégralité"
                              // (appui long) y met fin et révèle l'affichage
                              // de départ, sans toucher au réglage on/off
                              // normal -- ce n'est qu'ensuite qu'un nouvel
                              // appui simple bascule ce réglage.
                              if (widget.settingsService.showEveryWaypoint) {
                                widget.settingsService
                                    .setShowEveryWaypoint(false);
                              } else {
                                widget.settingsService.setShowAllWaypoints(
                                    !widget.settingsService.showAllWaypoints);
                              }
                              widget.viewModel.reloadWaypointDisplay(
                                roadmapTraceName:
                                    widget.settingsService.roadmapTraceName,
                                showEveryWaypoint:
                                    widget.settingsService.showEveryWaypoint,
                                showGpxWaypoints:
                                    widget.settingsService.showGpxWaypoints,
                              );
                            },
                            onLongPressWaypoints: () {
                              _dismissLocateBackButton();
                              widget.settingsService.setShowEveryWaypoint(true);
                              widget.viewModel.reloadWaypointDisplay(
                                roadmapTraceName:
                                    widget.settingsService.roadmapTraceName,
                                showEveryWaypoint: true,
                                showGpxWaypoints:
                                    widget.settingsService.showGpxWaypoints,
                              );
                            },
                            onToggleGpx: () {
                              _dismissLocateBackButton();
                              widget.settingsService.setShowAllGpx(
                                  !widget.settingsService.showAllGpx);
                            },
                            onToggleCompass: _dismissLocateBackButton,
                            onResegmentMesh: () {
                              _dismissLocateBackButton();
                              _resegmentTraces();
                            },
                            onCreateTrace: () {
                              _dismissLocateBackButton();
                              _createTraceFromMesh();
                            },
                            onClearSelection: () {
                              _dismissLocateBackButton();
                              _selectedSegmentUuids.value = {};
                            },
                            onDeleteSelected: () {
                              _dismissLocateBackButton();
                              _deleteSelectedSegments();
                            },
                            onToggleRecording: () {
                              _dismissLocateBackButton();
                              _handleToggleRecording();
                            },
                            isRecording: widget.recordingService.isActive,
                          ),
                        ),
                      ),
              ),
            if (widget.settingsService.waypointSelectionMode)
              Positioned(
                top: 100,
                left: 20,
                right: 20,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.blueAccent.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 8)
                    ],
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.touch_app, color: Colors.white),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'Touchez un waypoint sur la carte pour le définir comme destination',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () => widget.settingsService
                            .setWaypointSelectionMode(false),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
              ),
            if (widget.settingsService.measurementMode !=
                    MeasurementMode.none ||
                widget.settingsService.mapCreationStep !=
                    MapCreationStep.none ||
                widget.settingsService.pickingStartupCenter)
              const IgnorePointer(
                child: Center(
                  child: Icon(Icons.add, color: Colors.red, size: 40),
                ),
              ),
            if (widget.settingsService.mapCreationStep != MapCreationStep.none)
              _MapCreationOverlay(
                step: widget.settingsService.mapCreationStep,
                origin: widget.settingsService.mapOrigin,
                target: widget.settingsService.mapTarget,
                camera: _latestCamera!,
                onAdjust: widget.settingsService.adjustArea,
              ),
            if (widget.planningController != null)
              Positioned(
                bottom: bottomMenuHeight + 20,
                left: 0,
                right: 0,
                child: _PlanningControls(
                  controller: widget.planningController!,
                  active: _planningActive,
                  busy: _isFinalizing,
                  onToggleActive: () =>
                      setState(() => _planningActive = !_planningActive),
                  onFinalize: _finalizePlan,
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildDynamicTileLayer() {
    final source = MapStyle.resolveTileSource(widget.settingsService);

    return TileLayer(
      urlTemplate: source.url,
      subdomains: const ['a', 'b', 'c'],
      userAgentPackageName: 'com.meshiker.app',
      tileProvider: _buildTileProvider(source.id, onTileLoaded: _onTileLoaded),
      errorTileCallback: _onTileError,
      reset: _tileResetController.stream,
    );
  }

  /// Sert les tuiles depuis les cartes hors-ligne déjà téléchargées pour ce
  /// fond de carte ([sourceId]) quand elles sont disponibles localement, et
  /// ne retombe sur le réseau que pour les tuiles manquantes -- c'est ce qui
  /// rend une zone téléchargée ("Créer une carte") réellement consultable
  /// hors connexion. Les tuiles réseau restantes passent par le cache disque
  /// de [TileCacheService] (voir [_OfflineAwareTileProvider]).
  TileProvider _buildTileProvider(String sourceId, {required VoidCallback onTileLoaded}) {
    final headers = {'User-Agent': 'Meshiker/1.0'};
    final completedMaps = widget.isarService.isar.offlineMaps
        .filter()
        .sourceIdEqualTo(sourceId)
        .and()
        .isDownloadingEqualTo(false)
        .and()
        .isErrorEqualTo(false)
        .findAllSync();

    final localDirs = completedMaps
        .where((m) => m.localPath != null)
        .map((m) => Directory(m.localPath!))
        .toList();

    return _OfflineAwareTileProvider(
        localDirs: localDirs,
        headers: headers,
        sourceId: sourceId,
        onTileLoaded: onTileLoaded);
  }
}

/// Consulte d'abord les tuiles téléchargées en local (voir
/// [OfflineMapDownloadService]) avant de retomber sur le réseau, tuile par
/// tuile -- une même zone peut ainsi être partiellement téléchargée sans
/// empêcher l'affichage du reste depuis le réseau quand il est disponible.
/// Les tuiles réseau passent par [_CachedTileImageProvider], qui les
/// persiste sur disque (contrairement à un [NetworkImage] brut, qui ne
/// passe que par l'`ImageCache` en mémoire de Flutter -- trop petit et non
/// persistant pour une carte de la taille d'une randonnée).
class _OfflineAwareTileProvider extends TileProvider {
  _OfflineAwareTileProvider({
    required this.localDirs,
    required this.sourceId,
    required this.onTileLoaded,
    super.headers,
  });

  final List<Directory> localDirs;
  final String sourceId;
  final VoidCallback onTileLoaded;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    for (final dir in localDirs) {
      final file = OfflineMapDownloadService.tileFile(
          dir, coordinates.z, coordinates.x, coordinates.y);
      if (file.existsSync()) return FileImage(file);
    }
    return _CachedTileImageProvider(
      url: getTileUrl(coordinates, options),
      sourceId: sourceId,
      z: coordinates.z,
      x: coordinates.x,
      y: coordinates.y,
      headers: headers,
      onLoaded: onTileLoaded,
    );
  }
}

/// [ImageProvider] pour une tuile réseau qui persiste le résultat sur disque
/// dans le dossier géré par [TileCacheService] (tmp/tile_cache/sourceId/
/// z/x/y.tile), et le relit directement si déjà présent -- évite de
/// retélécharger une tuile déjà vue tant que [TileCacheService.checkAndEvict]
/// ne l'a pas purgée. Namespacé par [sourceId] : deux fonds de carte peuvent
/// avoir des tuiles différentes pour les mêmes z/x/y.
class _CachedTileImageProvider extends ImageProvider<_CachedTileImageProvider> {
  const _CachedTileImageProvider({
    required this.url,
    required this.sourceId,
    required this.z,
    required this.x,
    required this.y,
    required this.headers,
    required this.onLoaded,
  });

  final String url;
  final String sourceId;
  final int z;
  final int x;
  final int y;
  final Map<String, String>? headers;
  final VoidCallback onLoaded;

  @override
  Future<_CachedTileImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<_CachedTileImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
      _CachedTileImageProvider key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1.0,
      debugLabel: url,
      informationCollector: () => <DiagnosticsNode>[ErrorDescription('Tile: $url')],
    );
  }

  Future<File> _cacheFile() async {
    final cacheDir = await TileCacheService.cacheDirectory();
    return File('${cacheDir.path}/$sourceId/$z/$x/$y.tile');
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final cacheFile = await _cacheFile();

    if (await cacheFile.exists()) {
      final bytes = await cacheFile.readAsBytes();
      if (bytes.isNotEmpty) {
        try {
          final codec = decode(await ui.ImmutableBuffer.fromUint8List(bytes));
          onLoaded();
          return codec;
        } catch (_) {
          // Fichier cache corrompu (écriture interrompue, etc.) : on
          // l'ignore et retélécharge plutôt que de faire échouer la tuile.
        }
      }
    }

    // Timeout court plutôt que d'attendre indéfiniment une connexion qui ne
    // répondra pas : sans lui, une coupure réseau totale pouvait laisser la
    // requête pendante bien au-delà du délai de grâce du bandeau "hors
    // connexion" (voir MapScreen._onTileError), qui ne se déclenchait alors
    // qu'au bout d'un temps très variable selon le timeout par défaut de la
    // plateforme.
    final response = await http
        .get(Uri.parse(url), headers: headers)
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception(
          'Échec du téléchargement de la tuile ($url) : HTTP ${response.statusCode}');
    }
    final bytes = response.bodyBytes;
    unawaited(_writeToCache(cacheFile, bytes));
    final codec = decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    onLoaded();
    return codec;
  }

  Future<void> _writeToCache(File cacheFile, Uint8List bytes) async {
    try {
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsBytes(bytes, flush: false);
    } catch (e) {
      // Dossier cache supprimé entre-temps, disque plein, etc. -- non
      // bloquant, la tuile reste affichée, juste pas mise en cache.
      debugPrint('TileCache: échec écriture cache pour $url: $e');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is _CachedTileImageProvider &&
      other.sourceId == sourceId &&
      other.z == z &&
      other.x == x &&
      other.y == y;

  @override
  int get hashCode => Object.hash(sourceId, z, x, y);
}

class _BottomControlBar extends StatelessWidget {
  final double opacity;
  final bool reversePanels;
  final DisplayMode displayMode;
  final double? heading;
  final bool dynamicRotation;
  final bool locationActive;
  final MapCamera camera;
  final UnitSystem unitSystem;
  final MeasurementMode measurementMode;
  final ({double lat, double lon})? measurePoint1;
  final ({double lat, double lon})? measurePoint2;
  final geo.Position? currentPosition;

  final bool expanded;
  final double expandProgress;
  final bool showAllWaypoints;
  final bool showEveryWaypoint;
  final bool showAllGpx;
  final bool showMesh;

  final VoidCallback onToggleRotation;
  final VoidCallback onRecenter;
  final VoidCallback onToggleLocation;
  final VoidCallback onCycleMap;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onValidatePoint;
  final VoidCallback onCancelMeasure;

  final VoidCallback onToggleWaypoints;
  final VoidCallback onLongPressWaypoints;
  final VoidCallback onToggleGpx;
  final VoidCallback onToggleCompass;
  final VoidCallback onResegmentMesh;
  final VoidCallback onCreateTrace;
  final VoidCallback onClearSelection;
  final VoidCallback onDeleteSelected;
  final VoidCallback onToggleRecording;
  final bool isRecording;

  const _BottomControlBar({
    required this.opacity,
    required this.reversePanels,
    required this.displayMode,
    required this.heading,
    required this.dynamicRotation,
    required this.locationActive,
    required this.camera,
    required this.unitSystem,
    required this.measurementMode,
    this.measurePoint1,
    this.measurePoint2,
    this.currentPosition,
    required this.expanded,
    required this.expandProgress,
    required this.showAllWaypoints,
    required this.showEveryWaypoint,
    required this.showAllGpx,
    required this.showMesh,
    required this.onToggleRotation,
    required this.onRecenter,
    required this.onToggleLocation,
    required this.onCycleMap,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onValidatePoint,
    required this.onCancelMeasure,
    required this.onToggleWaypoints,
    required this.onLongPressWaypoints,
    required this.onToggleGpx,
    required this.onToggleCompass,
    required this.onResegmentMesh,
    required this.onCreateTrace,
    required this.onClearSelection,
    required this.onDeleteSelected,
    required this.onToggleRecording,
    required this.isRecording,
  });

  // Inverse l'ordre horizontal des boutons en mode gaucher (reversePanels),
  // pour rester cohérent avec l'inversion des volets latéraux : ce qui reste
  // sur la même ligne, seule sa position gauche/droite change.
  List<Widget> _reorder(List<Widget> children) =>
      reversePanels ? children.reversed.toList() : children;

  @override
  Widget build(BuildContext context) {
    final double totalHeight = 80.0 + (expandProgress * 80.0);

    final List<Widget> meshButtons = [
      // Boutons spécifiques au mode MESH (sans icônes)
      _RoundButton(
        onPressed: onResegmentMesh,
        child: const Text('RECALCULER',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.greenAccent,
                fontSize: 8,
                fontWeight: FontWeight.bold)),
      ),
      _RoundButton(
        onPressed: onCreateTrace,
        child: const Text('CRÉER TRACE',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.greenAccent,
                fontSize: 8,
                fontWeight: FontWeight.bold)),
      ),
      _RoundButton(
        onPressed: onClearSelection,
        child:
            const Icon(Icons.layers_clear, color: Colors.redAccent, size: 20),
      ),
      _RoundButton(
          onPressed: onZoomOut,
          child: const Icon(Icons.remove, color: Colors.white70)),
      _RoundButton(
          onPressed: onZoomIn,
          child: const Icon(Icons.add, color: Colors.white70)),
    ];

    final List<Widget> gpxButtons = [
      // Boutons par défaut (mode GPX)
      _RoundButton(
        onPressed: onToggleRotation,
        child: Transform.rotate(
          angle: ((heading ?? 0) * (pi / 180) * -1),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 3, height: 12, color: Colors.red),
                  Container(width: 3, height: 12, color: Colors.white),
                ],
              ),
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black,
                ),
              ),
            ],
          ),
        ),
      ),
      _RoundButton(
          onPressed: onRecenter,
          child: const Icon(Icons.my_location, color: Colors.white70)),
      _RoundButton(
        onPressed: onToggleLocation,
        child: Text('GPS',
            style: TextStyle(
                color: locationActive ? Colors.blue : Colors.redAccent,
                fontWeight: FontWeight.bold,
                fontSize: 12)),
      ),
      _RoundButton(
          onPressed: onCycleMap,
          child: const Text('MAP',
              style: TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                  fontSize: 10))),
      _RoundButton(
          onPressed: onZoomOut,
          child: const Icon(Icons.remove, color: Colors.white70)),
      _RoundButton(
          onPressed: onZoomIn,
          child: const Icon(Icons.add, color: Colors.white70)),
    ];

    final List<Widget> meshExpandedButtons = [
      _RoundButton(
          onPressed: onRecenter,
          child: const Icon(Icons.my_location, color: Colors.white70)),
      _RoundButton(
          onPressed: onCycleMap,
          child: const Text('MAP',
              style: TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                  fontSize: 10))),
      _RoundButton(
          onPressed: onDeleteSelected,
          child: const Icon(Icons.delete_outline, color: Colors.redAccent)),
      _RoundButton(
        onPressed: onToggleWaypoints,
        onLongPress: onLongPressWaypoints,
        child: _WaypointToggleIcon(
            active: showAllWaypoints, showEverything: showEveryWaypoint),
      ),
    ];

    final List<Widget> gpxExpandedButtons = [
      _RoundButton(
        onPressed: onToggleWaypoints,
        onLongPress: onLongPressWaypoints,
        child: _WaypointToggleIcon(
            active: showAllWaypoints, showEverything: showEveryWaypoint),
      ),
      _RoundButton(
        onPressed: onToggleGpx,
        child: Text('GPX',
            style: TextStyle(
                color: showAllGpx ? Colors.greenAccent : Colors.white38,
                fontWeight: FontWeight.bold,
                fontSize: 12)),
      ),
      _RoundButton(
        onPressed: onToggleRecording,
        child: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: Colors.red,
            shape: isRecording ? BoxShape.rectangle : BoxShape.circle,
          ),
        ),
      ),
      _RoundButton(
        onPressed: onToggleCompass,
        child: const Icon(Icons.explore, color: Colors.white38),
      ),
    ];

    return Container(
      height: totalHeight,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: opacity),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 80,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                if (measurementMode == MeasurementMode.none)
                  ..._reorder(displayMode == DisplayMode.mesh
                      ? meshButtons
                      : gpxButtons)
                else ...[
                  IconButton(
                    onPressed: onCancelMeasure,
                    icon: const Icon(Icons.close, color: Colors.redAccent),
                  ),
                  const Spacer(),
                  _MeasurementInfo(
                    mode: measurementMode,
                    p1: measurePoint1,
                    p2: measurePoint2,
                    currentPos: currentPosition,
                    mapCenter: camera.center,
                  ),
                  const Spacer(),
                  if (measurementMode == MeasurementMode.betweenPoints &&
                      measurePoint1 == null)
                    ElevatedButton.icon(
                      onPressed: onValidatePoint,
                      icon: const Icon(Icons.check),
                      label: const Text('VALIDER PT 1'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green),
                    ),
                  if (measurementMode == MeasurementMode.betweenPoints &&
                      measurePoint1 != null)
                    const SizedBox(
                        width: 48), // Pour équilibrer le bouton Close
                ],
              ],
            ),
          ),
          if (expandProgress > 0)
            Opacity(
              opacity: expandProgress,
              child: SizedBox(
                height: 80 * expandProgress,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: _reorder(displayMode == DisplayMode.mesh
                      ? meshExpandedButtons
                      : gpxExpandedButtons),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MeasurementLayer extends StatelessWidget {
  final MeasurementMode mode;
  final ({double lat, double lon})? p1;
  final ({double lat, double lon})? p2;
  final geo.Position? currentPos;
  final LatLng mapCenter;

  const _MeasurementLayer(
      {required this.mode,
      this.p1,
      this.p2,
      this.currentPos,
      required this.mapCenter});

  @override
  Widget build(BuildContext context) {
    LatLng start = const LatLng(0, 0);
    if (mode == MeasurementMode.fromGps && currentPos != null) {
      start = LatLng(currentPos!.latitude, currentPos!.longitude);
    } else if (p1 != null) {
      start = LatLng(p1!.lat, p1!.lon);
    } else {
      return const SizedBox.shrink();
    }

    final end = (mode == MeasurementMode.betweenPoints && p2 != null)
        ? LatLng(p2!.lat, p2!.lon)
        : mapCenter;

    return PolylineLayer(
      polylines: [
        Polyline(
          points: [start, end],
          color: Colors.orangeAccent,
          strokeWidth: 2,
          pattern: StrokePattern.dashed(segments: const [10, 5]),
        ),
      ],
    );
  }
}

class _ActiveTracesLayer extends StatelessWidget {
  const _ActiveTracesLayer({
    required this.viewModel,
    required this.isarService,
    required this.strokeWidth,
  });

  final MapViewModel viewModel;
  final IsarService isarService;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Trace>>(
      valueListenable: viewModel.activeTraces,
      builder: (context, traces, _) {
        return ValueListenableBuilder<List<Segment>>(
          valueListenable: viewModel.segments,
          builder: (context, segments, _) {
            final List<Polyline> polylines = [];

            for (final trace in traces) {
              final List<LatLng> points = [];
              for (final entry in trace.segments) {
                final segment = segments
                    .firstWhereOrNull((s) => s.localUuid == entry.segmentUuid);
                if (segment != null) {
                  final segmentPoints = entry.traveledForward
                      ? segment.points
                      : segment.points.reversed;
                  points.addAll(segmentPoints
                      .map((p) => LatLng(p.latitude, p.longitude)));
                }
              }
              if (points.isNotEmpty) {
                polylines.add(Polyline(
                  points: points,
                  color: trace.colorHex != null
                      ? Color(trace.colorHex!)
                      : Colors.red,
                  strokeWidth: strokeWidth,
                ));
              }
            }

            return PolylineLayer(polylines: polylines);
          },
        );
      },
    );
  }
}

class _MeshLayer extends StatelessWidget {
  const _MeshLayer({
    required this.viewModel,
    required this.selectedUuidsNotifier,
  });

  final MapViewModel viewModel;
  final ValueNotifier<Set<String>> selectedUuidsNotifier;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Segment>>(
      valueListenable: viewModel.segments,
      builder: (context, segments, _) {
        return ValueListenableBuilder<Set<String>>(
          valueListenable: selectedUuidsNotifier,
          builder: (context, selectedUuids, ___) {
            return PolylineLayer(
              polylines: [
                for (final segment in segments)
                  Polyline(
                    points: [
                      for (final p in segment.points)
                        LatLng(p.latitude, p.longitude),
                    ],
                    color: selectedUuids.contains(segment.localUuid)
                        ? Colors.greenAccent
                        : Colors.blue,
                    strokeWidth:
                        selectedUuids.contains(segment.localUuid) ? 5.0 : 2.5,
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _WaypointsLayer extends StatelessWidget {
  const _WaypointsLayer({
    required this.viewModel,
    required this.settings,
    required this.isarService,
    required this.recordingService,
  });

  final MapViewModel viewModel;
  final SettingsService settings;
  final IsarService isarService;
  final RecordingService recordingService;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<wp_model.Waypoint>>(
      valueListenable: viewModel.waypoints,
      builder: (context, waypoints, _) {
        return MarkerLayer(
          markers: [
            for (final wp in waypoints)
              Marker(
                point: LatLng(wp.latitude, wp.longitude),
                width: settings.waypointIconSize,
                height: settings.waypointIconSize,
                child: GestureDetector(
                  onTap: () {
                    settings.dismissLocateWaypointBackButton();
                    if (settings.waypointSelectionMode) {
                      settings.setNavigationWaypoint(wp.localUuid);
                      recordingService.setDestination(wp.localUuid);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Destination : ${wp.name}')),
                      );
                    } else {
                      showDialog(
                        context: context,
                        barrierColor: Colors.black.withValues(alpha: 0.7),
                        builder: (context) => WaypointEditScreen(
                          waypoint: wp,
                          isarService: isarService,
                        ),
                      ).then((_) => viewModel.refreshNow());
                    }
                  },
                  child: Icon(
                    _iconFor(wp, settings),
                    color: Color(wp.colorHex ?? Colors.green.toARGB32()),
                    size: settings.waypointIconSize,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Filtre de rendu (pas de deuxième couche, pas de champ dupliqué sur
  /// Waypoint) : un waypoint sans catégorie chargée, ou le réglage
  /// désactivé, retombe sur le repère générique.
  IconData _iconFor(wp_model.Waypoint wp, SettingsService settings) {
    if (!settings.useWaypointCategoryIcons) return Icons.location_on;
    final iconName = wp.category.value?.iconName;
    return iconName != null ? iconForWaypointCategory(iconName) : Icons.location_on;
  }
}

class _OsmPoisLayer extends StatelessWidget {
  const _OsmPoisLayer({
    required this.viewModel,
    required this.isarService,
    required this.settings,
  });

  final MapViewModel viewModel;
  final IsarService isarService;
  final SettingsService settings;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<dynamic>>(
      valueListenable: viewModel.osmPois,
      builder: (context, dynamicPois, _) {
        final pois = dynamicPois.cast<OsmPoi>();
        return MarkerLayer(
          markers: [
            for (final poi in pois)
              Marker(
                point: poi.location,
                width: 24,
                height: 24,
                child: GestureDetector(
                  onTap: () {
                    settings.dismissLocateWaypointBackButton();
                    showDialog(
                      context: context,
                      barrierColor: Colors.black.withValues(alpha: 0.7),
                      builder: (context) => OsmPoiDetailSheet(
                        poi: poi,
                        isarService: isarService,
                      ),
                    ).then((_) => viewModel.refreshNow());
                  },
                  child: Container(
                    decoration: const BoxDecoration(
                        shape: BoxShape.circle, color: Colors.white),
                    child: Icon(_categoryFor(poi.categoryId)?.icon ?? Icons.place,
                        color: _categoryFor(poi.categoryId)?.color ?? Colors.blueAccent, size: 16),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  OsmPoiCategoryDef? _categoryFor(String categoryId) =>
      kOsmPoiCategories.firstWhereOrNull((c) => c.id == categoryId);
}

class _MapScaleWidget extends StatelessWidget {
  const _MapScaleWidget({
    required this.camera,
    required this.color,
    required this.unitSystem,
  });

  final MapCamera camera;
  final Color color;
  final UnitSystem unitSystem;

  @override
  Widget build(BuildContext context) {
    final center = camera.center;
    final zoom = camera.zoom;
    final metersPerPixel =
        156543.03392 * cos(center.latitude * pi / 180) / pow(2, zoom);
    double targetMeters = 100 * metersPerPixel;

    double scaleMeters;
    if (targetMeters < 10) {
      scaleMeters = 10;
    } else if (targetMeters < 50) {
      scaleMeters = 50;
    } else if (targetMeters < 100) {
      scaleMeters = 100;
    } else if (targetMeters < 250) {
      scaleMeters = 250;
    } else if (targetMeters < 500) {
      scaleMeters = 500;
    } else if (targetMeters < 1000) {
      scaleMeters = 1000;
    } else if (targetMeters < 2000) {
      scaleMeters = 2000;
    } else if (targetMeters < 5000) {
      scaleMeters = 5000;
    } else if (targetMeters < 10000) {
      scaleMeters = 10000;
    } else {
      scaleMeters = 20000;
    }

    final widthPx = scaleMeters / metersPerPixel;
    String label = unitSystem == UnitSystem.metric
        ? (scaleMeters >= 1000
            ? "${(scaleMeters / 1000).round()} km"
            : "${scaleMeters.round()} m")
        : (scaleMeters * 3.28084 >= 5280
            ? "${(scaleMeters * 3.28084 / 5280).round()} mi"
            : "${(scaleMeters * 3.28084).round()} ft");

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(label,
            style: TextStyle(
                color: color, fontSize: 10, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Container(
          width: widthPx,
          height: 4,
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: color, width: 2),
              right: BorderSide(color: color, width: 2),
              bottom: BorderSide(color: color, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}

class _LocationMarkerLayer extends StatelessWidget {
  final RecordingService recordingService;
  final double? heading;
  const _LocationMarkerLayer({required this.recordingService, this.heading});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<geo.Position?>(
      valueListenable: recordingService.currentPosition,
      builder: (context, pos, _) {
        if (pos == null) return const SizedBox.shrink();
        final latLng = LatLng(pos.latitude, pos.longitude);
        return MarkerLayer(
          markers: [
            Marker(
              point: latLng,
              width: 60,
              height: 60,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Halo pulsant simplifié
                  _PulsingHalo(),
                  if (heading != null)
                    Transform.rotate(
                      angle: (heading! * (pi / 180)),
                      child: const Icon(Icons.navigation,
                          color: Colors.blue, size: 30),
                    )
                  else
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.red,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withValues(alpha: 0.4),
                              blurRadius: 6,
                              spreadRadius: 2)
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PulsingHalo extends StatefulWidget {
  @override
  State<_PulsingHalo> createState() => _PulsingHaloState();
}

class _PulsingHaloState extends State<_PulsingHalo>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Container(
          width: 20 + (40 * _controller.value),
          height: 20 + (40 * _controller.value),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.blue.withValues(alpha: 0.3 * (1 - _controller.value)),
          ),
        );
      },
    );
  }
}

class _LiveTrackLayer extends StatelessWidget {
  final RecordingService recordingService;
  final double strokeWidth;
  const _LiveTrackLayer({
    required this.recordingService,
    required this.strokeWidth,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<PointGPS>>(
      valueListenable: recordingService.livePoints,
      builder: (context, points, _) {
        if (points.length < 2) return const SizedBox.shrink();

        final latLngs =
            points.map((p) => LatLng(p.latitude, p.longitude)).toList();

        return PolylineLayer(
          polylines: [
            Polyline(
              points: latLngs,
              color: Colors.redAccent.withValues(alpha: 0.8),
              strokeWidth: strokeWidth,
            ),
          ],
        );
      },
    );
  }
}

class _PoisLayer extends StatelessWidget {
  const _PoisLayer({required this.viewModel});
  final MapViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<PointOfInterest>>(
      valueListenable: viewModel.pois,
      builder: (context, pois, _) {
        return MarkerLayer(
          markers: [
            for (final poi in pois)
              Marker(
                point: LatLng(poi.latitude, poi.longitude),
                width: 30,
                height: 30,
                child: Icon(
                  MapStyle.poiIcon(poi.type),
                  color: MapStyle.poiColor(poi.type),
                  size: 20,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _PlanningLayer extends StatelessWidget {
  const _PlanningLayer({required this.controller});
  final PlanningController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final pts = controller.points.value;
        if (pts.isEmpty) return const SizedBox.shrink();

        return Stack(
          children: [
            PolylineLayer(
              polylines: [
                Polyline(
                  points: pts.map((p) => LatLng(p.lat, p.lon)).toList(),
                  color: Colors.orangeAccent,
                  strokeWidth: 5,
                ),
              ],
            ),
            MarkerLayer(
              markers: [
                for (var i = 0; i < pts.length; i++)
                  Marker(
                    point: LatLng(pts[i].lat, pts[i].lon),
                    width: 12,
                    height: 12,
                    child: Container(
                      decoration: BoxDecoration(
                        color: i == 0
                            ? Colors.green
                            : (i == pts.length - 1 ? Colors.red : Colors.white),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.black, width: 1),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _PlanningControls extends StatelessWidget {
  const _PlanningControls({
    required this.controller,
    required this.active,
    required this.busy,
    required this.onToggleActive,
    required this.onFinalize,
  });

  final PlanningController controller;
  final bool active;
  final bool busy;
  final VoidCallback onToggleActive;
  final VoidCallback onFinalize;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (active) ...[
          FloatingActionButton.small(
            onPressed: () => controller.undo(),
            backgroundColor: Colors.white,
            child: const Icon(Icons.undo, color: Colors.black),
          ),
          const SizedBox(width: 12),
          FloatingActionButton.extended(
            onPressed: busy ? null : onFinalize,
            backgroundColor: Colors.greenAccent,
            label: busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('ENREGISTRER',
                    style: TextStyle(
                        color: Colors.black, fontWeight: FontWeight.bold)),
            icon: const Icon(Icons.check, color: Colors.black),
          ),
          const SizedBox(width: 12),
          FloatingActionButton.small(
            onPressed: onToggleActive,
            backgroundColor: Colors.redAccent,
            child: const Icon(Icons.close, color: Colors.white),
          ),
        ] else
          FloatingActionButton.extended(
            onPressed: onToggleActive,
            backgroundColor: Colors.orangeAccent,
            label: const Text('PLANIFIER',
                style: TextStyle(
                    color: Colors.black, fontWeight: FontWeight.bold)),
            icon: const Icon(Icons.edit_road, color: Colors.black),
          ),
      ],
    );
  }
}

class _MeasurementInfo extends StatelessWidget {
  final MeasurementMode mode;
  final ({double lat, double lon})? p1;
  final ({double lat, double lon})? p2;
  final geo.Position? currentPos;
  final LatLng mapCenter;

  const _MeasurementInfo({
    required this.mode,
    this.p1,
    this.p2,
    this.currentPos,
    required this.mapCenter,
  });

  @override
  Widget build(BuildContext context) {
    LatLng start = const LatLng(0, 0);
    if (mode == MeasurementMode.fromGps && currentPos != null) {
      start = LatLng(currentPos!.latitude, currentPos!.longitude);
    } else if (p1 != null) {
      start = LatLng(p1!.lat, p1!.lon);
    } else {
      return const Text('Positionnez la croix',
          style: TextStyle(color: Colors.white38, fontSize: 12));
    }

    final end = (mode == MeasurementMode.betweenPoints && p2 != null)
        ? LatLng(p2!.lat, p2!.lon)
        : mapCenter;

    final dist = geo.Geolocator.distanceBetween(
        start.latitude, start.longitude, end.latitude, end.longitude);
    final azimut = GeoUtils.bearingDegrees(
        start.latitude, start.longitude, end.latitude, end.longitude);

    final distStr = dist >= 1000
        ? '${(dist / 1000).toStringAsFixed(2)} km'
        : '${dist.round()} m';

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          distStr,
          style: const TextStyle(
              color: Colors.orangeAccent,
              fontWeight: FontWeight.bold,
              fontSize: 16),
        ),
        Text(
          'Azimut : ${azimut.toStringAsFixed(1)}°',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  final Widget child;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  const _RoundButton({required this.child, required this.onPressed, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      onLongPress: onLongPress,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.1),
          border: Border.all(color: Colors.white10),
        ),
        child: Center(child: child),
      ),
    );
  }
}

/// Icône du bouton d'affichage des waypoints : distingue visuellement les
/// trois modes (masqué / affiché selon le contexte / intégralité via appui
/// long) -- voir "Affichage des waypoints" dans l'écran d'Aide. En mode
/// "intégralité", un liseret vert extérieur encercle le pictogramme.
class _WaypointToggleIcon extends StatelessWidget {
  final bool active;
  final bool showEverything;
  const _WaypointToggleIcon({required this.active, required this.showEverything});

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      Icons.location_on,
      color: (active || showEverything) ? Colors.greenAccent : Colors.white38,
      size: showEverything ? 20 : 24,
    );
    if (!showEverything) return icon;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        border: Border.fromBorderSide(BorderSide(color: Colors.greenAccent, width: 2)),
      ),
      child: icon,
    );
  }
}

/// Bandeau simplifié affiché quand l'utilisateur choisit le point fixe
/// d'ouverture de la carte depuis les paramètres d'affichage (croix rouge
/// centrale + annuler/valider, même principe que _MapCreationMenu).
class _StartupCenterPickerMenu extends StatelessWidget {
  final SettingsService settings;
  final LatLng center;
  final double zoom;
  const _StartupCenterPickerMenu({
    required this.settings,
    required this.center,
    required this.zoom,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        children: [
          TextButton(
            onPressed: () => settings.cancelPickStartupCenter(),
            child:
                const Text('ANNULER', style: TextStyle(color: Colors.white38)),
          ),
          const Spacer(),
          const Text('Positionnez la croix sur le point d\'ouverture',
              style: TextStyle(color: Colors.white70, fontSize: 12)),
          const Spacer(),
          ElevatedButton(
            onPressed: () => settings.validateStartupCenter(
                center.latitude, center.longitude, zoom),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.greenAccent),
            child:
                const Text('VALIDER', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }
}

class _MapCreationMenu extends StatelessWidget {
  final SettingsService settings;
  final LatLng center;
  const _MapCreationMenu({required this.settings, required this.center});

  @override
  Widget build(BuildContext context) {
    final step = settings.mapCreationStep;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (step == MapCreationStep.selectOrigin)
            const Text('Positionnez la croix sur le point de départ',
                style: TextStyle(color: Colors.white70)),
          if (step == MapCreationStep.stretchArea)
            const Text('Éloignez-vous pour définir la zone',
                style: TextStyle(color: Colors.white70)),
          if (step == MapCreationStep.adjustArea) ...[
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                "Ajustez la carte à l'aide du zoom et des flèches",
                style: TextStyle(color: Colors.white, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
            _ZoomRangeSelector(settings: settings),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              TextButton(
                onPressed: () => settings.cancelMapCreation(),
                child: const Text('ANNULER',
                    style: TextStyle(color: Colors.white38)),
              ),
              const Spacer(),
              if (step == MapCreationStep.selectOrigin)
                ElevatedButton(
                  onPressed: () => settings.validateOrigin(
                      center.latitude, center.longitude),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.greenAccent),
                  child: const Text('VALIDER ORIGINE',
                      style: TextStyle(color: Colors.black)),
                ),
              if (step == MapCreationStep.stretchArea)
                ElevatedButton(
                  onPressed: () =>
                      settings.validateArea(center.latitude, center.longitude),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.greenAccent),
                  child: const Text('VALIDER ZONE',
                      style: TextStyle(color: Colors.black)),
                ),
              if (step == MapCreationStep.adjustArea)
                ElevatedButton(
                  onPressed: () => _showSaveDialog(context, settings),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.greenAccent),
                  child: const Text('ENREGISTRER',
                      style: TextStyle(color: Colors.black)),
                ),
            ],
          ),
          if (step == MapCreationStep.adjustArea)
            _AdjustmentArrows(onAdjust: settings.adjustArea),
        ],
      ),
    );
  }

  void _showSaveDialog(BuildContext context, SettingsService settings) {
    final nameController = TextEditingController();
    final descController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Enregistrer la carte',
            style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                    labelText: 'Nom',
                    labelStyle: TextStyle(color: Colors.white70))),
            TextField(
                controller: descController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                    labelText: 'Description',
                    labelStyle: TextStyle(color: Colors.white70))),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('ANNULER')),
          TextButton(
            onPressed: () async {
              if (nameController.text.isEmpty) return;
              final isar = context.read<IsarService>();
              final messenger = ScaffoldMessenger.of(context);

              // Le fond de carte actuellement affiché est celui téléchargé :
              // c'est ce que l'utilisateur vient de voir/ajuster à l'écran.
              final favIds = settings.favoriteMapIds;
              final sourceId = favIds.isNotEmpty
                  ? favIds[settings.currentMapIndex % favIds.length]
                  : 'osm_standard';
              final source = availableSources.firstWhere(
                  (s) => s.id == sourceId,
                  orElse: () => availableSources.first);

              final map = OfflineMap()
                ..localUuid = const Uuid().v4()
                ..name = nameController.text
                ..description = descController.text
                ..minLat = min(settings.mapOrigin!.lat, settings.mapTarget!.lat)
                ..maxLat = max(settings.mapOrigin!.lat, settings.mapTarget!.lat)
                ..minLon = min(settings.mapOrigin!.lon, settings.mapTarget!.lon)
                ..maxLon = max(settings.mapOrigin!.lon, settings.mapTarget!.lon)
                ..minZoom = settings.minZoomDownload
                ..maxZoom = settings.maxZoomDownload
                ..sourceId = source.id
                ..urlTemplate = source.url
                ..isDownloading = true
                ..downloadProgress = 0.0;

              await isar.saveOfflineMap(map);
              settings.cancelMapCreation();
              if (context.mounted) Navigator.pop(context);

              messenger.showSnackBar(
                const SnackBar(
                  content: Text('Téléchargement de la carte démarré',
                      textAlign: TextAlign.center),
                  duration: Duration(seconds: 2),
                  behavior: SnackBarBehavior.floating,
                  margin: EdgeInsets.symmetric(horizontal: 100, vertical: 200),
                ),
              );

              unawaited(
                OfflineMapDownloadService(isarService: isar)
                    .download(map, headers: const {'User-Agent': 'Meshiker/1.0'})
                    .then((_) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                          map.isError
                              ? 'Échec du téléchargement de "${map.name}"'
                              : 'Le téléchargement de "${map.name}" est terminé',
                          textAlign: TextAlign.center),
                      duration: const Duration(seconds: 2),
                      behavior: SnackBarBehavior.floating,
                      margin: const EdgeInsets.symmetric(
                          horizontal: 50, vertical: 200),
                    ),
                  );
                }),
              );
            },
            child: const Text('VALIDER',
                style: TextStyle(color: Colors.greenAccent)),
          ),
        ],
      ),
    );
  }
}

class _AdjustmentArrows extends StatelessWidget {
  final Function(double, double, {bool fromOrigin}) onAdjust;
  const _AdjustmentArrows({required this.onAdjust});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ArrowBtn(
                  icon: Icons.arrow_upward, onTap: () => onAdjust(0.001, 0)),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ArrowBtn(
                  icon: Icons.arrow_back, onTap: () => onAdjust(0, -0.001)),
              const SizedBox(width: 40),
              _ArrowBtn(
                  icon: Icons.arrow_forward, onTap: () => onAdjust(0, 0.001)),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ArrowBtn(
                  icon: Icons.arrow_downward, onTap: () => onAdjust(-0.001, 0)),
            ],
          ),
        ],
      ),
    );
  }
}

class _ArrowBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _ArrowBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, color: Colors.greenAccent),
      padding: EdgeInsets.zero,
    );
  }
}

class _MapCreationOverlay extends StatelessWidget {
  final MapCreationStep step;
  final ({double lat, double lon})? origin;
  final ({double lat, double lon})? target;
  final MapCamera camera;
  final Function(double, double, {bool fromOrigin}) onAdjust;

  const _MapCreationOverlay({
    required this.step,
    this.origin,
    this.target,
    required this.camera,
    required this.onAdjust,
  });

  @override
  Widget build(BuildContext context) {
    if (origin == null) return const SizedBox.shrink();

    final p1 = camera.latLngToScreenPoint(LatLng(origin!.lat, origin!.lon));
    final p2 = target != null
        ? camera.latLngToScreenPoint(LatLng(target!.lat, target!.lon))
        : camera.latLngToScreenPoint(camera.center);

    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _CreationPainter(
            p1: Offset(p1.x.toDouble(), p1.y.toDouble()),
            p2: Offset(p2.x.toDouble(), p2.y.toDouble())),
      ),
    );
  }
}

class _CreationPainter extends CustomPainter {
  final Offset p1;
  final Offset p2;
  _CreationPainter({required this.p1, required this.p2});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromPoints(p1, p2);

    canvas.drawRect(
        rect,
        Paint()
          ..color = Colors.greenAccent.withValues(alpha: 0.3)
          ..style = PaintingStyle.fill);

    canvas.drawRect(
        rect,
        Paint()
          ..color = Colors.greenAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);

    final backgroundPath = ui.Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final holePath = ui.Path()..addRect(rect);

    canvas.drawPath(
        ui.Path.combine(ui.PathOperation.difference, backgroundPath, holePath),
        Paint()..color = Colors.black45);
  }

  @override
  bool shouldRepaint(_CreationPainter oldDelegate) =>
      p1.dx != oldDelegate.p1.dx ||
      p1.dy != oldDelegate.p1.dy ||
      p2.dx != oldDelegate.p2.dx ||
      p2.dy != oldDelegate.p2.dy;
}

class _ZoomRangeSelector extends StatelessWidget {
  final SettingsService settings;
  const _ZoomRangeSelector({required this.settings});

  @override
  Widget build(BuildContext context) {
    // Estimation simplifiée de la taille
    // Un zoom de plus = 4x plus de tuiles.
    // Base: une zone "standard" à zoom 15 fait environ 5-10 MB.
    int tileCount = 0;
    for (int z = settings.minZoomDownload; z <= settings.maxZoomDownload; z++) {
      tileCount += pow(4, (z - 10).clamp(0, 10)).toInt();
    }
    final estSizeMb = (tileCount * 0.02).toStringAsFixed(1);

    return Column(
      children: [
        Text(
            "Niveaux de zoom à télécharger (${settings.minZoomDownload} - ${settings.maxZoomDownload})",
            style: const TextStyle(color: Colors.white70, fontSize: 10)),
        const SizedBox(height: 4),
        Text(
          "Estimation : ~$estSizeMb MB",
          style: const TextStyle(
              color: Colors.greenAccent,
              fontSize: 12,
              fontWeight: FontWeight.bold),
        ),
        RangeSlider(
          values: RangeValues(settings.minZoomDownload.toDouble(),
              settings.maxZoomDownload.toDouble()),
          min: 0,
          max: 18,
          divisions: 18,
          labels: RangeLabels(settings.minZoomDownload.toString(),
              settings.maxZoomDownload.toString()),
          activeColor: Colors.greenAccent,
          onChanged: (values) {
            settings.setZoomRange(values.start.round(), values.end.round());
          },
        ),
      ],
    );
  }
}
