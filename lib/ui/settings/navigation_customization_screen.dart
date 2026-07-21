import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../utils/settings_service.dart';

class NavigationCustomizationScreen extends StatelessWidget {
  const NavigationCustomizationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Personnaliser la navigation'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
        ),
        body: Consumer<SettingsService>(
          builder: (context, settings, child) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'CHOISISSEZ LES ÉLÉMENTS À AFFICHER',
                  style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                _buildToggle(context, settings, 'Vitesse (actuelle, jour, gén.)', settings.navShowSpeed, 'speed'),
                _buildToggle(context, settings, 'Distance du jour', settings.navShowDailyDist, 'dailyDist'),
                _buildToggle(context, settings, 'Distances sur la trace', settings.navShowTraceDist, 'traceDist'),
                _buildToggle(context, settings, 'Précision satellite', settings.navShowGpsAccuracy, 'gpsAccuracy'),
                _buildToggle(context, settings, 'Nombre de satellites / Statut', settings.navShowSatellites, 'satellites'),
                _buildToggle(context, settings, 'Podomètre', settings.navShowPedometer, 'pedometer'),
                const Divider(color: Colors.white12, height: 32),
                _buildToggle(context, settings, 'Prochain waypoint', settings.navShowNextWaypoint, 'nextWaypoint'),
                _buildToggle(context, settings, 'Point de destination', settings.navShowDestination, 'destination'),
                _buildToggle(context, settings, 'Outils de mesure (Azimut/Dist)', settings.navShowMeasureTools, 'measureTools'),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildToggle(BuildContext context, SettingsService settings, String label, bool value, String key) {
    return SwitchListTile(
      title: Text(label, style: const TextStyle(color: Colors.white, fontSize: 14)),
      value: value,
      onChanged: (v) => settings.setNavVisibility(key, v),
      activeThumbColor: Colors.greenAccent,
      contentPadding: EdgeInsets.zero,
    );
  }
}
