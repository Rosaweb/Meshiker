import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:isar_community/isar.dart';
import '../../database/isar_service.dart';
import '../../models/segment.dart';
import '../../utils/settings_service.dart';

class SegmentManagerScreen extends StatefulWidget {
  const SegmentManagerScreen({super.key});

  @override
  State<SegmentManagerScreen> createState() => _SegmentManagerScreenState();
}

class _SegmentManagerScreenState extends State<SegmentManagerScreen> {
  Future<void> _deleteSegment(IsarService isar, Segment segment) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Supprimer le segment', style: TextStyle(color: Colors.white)),
        content: const Text('Voulez-vous vraiment supprimer ce segment ?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('ANNULER')),
          TextButton(
            onPressed: () => Navigator.pop(context, true), 
            child: const Text('SUPPRIMER', style: TextStyle(color: Colors.redAccent))
          ),
        ],
      ),
    );

    if (confirm == true) {
      await isar.deleteSegment(segment.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isar = context.watch<IsarService>();
    final settings = context.watch<SettingsService>();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Mesh Manager'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: StreamBuilder<List<Segment>>(
            stream: isar.isar.segments.where().watch(fireImmediately: true),
            builder: (context, snapshot) {
              final segments = snapshot.data ?? [];
              final totalMeters = segments.fold<double>(0, (sum, s) => sum + s.distanceMeters);
              final totalDistance = settings.unitSystem == UnitSystem.metric
                  ? '${(totalMeters / 1000).toStringAsFixed(1)} km'
                  : '${(totalMeters * 0.000621371).toStringAsFixed(1)} mi';
              return Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 16.0, bottom: 8.0),
                  child: Text(
                    '${segments.length} segment${segments.length > 1 ? 's' : ''} · $totalDistance',
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
              );
            },
          ),
        ),
      ),
      body: StreamBuilder<List<Segment>>(
        stream: isar.isar.segments.where().watch(fireImmediately: true),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          
          final segments = snapshot.data!;
          if (segments.isEmpty) {
            return const Center(
              child: Text(
                'Aucun segment enregistré.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38),
              ),
            );
          }

          return ListView.builder(
            itemCount: segments.length,
            itemBuilder: (context, index) {
              final segment = segments[index];
              final distance = settings.unitSystem == UnitSystem.metric 
                ? '${(segment.distanceMeters / 1000).toStringAsFixed(2)} km'
                : '${(segment.distanceMeters * 0.000621371).toStringAsFixed(2)} mi';

              return ListTile(
                leading: const Icon(Icons.timeline, color: Colors.blueAccent),
                title: Text(
                  'Segment #${segment.id}',
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  '$distance | +${segment.elevationGainMeters.round()}m',
                  style: const TextStyle(color: Colors.white38),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.white38),
                  onPressed: () => _deleteSegment(isar, segment),
                ),
                onTap: () {
                  // TODO: Afficher détails sur la carte
                },
              );
            },
          );
        },
      ),
    );
  }
}
