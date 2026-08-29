import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../utils/settings_service.dart';
import '../waypoints/waypoint_announcement_settings_section.dart';

/// Paramètres du Roadmap (accessible via la roue crantée de son AppBar).
class RoadmapSettingsScreen extends StatelessWidget {
  const RoadmapSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();

    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Paramètres du Roadmap'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
        ),
        body: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.restart_alt, color: Colors.orangeAccent),
                title: const Text('Réinitialiser', style: TextStyle(color: Colors.white)),
                subtitle: const Text(
                  'Quitte la navigation en cours. La trace elle-même n\'est pas modifiée.',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
                onTap: () async {
                  final navigator = Navigator.of(context);
                  await context.read<SettingsService>().setRoadmapTraceName(null);
                  navigator.popUntil((route) => route.isFirst);
                },
              ),
            ),
            WaypointAnnouncementSettingsSection(
              enabled: settings.roadmapAnnouncementsEnabled,
              onEnabledChanged: (v) => settings.setRoadmapAnnouncementsEnabled(v),
              onApproach: settings.roadmapAnnounceOnApproach,
              onApproachChanged: (v) => settings.setRoadmapAnnounceTrigger('approach', v),
              onSpot: settings.roadmapAnnounceOnSpot,
              onSpotChanged: (v) => settings.setRoadmapAnnounceTrigger('onSpot', v),
              approachDistanceMeters: settings.roadmapAnnounceDistanceMeters,
              onApproachDistanceChanged: (v) => settings.setRoadmapAnnounceDistanceMeters(v),
              announceTitle: settings.roadmapAnnounceTitle,
              onAnnounceTitleChanged: (v) => settings.setRoadmapAnnounceContent('title', v),
              announceType: settings.roadmapAnnounceType,
              onAnnounceTypeChanged: (v) => settings.setRoadmapAnnounceContent('type', v),
              announceDescription: settings.roadmapAnnounceDescription,
              onAnnounceDescriptionChanged: (v) => settings.setRoadmapAnnounceContent('description', v),
            ),
          ],
        ),
      ),
    );
  }
}
