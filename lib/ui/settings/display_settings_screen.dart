import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../utils/settings_service.dart';
import 'navigation_customization_screen.dart';

class DisplaySettingsScreen extends StatelessWidget {
  const DisplaySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Paramètres d\'affichage'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
        ),
        body: Consumer<SettingsService>(
          builder: (context, settings, child) {
            const labelStyle = TextStyle(color: Colors.white, fontSize: 14);
            const valueStyle = TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 14);
            const headerStyle = TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent, fontSize: 11);

            return ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                const Text('INTERFACE ET CARTE', style: headerStyle),
                const SizedBox(height: 12),

                // Transparence : volets Paramètres / Outils de navigation
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Transparence menu Paramètres/Outils', style: labelStyle),
                    Text('${((1.1 - settings.barOpacity) * 100).round()}%', style: valueStyle),
                  ],
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(trackHeight: 2),
                  child: Slider(
                    value: 1.1 - settings.barOpacity,
                    min: 0.1, max: 1.0, divisions: 18,
                    onChanged: (v) => settings.setBarOpacity(1.1 - v),
                    activeColor: Colors.greenAccent, inactiveColor: Colors.white12,
                  ),
                ),

                // Transparence : menu de la page principale (barre de contrôle sur la carte)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Transparence menu principal', style: labelStyle),
                    Text('${((1.1 - settings.mainMenuOpacity) * 100).round()}%', style: valueStyle),
                  ],
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(trackHeight: 2),
                  child: Slider(
                    value: 1.1 - settings.mainMenuOpacity,
                    min: 0.1, max: 1.0, divisions: 18,
                    onChanged: (v) => settings.setMainMenuOpacity(1.1 - v),
                    activeColor: Colors.greenAccent, inactiveColor: Colors.white12,
                  ),
                ),

                // Échelle & Gaucher
                Row(
                  children: [
                    const Text('Afficher l\'échelle', style: labelStyle),
                    const Spacer(),
                    Switch(
                      value: settings.showScale,
                      onChanged: (v) => settings.setShowScale(v),
                      activeThumbColor: Colors.greenAccent,
                    ),
                  ],
                ),
                Row(
                  children: [
                    const Text('Mode Gaucher', style: labelStyle),
                    const Spacer(),
                    Switch(
                      value: settings.reversePanels,
                      onChanged: (v) => settings.setReversePanels(v),
                      activeThumbColor: Colors.greenAccent,
                    ),
                  ],
                ),

                const SizedBox(height: 12),
                // Zones de swipe
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Zones de swipe', style: labelStyle),
                    Text('${settings.edgeSwipeWidth.round()} px', style: valueStyle),
                  ],
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(trackHeight: 2),
                  child: Slider(
                    value: settings.edgeSwipeWidth,
                    min: 20, max: 80, divisions: 12,
                    onChanged: (v) => settings.setEdgeSwipeWidth(v),
                    activeColor: Colors.greenAccent, inactiveColor: Colors.white12,
                  ),
                ),

                // Taille icônes
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Taille icônes Waypoints', style: labelStyle),
                    Text('${settings.waypointIconSize.round()} px', style: valueStyle),
                  ],
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(trackHeight: 2),
                  child: Slider(
                    value: settings.waypointIconSize,
                    min: 20, max: 60, divisions: 8,
                    onChanged: (v) => settings.setWaypointIconSize(v),
                    activeColor: Colors.greenAccent, inactiveColor: Colors.white12,
                  ),
                ),

                const Divider(color: Colors.white12, height: 24),
                const Text('OUVERTURE DE LA CARTE', style: headerStyle),
                const SizedBox(height: 4),
                RadioListTile<MapStartupMode>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  activeColor: Colors.greenAccent,
                  title: const Text('Reprendre là où j\'ai arrêté', style: labelStyle),
                  value: MapStartupMode.lastPosition,
                  groupValue: settings.mapStartupMode,
                  onChanged: (mode) {
                    if (mode != null) settings.setMapStartupMode(mode);
                  },
                ),
                RadioListTile<MapStartupMode>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  activeColor: Colors.greenAccent,
                  title: const Text('Point personnalisé', style: labelStyle),
                  subtitle: settings.mapStartupMode == MapStartupMode.customPoint
                      ? const Text('Touchez pour choisir/modifier le point sur la carte',
                          style: TextStyle(color: Colors.white38, fontSize: 11))
                      : null,
                  value: MapStartupMode.customPoint,
                  groupValue: settings.mapStartupMode,
                  onChanged: (mode) {
                    if (mode == null) return;
                    settings.setMapStartupMode(mode);
                    settings.startPickStartupCenter();
                    Navigator.pop(context);
                  },
                ),

                const Divider(color: Colors.white12, height: 24),
                ListTile(
                  title: const Text('Personnaliser le volet de navigation', style: labelStyle),
                  trailing: const Icon(Icons.chevron_right, color: Colors.white24),
                  onTap: () {
                    final bool isReversed = settings.reversePanels;
                    Navigator.push(context, PageRouteBuilder(
                      pageBuilder: (context, animation, secondaryAnimation) => const NavigationCustomizationScreen(),
                      transitionsBuilder: (context, animation, secondaryAnimation, child) {
                        final beginOffset = isReversed ? const Offset(1, 0) : const Offset(-1, 0);
                        return SlideTransition(
                          position: Tween<Offset>(begin: beginOffset, end: Offset.zero).animate(animation),
                          child: child,
                        );
                      },
                    ));
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
