import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../utils/settings_service.dart';

class DisplaySettingsScreen extends StatelessWidget {
  const DisplaySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Affichage'),
      ),
      body: Consumer<SettingsService>(
        builder: (context, settings, child) {
          return ListView(
            children: [
              ListTile(
                title: const Text('Transparence du bandeau'),
                subtitle: Text('${(settings.barOpacity * 100).round()}%'),
              ),
              Slider(
                value: settings.barOpacity,
                min: 0.1,
                max: 1.0,
                divisions: 18,
                label: '${(settings.barOpacity * 100).round()}%',
                onChanged: (value) => settings.setBarOpacity(value),
              ),
              const Divider(),
              SwitchListTile(
                title: const Text('Afficher l\'échelle de carte'),
                subtitle: const Text('Affiche un segment de distance au-dessus des boutons'),
                value: settings.showScale,
                onChanged: (value) => settings.setShowScale(value),
              ),
              SwitchListTile(
                title: const Text('Mode Gaucher'),
                subtitle: const Text('Inverse les volets latéraux pour une utilisation à la main gauche'),
                value: settings.reversePanels,
                onChanged: (value) => settings.setReversePanels(value),
              ),
              const Divider(),
              ListTile(
                title: const Text('Taille des icônes de Waypoints'),
                subtitle: Text('${settings.waypointIconSize.round()} px'),
              ),
              Slider(
                value: settings.waypointIconSize,
                min: 20,
                max: 60,
                divisions: 8,
                label: '${settings.waypointIconSize.round()} px',
                onChanged: (value) => settings.setWaypointIconSize(value),
              ),
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text(
                  'Note : La couleur de l\'échelle s\'adapte automatiquement selon la transparence pour rester lisible.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
