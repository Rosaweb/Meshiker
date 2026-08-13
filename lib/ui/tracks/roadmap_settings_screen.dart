import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../utils/settings_service.dart';

/// Paramètres du Roadmap (accessible via la roue crantée de son AppBar).
/// Pour l'instant, seule la réinitialisation de la navigation -- amené à
/// grossir (ex: annonce vocale de proximité des waypoints).
class RoadmapSettingsScreen extends StatelessWidget {
  const RoadmapSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
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
          padding: const EdgeInsets.all(16),
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.restart_alt, color: Colors.orangeAccent),
              title: const Text('Réinitialiser', style: TextStyle(color: Colors.white)),
              subtitle: const Text(
                'Quitte la navigation en cours. La trace elle-même n\'est pas modifiée.',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
              onTap: () async {
                final settings = context.read<SettingsService>();
                final navigator = Navigator.of(context);
                await settings.setRoadmapTraceName(null);
                navigator.popUntil((route) => route.isFirst);
              },
            ),
          ],
        ),
      ),
    );
  }
}
