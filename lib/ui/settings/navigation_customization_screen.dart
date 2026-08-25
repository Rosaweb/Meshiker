import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../utils/settings_service.dart';

class NavigationCustomizationScreen extends StatelessWidget {
  const NavigationCustomizationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(loc.navCustomizeTitle),
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
        ),
        body: Consumer<SettingsService>(
          builder: (context, settings, child) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  loc.navCustomizeSectionTitle,
                  style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                _buildToggle(context, settings, loc.navToggleSpeed, settings.navShowSpeed, 'speed'),
                _buildToggle(context, settings, loc.navToggleDailyDist, settings.navShowDailyDist, 'dailyDist'),
                _buildToggle(context, settings, loc.navToggleTraceDist, settings.navShowTraceDist, 'traceDist'),
                _buildToggle(context, settings, loc.navToggleGpsAccuracy, settings.navShowGpsAccuracy, 'gpsAccuracy'),
                _buildToggle(context, settings, loc.navToggleSatellites, settings.navShowSatellites, 'satellites'),
                _buildToggle(context, settings, loc.statPedometerLabel, settings.navShowPedometer, 'pedometer'),
                const Divider(color: Colors.white12, height: 32),
                _buildToggle(context, settings, loc.navToggleNextWaypoint, settings.navShowNextWaypoint, 'nextWaypoint'),
                _buildToggle(context, settings, loc.navToggleDestination, settings.navShowDestination, 'destination'),
                _buildToggle(context, settings, loc.navTogglePois, settings.navShowPois, 'pois'),
                _buildToggle(context, settings, loc.navToggleMeasureTools, settings.navShowMeasureTools, 'measureTools'),
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
