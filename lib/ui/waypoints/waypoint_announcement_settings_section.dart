import 'package:flutter/material.dart';

/// Section "ANNONCES VOCALES" réutilisée à l'identique dans les paramètres
/// du waypoint manager et du roadmap (cf. UI-annonce-waypoints.txt) — même
/// UI, deux jeux de réglages indépendants passés par l'appelant.
class WaypointAnnouncementSettingsSection extends StatelessWidget {
  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;
  final bool onApproach;
  final ValueChanged<bool> onApproachChanged;
  final bool onSpot;
  final ValueChanged<bool> onSpotChanged;
  final double approachDistanceMeters;
  final ValueChanged<double> onApproachDistanceChanged;
  final bool announceTitle;
  final ValueChanged<bool> onAnnounceTitleChanged;
  final bool announceType;
  final ValueChanged<bool> onAnnounceTypeChanged;
  final bool announceDescription;
  final ValueChanged<bool> onAnnounceDescriptionChanged;

  const WaypointAnnouncementSettingsSection({
    super.key,
    required this.enabled,
    required this.onEnabledChanged,
    required this.onApproach,
    required this.onApproachChanged,
    required this.onSpot,
    required this.onSpotChanged,
    required this.approachDistanceMeters,
    required this.onApproachDistanceChanged,
    required this.announceTitle,
    required this.onAnnounceTitleChanged,
    required this.announceType,
    required this.onAnnounceTypeChanged,
    required this.announceDescription,
    required this.onAnnounceDescriptionChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Colors.white.withValues(alpha: 0.05),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('ANNONCES VOCALES', style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SwitchListTile(
            title: const Text('Activer les annonces vocales', style: TextStyle(color: Colors.white, fontSize: 14)),
            subtitle: const Text(
              'Annonce le waypoint à voix haute à l\'approche et/ou à l\'arrivée, entièrement hors ligne',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            value: enabled,
            activeThumbColor: Colors.greenAccent,
            onChanged: onEnabledChanged,
          ),
          AnimatedOpacity(
            opacity: enabled ? 1.0 : 0.4,
            duration: const Duration(milliseconds: 150),
            child: IgnorePointer(
              ignoring: !enabled,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    title: const Text('Annonce à l\'approche', style: TextStyle(color: Colors.white, fontSize: 14)),
                    subtitle: const Text('Prévient avant d\'arriver, à la distance réglée ci-dessous', style: TextStyle(color: Colors.white38, fontSize: 12)),
                    value: onApproach,
                    activeThumbColor: Colors.greenAccent,
                    onChanged: onApproachChanged,
                  ),
                  SwitchListTile(
                    title: const Text('Annonce sur place', style: TextStyle(color: Colors.white, fontSize: 14)),
                    subtitle: const Text('Confirme l\'arrivée effective au waypoint', style: TextStyle(color: Colors.white38, fontSize: 12)),
                    value: onSpot,
                    activeThumbColor: Colors.greenAccent,
                    onChanged: onSpotChanged,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Row(
                      children: [
                        const Text('Distance de l\'annonce d\'approche', style: TextStyle(color: Colors.white70, fontSize: 13)),
                        const Spacer(),
                        Text(
                          '${approachDistanceMeters.round()} m',
                          style: const TextStyle(color: Colors.greenAccent, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(trackHeight: 2),
                      child: Slider(
                        value: approachDistanceMeters.clamp(50, 300),
                        min: 50,
                        max: 300,
                        divisions: 10,
                        activeColor: Colors.greenAccent,
                        inactiveColor: Colors.white12,
                        onChanged: onApproachDistanceChanged,
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text('CONTENU DE L\'ANNONCE', style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                  SwitchListTile(
                    title: const Text('Titre', style: TextStyle(color: Colors.white, fontSize: 14)),
                    value: announceTitle,
                    activeThumbColor: Colors.greenAccent,
                    onChanged: onAnnounceTitleChanged,
                  ),
                  SwitchListTile(
                    title: const Text('Type', style: TextStyle(color: Colors.white, fontSize: 14)),
                    value: announceType,
                    activeThumbColor: Colors.greenAccent,
                    onChanged: onAnnounceTypeChanged,
                  ),
                  SwitchListTile(
                    title: const Text('Description', style: TextStyle(color: Colors.white, fontSize: 14)),
                    value: announceDescription,
                    activeThumbColor: Colors.greenAccent,
                    onChanged: onAnnounceDescriptionChanged,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
