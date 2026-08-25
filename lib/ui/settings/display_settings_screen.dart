import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:provider/provider.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../utils/settings_service.dart';
import 'maps_settings_screen.dart';
import 'navigation_customization_screen.dart';

class DisplaySettingsScreen extends StatelessWidget {
  const DisplaySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(loc.displaySettingsTitle),
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
                Text(loc.interfaceMapSectionTitle, style: headerStyle),
                const SizedBox(height: 12),

                // Couleur d'accent : cadres/titres/icônes de l'écran Outils
                // de navigation (d'autres éléments suivront plus tard).
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(loc.themeColorLabel, style: labelStyle),
                  subtitle: Text(
                      loc.themeColorSubtitle,
                      style: const TextStyle(color: Colors.white38, fontSize: 11)),
                  trailing: GestureDetector(
                    onTap: () => _pickAccentColor(context, settings),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: settings.accentColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white24),
                      ),
                    ),
                  ),
                  onTap: () => _pickAccentColor(context, settings),
                ),

                // Transparence : volets Paramètres / Outils de navigation
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(loc.settingsPanelOpacityLabel, style: labelStyle),
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
                    Text(loc.mainMenuOpacityLabel, style: labelStyle),
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
                    Text(loc.showScaleLabel, style: labelStyle),
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
                    Text(loc.leftHandedModeLabel, style: labelStyle),
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
                    Text(loc.swipeZonesLabel, style: labelStyle),
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
                    Text(loc.waypointIconSizeLabel, style: labelStyle),
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
                Text(loc.mapStartupSectionTitle, style: headerStyle),
                const SizedBox(height: 4),
                RadioListTile<MapStartupMode>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  activeColor: Colors.greenAccent,
                  title: Text(loc.resumeLastPositionLabel, style: labelStyle),
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
                  title: Text(loc.customPointLabel, style: labelStyle),
                  subtitle: settings.mapStartupMode == MapStartupMode.customPoint
                      ? Text(loc.customPointSubtitle,
                          style: const TextStyle(color: Colors.white38, fontSize: 11))
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
                Text(loc.gpxPreviewSectionTitle, style: headerStyle),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(loc.previewBasemapLabel, style: labelStyle),
                    ),
                    DropdownButton<String?>(
                      value: settings.tracePreviewMapSourceId,
                      dropdownColor: Colors.grey[900],
                      style: valueStyle,
                      underline: const SizedBox(),
                      onChanged: (id) => settings.setTracePreviewMapSourceId(id),
                      items: [
                        DropdownMenuItem<String?>(
                          value: null,
                          child: Text(loc.activeBasemapOption),
                        ),
                        ...availableSources.map(
                          (source) => DropdownMenuItem<String?>(
                            value: source.id,
                            child: Text(source.name),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                const Divider(color: Colors.white12, height: 24),
                Text(loc.accessibilitySectionTitle, style: headerStyle),
                const SizedBox(height: 4),
                RadioListTile<FontScaleLevel>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  activeColor: Colors.greenAccent,
                  title: Text(loc.fontSizeNormalLabel, style: labelStyle),
                  value: FontScaleLevel.normal,
                  groupValue: settings.fontScaleLevel,
                  onChanged: (level) {
                    if (level != null) settings.setFontScaleLevel(level);
                  },
                ),
                RadioListTile<FontScaleLevel>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  activeColor: Colors.greenAccent,
                  title: Text(loc.fontSizeLargeLabel, style: labelStyle),
                  value: FontScaleLevel.large,
                  groupValue: settings.fontScaleLevel,
                  onChanged: (level) {
                    if (level != null) settings.setFontScaleLevel(level);
                  },
                ),
                RadioListTile<FontScaleLevel>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  activeColor: Colors.greenAccent,
                  title: Text(loc.fontSizeExtraLargeLabel, style: labelStyle),
                  value: FontScaleLevel.extraLarge,
                  groupValue: settings.fontScaleLevel,
                  onChanged: (level) {
                    if (level != null) settings.setFontScaleLevel(level);
                  },
                ),

                const Divider(color: Colors.white12, height: 24),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(loc.customizeNavigationPanelLabel, style: headerStyle),
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

  void _pickAccentColor(BuildContext context, SettingsService settings) {
    final loc = AppLocalizations.of(context)!;
    Color selected = settings.accentColor;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: Colors.grey[900],
          title: Text(loc.themeColorLabel, style: const TextStyle(color: Colors.white)),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: selected,
              onColorChanged: (color) => setDialogState(() => selected = color),
              enableAlpha: false,
              displayThumbColor: true,
              paletteType: PaletteType.hsvWithHue,
              labelTypes: const [],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(loc.cancelButtonUppercase)),
            TextButton(
              onPressed: () {
                settings.setAccentColor(selected);
                Navigator.pop(context);
              },
              child: Text(loc.applyButtonUppercase, style: const TextStyle(color: Colors.greenAccent)),
            ),
          ],
        ),
      ),
    );
  }
}
