import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../database/isar_service.dart';
import '../../map/map_style.dart';
import '../../map/map_view_model.dart';
import '../../models/trace.dart';
import '../../utils/geo_utils.dart';
import '../../utils/settings_service.dart';

/// Illustration d'une trace GPX : petite carte statique (non-interactive)
/// cadrée sur l'étendue de la trace, avec son tracé dessiné dessus. Un
/// appui dessus déclenche "Localiser sur la carte" (cf. TrackEditScreen),
/// un processus volontairement distinct de "Naviguer" -- voir
/// SettingsService.startLocateTrace.
class TraceMapPreview extends StatefulWidget {
  final Trace trace;

  const TraceMapPreview({super.key, required this.trace});

  @override
  State<TraceMapPreview> createState() => _TraceMapPreviewState();
}

class _TraceMapPreviewState extends State<TraceMapPreview> {
  late final Future<List<({double lat, double lon})>> _polylineFuture;

  @override
  void initState() {
    super.initState();
    _polylineFuture = context.read<IsarService>().getTracePolyline(widget.trace);
  }

  Future<void> _locateOnMap(
    BuildContext context,
    ({double minLat, double maxLat, double minLon, double maxLon}) bbox,
  ) async {
    final settings = context.read<SettingsService>();
    await settings.startLocateTrace(widget.trace.localUuid, widget.trace.name);
    if (!context.mounted) return;
    context.read<MapViewModel>().centerBoundsRequest.value = bbox;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 180,
        width: double.infinity,
        child: FutureBuilder<List<({double lat, double lon})>>(
          future: _polylineFuture,
          builder: (context, snapshot) {
            final points = snapshot.data;
            final bbox = points == null ? null : GeoUtils.boundingBox(points);

            if (bbox == null) {
              return Container(
                color: Colors.white.withValues(alpha: 0.05),
                alignment: Alignment.center,
                child: Text(
                  snapshot.connectionState == ConnectionState.waiting
                      ? 'Chargement de l\'aperçu...'
                      : 'Aperçu indisponible',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              );
            }

            final source = MapStyle.resolveTileSource(settings);
            final latLngPoints =
                points!.map((p) => LatLng(p.lat, p.lon)).toList();

            return GestureDetector(
              onTap: () => _locateOnMap(context, bbox),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FlutterMap(
                    options: MapOptions(
                      initialCameraFit: CameraFit.bounds(
                        bounds: LatLngBounds(
                          LatLng(bbox.minLat, bbox.minLon),
                          LatLng(bbox.maxLat, bbox.maxLon),
                        ),
                        padding: const EdgeInsets.all(24),
                      ),
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.none,
                      ),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: source.url,
                        subdomains: const ['a', 'b', 'c'],
                        userAgentPackageName: 'com.example.meshiker',
                      ),
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: latLngPoints,
                            color: widget.trace.colorHex != null
                                ? Color(widget.trace.colorHex!)
                                : Colors.greenAccent,
                            strokeWidth: 4,
                          ),
                        ],
                      ),
                    ],
                  ),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: Colors.black54,
                      child: const Icon(Icons.zoom_in, color: Colors.white, size: 18),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
