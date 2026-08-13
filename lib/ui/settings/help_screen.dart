import 'package:flutter/material.dart';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Aide'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: const [
            _HelpTopic(
              icon: Icons.location_on_outlined,
              title: 'Affichage des waypoints',
              paragraphs: [
                'Quand une trace GPX est chargée dans le Roadmap, seuls les '
                    'waypoints de cette trace sont affichés par défaut. Le '
                    'bouton d\'affichage des waypoints masque ou réaffiche '
                    'uniquement les waypoints de la trace chargée.',
                'Quand aucune trace n\'est chargée dans le Roadmap, ce sont '
                    'les waypoints de toutes les traces GPX actuellement '
                    'affichées sur la carte qui apparaissent, et le bouton '
                    'masque ou réaffiche les waypoints de l\'ensemble de ces '
                    'traces. Si aucune trace n\'est affichée, aucun waypoint '
                    'n\'apparaît.',
                'Dans les deux cas, un appui long sur le bouton affiche '
                    'l\'intégralité des waypoints existants dans le Waypoint '
                    'Manager (dossiers personnels compris), et un appui simple '
                    'suivant revient à l\'affichage de départ.',
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HelpTopic extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<String> paragraphs;

  const _HelpTopic({
    required this.icon,
    required this.title,
    required this.paragraphs,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.greenAccent, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final p in paragraphs) ...[
            Text(p, style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4)),
            if (p != paragraphs.last) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}
