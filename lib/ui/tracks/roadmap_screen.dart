import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:isar_community/isar.dart';
import '../../database/isar_service.dart';
import '../../map/map_view_model.dart';
import '../../models/trace.dart';
import '../../models/waypoint.dart';
import '../../utils/geo_utils.dart';
import '../../utils/settings_service.dart';
import '../../recording/recording_service.dart';
import '../waypoints/waypoint_edit_screen.dart';
import 'track_manager_screen.dart';

/// Affiche les waypoints de la trace GPX unique actuellement chargée dans le
/// Roadmap, dans l'ordre du parcours (pas de tri ni de recherche — cette
/// liste n'est pas un gestionnaire, c'est un carnet de route). Une ligne
/// horizontale matérialise la position de l'utilisateur et descend dans la
/// liste à mesure qu'il dépasse les waypoints.
class RoadmapScreen extends StatelessWidget {
  final bool isTransparent;
  final bool isSelectionMode;

  const RoadmapScreen({
    super.key,
    this.isTransparent = false,
    this.isSelectionMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final traceName = context.select<SettingsService, String?>((s) => s.roadmapTraceName);
    final isar = context.watch<IsarService>();
    final recording = context.watch<RecordingService>();
    final settings = context.read<SettingsService>();

    return Scaffold(
      backgroundColor: isTransparent ? Colors.transparent : Colors.black,
      appBar: AppBar(
        title: const Text('Roadmap'),
        backgroundColor: isTransparent ? Colors.transparent : Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.route_outlined),
            tooltip: 'Track Manager',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TrackManagerScreen()),
            ),
          ),
        ],
      ),
      body: traceName == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24.0),
                child: Text(
                  'Aucune trace chargée.\nOuvrez une trace depuis le Track Manager et choisissez « Naviguer ».',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white38),
                ),
              ),
            )
          : FutureBuilder<_RoadmapData?>(
              future: _loadRoadmapData(isar, traceName),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final data = snapshot.data;
                if (data == null) {
                  return const Center(
                    child: Text(
                      'Trace introuvable.',
                      style: TextStyle(color: Colors.white38),
                    ),
                  );
                }
                if (data.entries.isEmpty) {
                  return const Center(
                    child: Text(
                      'Cette trace ne contient aucun waypoint.',
                      style: TextStyle(color: Colors.white38),
                    ),
                  );
                }

                return ValueListenableBuilder<double>(
                  valueListenable: recording.trackDistanceDoneMeters,
                  builder: (context, doneDist, _) {
                    // Index du premier waypoint encore devant l'utilisateur.
                    final lineIndex = data.entries.indexWhere((e) => e.distanceAlongTrack > doneDist);
                    final insertAt = lineIndex == -1 ? data.entries.length : lineIndex;

                    return ListView.builder(
                      itemCount: data.entries.length + 1,
                      itemBuilder: (context, index) {
                        if (index == insertAt) {
                          return const _ProgressLine();
                        }
                        final entryIndex = index < insertAt ? index : index - 1;
                        final entry = data.entries[entryIndex];
                        return _RoadmapWaypointTile(
                          waypoint: entry.waypoint,
                          passed: entry.distanceAlongTrack <= doneDist,
                          distanceMeters: (entry.distanceAlongTrack - doneDist).abs(),
                          unitSystem: settings.unitSystem,
                          onTap: isSelectionMode
                              ? () {
                                  settings.setNavigationWaypoint(entry.waypoint.localUuid);
                                  recording.setDestination(entry.waypoint.localUuid);
                                  Navigator.pop(context);
                                }
                              : () {
                                  showDialog(
                                    context: context,
                                    barrierColor: Colors.black.withValues(alpha: 0.7),
                                    builder: (context) => WaypointEditScreen(
                                      waypoint: entry.waypoint,
                                      isarService: isar,
                                      locateOrigin: WaypointLocateOrigin.roadmap,
                                    ),
                                  ).then((_) {
                                    if (context.mounted) {
                                      context.read<MapViewModel>().refreshNow();
                                    }
                                  });
                                },
                        );
                      },
                    );
                  },
                );
              },
            ),
    );
  }

  Future<_RoadmapData?> _loadRoadmapData(IsarService isar, String traceName) async {
    final trace = await isar.isar.traces.filter().nameEqualTo(traceName).findFirst();
    if (trace == null) return null;

    final polyline = await isar.getTracePolyline(trace);
    final waypoints = await isar.searchWaypoints(filterGpxName: traceName);

    final entries = <_RoadmapEntry>[];
    for (final wp in waypoints) {
      await wp.category.load();
      if (polyline.isEmpty) {
        entries.add(_RoadmapEntry(wp, 0));
        continue;
      }
      final snap = GeoUtils.snapToPolyline(wp.latitude, wp.longitude, polyline, 100);
      if (snap == null) continue;
      entries.add(_RoadmapEntry(wp, GeoUtils.distanceToSnapMeters(polyline, snap)));
    }
    entries.sort((a, b) => a.distanceAlongTrack.compareTo(b.distanceAlongTrack));

    return _RoadmapData(entries);
  }
}

class _RoadmapData {
  final List<_RoadmapEntry> entries;
  _RoadmapData(this.entries);
}

class _RoadmapEntry {
  final Waypoint waypoint;
  final double distanceAlongTrack;
  _RoadmapEntry(this.waypoint, this.distanceAlongTrack);
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: Row(
        children: [
          const Icon(Icons.hiking, color: Colors.greenAccent, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Container(height: 2, color: Colors.greenAccent),
          ),
        ],
      ),
    );
  }
}

class _RoadmapWaypointTile extends StatelessWidget {
  final Waypoint waypoint;
  final bool passed;
  final double distanceMeters;
  final UnitSystem unitSystem;
  final VoidCallback? onTap;

  const _RoadmapWaypointTile({
    required this.waypoint,
    required this.passed,
    required this.distanceMeters,
    required this.unitSystem,
    required this.onTap,
  });

  String _formatDistance(double m) => unitSystem == UnitSystem.metric
      ? (m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m')
      : (m * 3.28084 >= 5280
          ? '${(m * 3.28084 / 5280).toStringAsFixed(1)} mi'
          : '${(m * 3.28084).round()} ft');

  @override
  Widget build(BuildContext context) {
    final distanceColor = passed ? Colors.white38 : Colors.greenAccent;
    return ListTile(
      enabled: onTap != null,
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: waypoint.colorHex != null ? Color(waypoint.colorHex!) : Colors.grey,
        child: const Icon(Icons.location_on, color: Colors.white, size: 20),
      ),
      title: Text(
        waypoint.name,
        style: TextStyle(color: passed ? Colors.white38 : Colors.white),
      ),
      subtitle: Text(
        waypoint.category.value?.name ?? 'Point',
        style: const TextStyle(color: Colors.white38),
      ),
      trailing: Text(
        _formatDistance(distanceMeters),
        style: TextStyle(color: distanceColor, fontWeight: FontWeight.bold, fontSize: 13),
      ),
      onTap: onTap,
    );
  }
}
