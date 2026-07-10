import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;
import '../ui/settings/maps_settings_screen.dart';
import '../ui/waypoints/waypoint_edit_screen.dart';
import '../models/waypoint.dart' as wp_model;

import '../database/isar_service.dart';
import '../models/point_of_interest.dart';
import '../models/segment.dart';
import '../search/local_search_engine.dart';
import '../utils/settings_service.dart';
import 'package:uuid/uuid.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:uuid/uuid.dart';
import '../utils/overpass_service.dart';
import '../utils/geo_utils.dart';
import '../recording/recording_service.dart';
import 'map_style.dart';
import 'map_view_model.dart';
import 'planning_controller.dart';
import 'vector_tile_source.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    required this.viewModel,
    required this.vectorTileSource,
    required this.isarService,
    required this.searchEngine,
    required this.ownerUuid,
    required this.settingsService,
    required this.recordingService,
    this.planningController,
    this.onPlanFinalized,
    this.initialCenter = const LatLng(45.8326, 6.8652),
    this.initialZoom = 13,
  });

  final MapViewModel viewModel;
  final VectorTileSource vectorTileSource;
  final IsarService isarService;
  final LocalSearchEngine searchEngine;
  final SettingsService settingsService;
  final RecordingService recordingService;
  final String ownerUuid;
  final PlanningController? planningController;
  final VoidCallback? onPlanFinalized;
  final LatLng initialCenter;
  final double initialZoom;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  final ValueNotifier<SegmentColorMode> _colorMode =
      ValueNotifier(SegmentColorMode.difficulty);
  
  bool _planningActive = false;
  bool _isFinalizing = false;
  bool _dynamicRotation = false;
  bool _locationActive = true;
  bool _isMapReady = false;
  MapCamera? _latestCamera;
  
  StreamSubscription? _compassSubscription;
  double? _currentHeading;

  @override
  void initState() {
    super.initState();
    _initCompass();
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
    _colorMode.dispose();
    _compassSubscription?.cancel();
    super.dispose();
  }

  void _reloadViewportData(MapCamera camera) {
    final bounds = camera.visibleBounds;
    widget.viewModel.onViewportChanged(
      minLat: bounds.south,
      maxLat: bounds.north,
      minLon: bounds.west,
      maxLon: bounds.east,
    );
  }

  void _onPositionChanged(MapCamera camera, bool hasGesture) {
    setState(() => _latestCamera = camera);
    _reloadViewportData(camera);
    widget.planningController
        ?.updateCandidateSegments(widget.viewModel.segments.value);
  }

  void _onTap(TapPosition tapPosition, LatLng point) {
    if (!_planningActive) return;
    widget.planningController?.addTapPoint(point.latitude, point.longitude);
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

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.settingsService,
      builder: (context, _) {
        return Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: widget.initialCenter,
                initialZoom: widget.initialZoom,
                onTap: _onTap,
                onLongPress: (tapPosition, point) {
                  showDialog(
                    context: context,
                    barrierColor: Colors.black.withOpacity(0.7),
                    builder: (context) => WaypointEditScreen(
                      latitude: point.latitude,
                      longitude: point.longitude,
                      isarService: widget.isarService,
                    ),
                  );
                },
                onPositionChanged: _onPositionChanged,
                onMapReady: () {
                  setState(() {
                    _isMapReady = true;
                    _latestCamera = _mapController.camera;
                  });
                  _reloadViewportData(_mapController.camera);
                },
              ),
              children: [
                // FOND DE CARTE : Vectoriel (hors-ligne) ou Sélections (en-ligne)
                if (widget.vectorTileSource.theme != null)
                  VectorTileLayer(
                    theme: widget.vectorTileSource.theme!,
                    tileProviders: widget.vectorTileSource.tileProviders,
                  )
                else
                  _buildDynamicTileLayer(),

                _SegmentsLayer(viewModel: widget.viewModel, colorMode: _colorMode),
                _PoisLayer(viewModel: widget.viewModel),
                if (widget.settingsService.showAllWaypoints)
                  _WaypointsLayer(
                    viewModel: widget.viewModel, 
                    settings: widget.settingsService,
                    isarService: widget.isarService,
                  ),
                _OsmPoisLayer(
                  viewModel: widget.viewModel,
                  isarService: widget.isarService,
                ),
                if (widget.planningController != null)
                  _PlanningLayer(controller: widget.planningController!),
                const RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution("Contributeurs de la toile d'araignee"),
                  ],
                ),
              ],
            ),
            
            // BANDEAU DE CONTRÔLE BAS
            if (_isMapReady && _latestCamera != null)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _BottomControlBar(
                  opacity: widget.settingsService.barOpacity,
                  heading: _currentHeading,
                  dynamicRotation: _dynamicRotation,
                  locationActive: _locationActive,
                  showScale: widget.settingsService.showScale,
                  camera: _latestCamera!,
                  unitSystem: widget.settingsService.unitSystem,
                  measurementMode: widget.settingsService.measurementMode,
                  measurePoint1: widget.settingsService.measurePoint1,
                  measurePoint2: widget.settingsService.measurePoint2,
                  currentPosition: widget.recordingService.currentPosition.value,
                  onToggleRotation: () {
                    setState(() => _dynamicRotation = !_dynamicRotation);
                    if (!_dynamicRotation) _mapController.rotate(0);
                  },
                  onRecenter: () {
                    _mapController.move(widget.initialCenter, _mapController.camera.zoom);
                  },
                  onToggleLocation: () {
                    setState(() => _locationActive = !_locationActive);
                  },
                  onCycleMap: () {
                    widget.settingsService.cycleMap();
                  },
                  onZoomIn: () {
                    _mapController.move(_mapController.camera.center, _mapController.camera.zoom + 1);
                  },
                  onZoomOut: () {
                    _mapController.move(_mapController.camera.center, _mapController.camera.zoom - 1);
                  },
                  onValidatePoint: () {
                    final center = _mapController.camera.center;
                    if (widget.settingsService.measurePoint1 == null) {
                      widget.settingsService.setMeasurePoint1(center.latitude, center.longitude);
                    } else {
                      widget.settingsService.setMeasurePoint2(center.latitude, center.longitude);
                    }
                  },
                  onCancelMeasure: () {
                    widget.settingsService.clearMeasurement();
                  },
                ),
              ),

            // CROIX CENTRALE
            if (widget.settingsService.measurementMode != MeasurementMode.none)
              const IgnorePointer(
                child: Center(
                  child: Icon(Icons.add, color: Colors.white, size: 40),
                ),
              ),

            Positioned(top: 16, right: 16, child: _ColorModeSelector(colorMode: _colorMode)),
            if (widget.planningController != null)
              Positioned(
                bottom: 100, // Remonté pour ne pas chevaucher le bandeau
                left: 0,
                right: 0,
                child: _PlanningControls(
                  controller: widget.planningController!,
                  active: _planningActive,
                  busy: _isFinalizing,
                  onToggleActive: () => setState(() => _planningActive = !_planningActive),
                  onFinalize: _finalizePlan,
                ),
              ),
          ],
        );
      },
    );
  }
  Widget _buildDynamicTileLayer() {
    final favIds = widget.settingsService.favoriteMapIds;
    if (favIds.isEmpty) {
      return TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png');
    }
    
    final currentId = favIds[widget.settingsService.currentMapIndex];
    final source = availableSources.firstWhere((s) => s.id == currentId, orElse: () => availableSources.first);
    
    return TileLayer(
      urlTemplate: source.url,
      subdomains: const ['a', 'b', 'c'],
      userAgentPackageName: 'com.example.rando',
    );
  }
}

class _BottomControlBar extends StatelessWidget {
  final double opacity;
  final double? heading;
  final bool dynamicRotation;
  final bool locationActive;
  final bool showScale;
  final MapCamera camera;
  final UnitSystem unitSystem;
  final MeasurementMode measurementMode;
  final ({double lat, double lon})? measurePoint1;
  final ({double lat, double lon})? measurePoint2;
  final geo.Position? currentPosition;
  final VoidCallback onToggleRotation;
  final VoidCallback onRecenter;
  final VoidCallback onToggleLocation;
  final VoidCallback onCycleMap;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onValidatePoint;
  final VoidCallback onCancelMeasure;

  const _BottomControlBar({
    required this.opacity,
    required this.heading,
    required this.dynamicRotation,
    required this.locationActive,
    required this.showScale,
    required this.camera,
    required this.unitSystem,
    required this.measurementMode,
    this.measurePoint1,
    this.measurePoint2,
    this.currentPosition,
    required this.onToggleRotation,
    required this.onRecenter,
    required this.onToggleLocation,
    required this.onCycleMap,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onValidatePoint,
    required this.onCancelMeasure,
  });

  @override
  Widget build(BuildContext context) {
    final scaleColor = opacity > 0.5 ? Colors.white70 : Colors.black;

    return Container(
      height: (showScale || measurementMode != MeasurementMode.none) ? 100 : 80,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(opacity),
      ),
      child: Column(
        children: [
          // ÉCHELLE OU MESURES
          if (measurementMode != MeasurementMode.none)
            _buildMeasurementDisplay(scaleColor)
          else if (showScale)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: scaleColor.withOpacity(0.3), width: 1)),
              ),
              child: _MapScaleWidget(
                camera: camera,
                color: scaleColor,
                unitSystem: unitSystem,
              ),
            ),
          
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                if (measurementMode == MeasurementMode.none) ...[
                  // BOUSSOLE
                  _RoundButton(
                    onPressed: onToggleRotation,
                    child: Transform.rotate(
                      angle: ((heading ?? 0) * (pi / 180) * -1),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(width: 2, height: 30, color: Colors.red),
                          Positioned(top: 8, child: Container(width: 2, height: 15, color: Colors.white)),
                        ],
                      ),
                    ),
                  ),
                  
                  // RECENTRER
                  _RoundButton(
                    onPressed: onRecenter,
                    child: const Icon(Icons.my_location, color: Colors.white70),
                  ),

                  // TOGGLE GPS (SLEEP)
                  _RoundButton(
                    onPressed: onToggleLocation,
                    child: Icon(
                      locationActive ? Icons.gps_fixed : Icons.gps_off,
                      color: locationActive ? Colors.blue : Colors.redAccent,
                    ),
                  ),

                  // MAP SWITCH
                  _RoundButton(
                    onPressed: onCycleMap,
                    child: const Text('MAP', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 10)),
                  ),

                  // ZOOM -
                  _RoundButton(
                    onPressed: onZoomOut,
                    child: const Icon(Icons.remove, color: Colors.white70),
                  ),

                  // ZOOM +
                  _RoundButton(
                    onPressed: onZoomIn,
                    child: const Icon(Icons.add, color: Colors.white70),
                  ),
                ] else ...[
                  // BOUTONS DE MESURE
                  TextButton.icon(
                    onPressed: onCancelMeasure,
                    icon: const Icon(Icons.close, color: Colors.redAccent),
                    label: const Text('ANNULER', style: TextStyle(color: Colors.redAccent)),
                  ),
                  const Spacer(),
                  if (measurementMode == MeasurementMode.betweenPoints && measurePoint1 == null)
                    ElevatedButton.icon(
                      onPressed: onValidatePoint,
                      icon: const Icon(Icons.check),
                      label: const Text('VALIDER PT 1'),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMeasurementDisplay(Color color) {
    double? distMeters;
    double? bearing;

    if (measurementMode == MeasurementMode.fromGps) {
      if (currentPosition != null) {
        distMeters = geo.Geolocator.distanceBetween(
          currentPosition!.latitude, currentPosition!.longitude,
          camera.center.latitude, camera.center.longitude,
        );
        bearing = GeoUtils.bearingDegrees(
          currentPosition!.latitude, currentPosition!.longitude,
          camera.center.latitude, camera.center.longitude,
        );
      }
    } else {
      // Between points
      if (measurePoint1 != null) {
        distMeters = geo.Geolocator.distanceBetween(
          measurePoint1!.lat, measurePoint1!.lon,
          camera.center.latitude, camera.center.longitude,
        );
        bearing = GeoUtils.bearingDegrees(
          measurePoint1!.lat, measurePoint1!.lon,
          camera.center.latitude, camera.center.longitude,
        );
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: color.withOpacity(0.3), width: 1)),
      ),
      child: Center(
        child: (distMeters == null) 
          ? Text(
              measurementMode == MeasurementMode.fromGps ? 'GPS INDISPONIBLE' : 'CIBLEZ LE POINT 1', 
              style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.bold)
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.straighten, color: color, size: 20),
                const SizedBox(width: 8),
                Text(
                  _formatDistance(distMeters), 
                  style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.bold)
                ),
                const SizedBox(width: 32),
                Icon(Icons.explore, color: color, size: 20),
                const SizedBox(width: 8),
                Text(
                  '${bearing?.round()}°', 
                  style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.bold)
                ),
              ],
            ),
      ),
    );
  }

  String _formatDistance(double meters) {
    if (unitSystem == UnitSystem.metric) {
      if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(1)} km';
      return '${meters.round()} m';
    } else {
      final feet = meters * 3.28084;
      if (feet >= 5280) return '${(feet / 5280).toStringAsFixed(1)} mi';
      return '${feet.round()} ft';
    }
  }
}

class _MapScaleWidget extends StatelessWidget {
  final MapCamera camera;
  final Color color;
  final UnitSystem unitSystem;

  const _MapScaleWidget({
    required this.camera,
    required this.color,
    required this.unitSystem,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final scaleWidth = screenWidth * 0.66; // 2/3 de la largeur du bandeau

    // Résolution en mètres par pixel au centre de la carte
    // Formule : (Circunférence équateur * cos(lat)) / 2^(zoom + 8)
    final latitude = camera.center.latitude;
    final zoom = camera.zoom;
    final metersPerPixel = (40075016.686 * cos(latitude * pi / 180)) / pow(2, zoom + 8);
    
    final distanceMeters = scaleWidth * metersPerPixel;
    String distanceText;

    if (unitSystem == UnitSystem.metric) {
      if (distanceMeters >= 1000) {
        distanceText = '${(distanceMeters / 1000).toStringAsFixed(1)} km';
      } else {
        distanceText = '${distanceMeters.round()} m';
      }
    } else {
      // Système Impérial
      final distanceFeet = distanceMeters * 3.28084;
      if (distanceFeet >= 5280) {
        distanceText = '${(distanceFeet / 5280).toStringAsFixed(1)} mi';
      } else {
        distanceText = '${distanceFeet.round()} ft';
      }
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: scaleWidth,
          height: 3,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 50,
          child: Text(
            distanceText,
            style: TextStyle(
              color: color, 
              fontSize: 11, 
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  final Widget child;
  final VoidCallback onPressed;
  const _RoundButton({required this.child, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(30),
      child: Container(
        width: 45,
        height: 45,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24),
        ),
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}

/// Calque des segments, recolorie dynamiquement selon colorMode sans
/// reconstruire toute la carte (deux ValueListenableBuilder imbriques,
/// chacun ne reagissant qu'a ce qui le concerne).
class _SegmentsLayer extends StatelessWidget {
  const _SegmentsLayer({required this.viewModel, required this.colorMode});

  final MapViewModel viewModel;
  final ValueNotifier<SegmentColorMode> colorMode;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Segment>>(
      valueListenable: viewModel.segments,
      builder: (context, segments, _) {
        return ValueListenableBuilder<SegmentColorMode>(
          valueListenable: colorMode,
          builder: (context, mode, __) {
            return PolylineLayer(
              polylines: [
                for (final segment in segments)
                  Polyline(
                    points: [
                      for (final p in segment.points) LatLng(p.latitude, p.longitude),
                    ],
                    color: MapStyle.segmentColor(segment, mode),
                    strokeWidth: MapStyle.segmentWidth(segment),
                    // Le trace en tirets pour le hors-piste est une info
                    // redondante avec la couleur (voir MapStyle.isDashed) :
                    // reste lisible meme en noir & blanc ou en mode
                    // daltonien. `pattern` est apparu dans des versions
                    // recentes de flutter_map -- a verifier contre la
                    // version installee (voir README).
                    pattern: MapStyle.isDashed(segment)
                        ? StrokePattern.dashed(segments: const [8.0, 6.0])
                        : const StrokePattern.solid(),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _OsmPoisLayer extends StatelessWidget {
  const _OsmPoisLayer({required this.viewModel, required this.isarService});

  final MapViewModel viewModel;
  final IsarService isarService;

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
                  onLongPress: () {
                    final uuid = const Uuid().v4();
                    // Importer le point OSM
                    showDialog(
                      context: context,
                      barrierColor: Colors.black.withOpacity(0.7),
                      builder: (context) => WaypointEditScreen(
                        latitude: poi.location.latitude,
                        longitude: poi.location.longitude,
                        isarService: isarService,
                        waypoint: wp_model.Waypoint()
                          ..name = poi.name
                          ..description = 'Importé d\'OpenStreetMap (Type: ${poi.type})'
                          ..localUuid = uuid,
                      ),
                    );
                  },
                  child: Icon(
                    _getOsmIcon(poi.type),
                    color: Colors.blueAccent.withOpacity(0.7),
                    size: 20,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  IconData _getOsmIcon(String type) {
    if (type.contains('water')) return Icons.water_drop;
    if (type.contains('camp')) return Icons.terrain; // campsite n'existe pas en standard
    if (type.contains('hospital')) return Icons.local_hospital;
    if (type.contains('hut') || type.contains('shelter')) return Icons.home;
    if (type.contains('supermarket') || type.contains('bakery')) return Icons.shopping_basket;
    if (type.contains('fuel')) return Icons.local_gas_station;
    return Icons.info_outline;
  }
}

class _WaypointsLayer extends StatelessWidget {
  const _WaypointsLayer({required this.viewModel, required this.settings, required this.isarService});

  final MapViewModel viewModel;
  final SettingsService settings;
  final IsarService isarService;

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
                    Navigator.push(context, MaterialPageRoute(
                      builder: (_) => WaypointEditScreen(
                        waypoint: wp,
                        isarService: isarService,
                      ),
                    ));
                  },
                  child: Icon(
                    _getIcon(wp.category.value?.iconName), 
                    color: wp.colorHex != null ? Color(wp.colorHex!) : Colors.green,
                    size: settings.waypointIconSize,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  IconData _getIcon(String? iconName) {
    switch (iconName) {
      case 'water_drop': return Icons.water_drop;
      case 'home': return Icons.home;
      case 'tent': return Icons.terrain; // tent n'existe pas
      case 'terrain': return Icons.terrain;
      default: return Icons.location_on;
    }
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
                width: 36,
                height: 36,
                child: Icon(MapStyle.poiIcon(poi.type), color: MapStyle.poiColor(poi.type)),
              ),
          ],
        );
      },
    );
  }
}

/// Trace en cours de dessin en mode planification, distinct des segments
/// deja persistes (couleur dediee, tant qu'il n'a pas ete finalise).
class _PlanningLayer extends StatelessWidget {
  const _PlanningLayer({required this.controller});

  final PlanningController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<PlanPoint>>(
      valueListenable: controller.points,
      builder: (context, planPoints, _) {
        if (planPoints.length < 2) return const SizedBox.shrink();
        return PolylineLayer(
          polylines: [
            Polyline(
              points: [for (final p in planPoints) LatLng(p.lat, p.lon)],
              color: Colors.deepPurple,
              strokeWidth: 4,
            ),
          ],
        );
      },
    );
  }
}

class _ColorModeSelector extends StatelessWidget {
  const _ColorModeSelector({required this.colorMode});

  final ValueNotifier<SegmentColorMode> colorMode;

  static const _labels = {
    SegmentColorMode.difficulty: 'Difficulté',
    SegmentColorMode.elevationGrade: 'Pente',
    SegmentColorMode.recency: 'Récence',
    SegmentColorMode.reliability: 'Fiabilité',
    SegmentColorMode.mode: 'Routé / hors-piste',
  };

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SegmentColorMode>(
      valueListenable: colorMode,
      builder: (context, mode, _) {
        return Material(
          elevation: 2,
          borderRadius: BorderRadius.circular(8),
          child: PopupMenuButton<SegmentColorMode>(
            tooltip: 'Code couleur des segments',
            initialValue: mode,
            onSelected: (m) => colorMode.value = m,
            itemBuilder: (context) => [
              for (final entry in _labels.entries)
                PopupMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            child: const Padding(
              padding: EdgeInsets.all(10),
              child: Icon(Icons.palette_outlined),
            ),
          ),
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
        FloatingActionButton.extended(
          heroTag: 'planningToggle',
          onPressed: busy ? null : onToggleActive,
          icon: Icon(active ? Icons.close : Icons.edit_road),
          label: Text(active ? 'Quitter la planification' : 'Planifier un itinéraire'),
        ),
        if (active) ...[
          const SizedBox(width: 12),
          ValueListenableBuilder<bool>(
            valueListenable: controller.magnetEnabled,
            builder: (context, enabled, _) {
              return FloatingActionButton(
                heroTag: 'magnetToggle',
                onPressed: busy ? null : controller.toggleMagnet,
                backgroundColor: enabled ? Colors.blue : Colors.brown,
                tooltip: enabled ? 'Aimant activé (routé)' : 'Aimant désactivé (hors-piste)',
                child: Icon(enabled ? Icons.link : Icons.link_off),
              );
            },
          ),
          const SizedBox(width: 12),
          FloatingActionButton(
            heroTag: 'undoPlanPoint',
            onPressed: busy ? null : controller.undoLastPoint,
            tooltip: 'Annuler le dernier point',
            child: const Icon(Icons.undo),
          ),
          const SizedBox(width: 12),
          FloatingActionButton(
            heroTag: 'finalizePlan',
            onPressed: busy ? null : onFinalize,
            tooltip: 'Enregistrer cet itinéraire',
            child: busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
          ),
        ],
      ],
    );
  }
}
