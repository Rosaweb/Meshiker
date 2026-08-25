import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import '../../l10n/generated/app_localizations.dart';
import '../../utils/settings_service.dart';
import '../../utils/tile_cache_service.dart';
import '../../utils/photo_scanner_service.dart';
import '../../gpx/gpx_scanner_service.dart';

class SystemSettingsScreen extends StatelessWidget {
  const SystemSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(loc.systemSettingsTitle),
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
        ),
        body: Consumer2<SettingsService, TileCacheService>(
          builder: (context, settings, cacheService, child) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(loc.languageSectionTitle, style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                _buildLanguageSection(context, settings),
                const SizedBox(height: 32),
                Text(loc.unitsSectionTitle, style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                _buildUnitsSection(context, settings),
                const SizedBox(height: 32),
                Text(loc.gpxStorageSectionTitle, style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                _buildGpxStorageSection(context, settings),
                const SizedBox(height: 32),
                Text(loc.cacheSectionTitle, style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                _buildCacheSection(context, settings, cacheService),
                const SizedBox(height: 32),
                Text(loc.networkSectionTitle, style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                _buildNetworkSection(context, settings),
                const SizedBox(height: 32),
                Text(loc.photosSectionTitle, style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                _buildPhotoSection(context),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildLanguageSection(BuildContext context, SettingsService settings) {
    final loc = AppLocalizations.of(context)!;
    const labelStyle = TextStyle(color: Colors.white, fontSize: 14);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          RadioListTile<AppLanguage>(
            dense: true,
            activeColor: Colors.greenAccent,
            title: Text(loc.languageSystemOption, style: labelStyle),
            value: AppLanguage.system,
            groupValue: settings.appLanguage,
            onChanged: (lang) {
              if (lang != null) settings.setAppLanguage(lang);
            },
          ),
          RadioListTile<AppLanguage>(
            dense: true,
            activeColor: Colors.greenAccent,
            title: Text(loc.languageFrenchOption, style: labelStyle),
            value: AppLanguage.fr,
            groupValue: settings.appLanguage,
            onChanged: (lang) {
              if (lang != null) settings.setAppLanguage(lang);
            },
          ),
          RadioListTile<AppLanguage>(
            dense: true,
            activeColor: Colors.greenAccent,
            title: Text(loc.languageEnglishOption, style: labelStyle),
            value: AppLanguage.en,
            groupValue: settings.appLanguage,
            onChanged: (lang) {
              if (lang != null) settings.setAppLanguage(lang);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildUnitsSection(BuildContext context, SettingsService settings) {
    final loc = AppLocalizations.of(context)!;
    const labelStyle = TextStyle(color: Colors.white, fontSize: 14);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Radio<UnitSystem>(
                      value: UnitSystem.metric,
                      groupValue: settings.unitSystem,
                      onChanged: (v) => v != null ? settings.setUnitSystem(v) : null,
                      activeColor: Colors.greenAccent,
                      visualDensity: VisualDensity.compact,
                    ),
                    Text(loc.unitMetricLabel, style: labelStyle),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    Radio<UnitSystem>(
                      value: UnitSystem.imperial,
                      groupValue: settings.unitSystem,
                      onChanged: (v) => v != null ? settings.setUnitSystem(v) : null,
                      activeColor: Colors.greenAccent,
                      visualDensity: VisualDensity.compact,
                    ),
                    Text(loc.unitImperialLabel, style: labelStyle),
                  ],
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Radio<bool>(
                      value: true,
                      groupValue: settings.useCelsius,
                      onChanged: (v) => v != null ? settings.setTemperatureUnit(v) : null,
                      activeColor: Colors.greenAccent,
                      visualDensity: VisualDensity.compact,
                    ),
                    Text(loc.unitCelsiusLabel, style: labelStyle),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    Radio<bool>(
                      value: false,
                      groupValue: settings.useCelsius,
                      onChanged: (v) => v != null ? settings.setTemperatureUnit(v) : null,
                      activeColor: Colors.greenAccent,
                      visualDensity: VisualDensity.compact,
                    ),
                    Text(loc.unitFahrenheitLabel, style: labelStyle),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoSection(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(loc.publicStorageLabel, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            loc.publicStorageDescription,
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () async {
              final scanner = PhotoScannerService();
              final messenger = ScaffoldMessenger.of(context);
              messenger.showSnackBar(
                SnackBar(content: Text(loc.scanningPhotosMessage)),
              );

              final photos = await scanner.scanPhotos();

              messenger.showSnackBar(
                SnackBar(content: Text(loc.photosFoundMessage(photos.length))),
              );
            },
            icon: const Icon(Icons.photo_library),
            label: Text(loc.syncGalleryButton),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.white10, foregroundColor: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildNetworkSection(BuildContext context, SettingsService settings) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: SwitchListTile(
        title: Text(loc.wifiOnlyLabel, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        subtitle: Text(loc.wifiOnlySubtitle, style: const TextStyle(color: Colors.white38, fontSize: 12)),
        value: settings.wifiOnlyDownload,
        onChanged: (v) => settings.setWifiOnlyDownload(v),
        activeThumbColor: Colors.greenAccent,
        contentPadding: EdgeInsets.zero,
      ),
    );
  }

  Widget _buildGpxStorageSection(BuildContext context, SettingsService settings) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(loc.customFolderLabel, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            settings.gpxStoragePath ?? loc.useDefaultStorageLabel,
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () async {
                    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
                    if (selectedDirectory != null) {
                      settings.setGpxStoragePath(selectedDirectory);
                      // Déclencher un scan immédiat après la sélection
                      if (context.mounted) {
                         final scanner = context.read<GpxScannerService>();
                         final result = await scanner.scanFolder(selectedDirectory);
                         if (context.mounted && result == GpxScanResult.permissionDenied) {
                           ScaffoldMessenger.of(context).showSnackBar(
                             SnackBar(
                               content: Text(loc.storageAccessDeniedMessage),
                               duration: const Duration(seconds: 5),
                               action: SnackBarAction(
                                 label: loc.settingsSnackbarAction,
                                 onPressed: () => ph.openAppSettings(),
                               ),
                             ),
                           );
                         }
                      }
                    }
                  },
                  icon: const Icon(Icons.folder_open),
                  label: Text(loc.selectButtonLabel),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.white10, foregroundColor: Colors.white),
                ),
              ),
              if (settings.gpxStoragePath != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () => settings.setGpxStoragePath(null),
                  icon: const Icon(Icons.refresh, color: Colors.orangeAccent),
                  tooltip: loc.resetTooltip,
                ),
              ],
            ],
          ),

          if (settings.gpxStoragePath != null) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
            ),
            Text(loc.recordingFolderLabel, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
                      if (selectedDirectory != null) {
                        // On vérifie que c'est bien dans le répertoire racine
                        if (selectedDirectory.startsWith(settings.gpxStoragePath!)) {
                           settings.setRecordingSubPath(selectedDirectory);
                        } else {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(loc.folderMustBeInsideRootMessage)),
                            );
                          }
                        }
                      }
                    },
                    icon: const Icon(Icons.create_new_folder),
                    label: Text(loc.selectButtonLabel),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.white10, foregroundColor: Colors.white),
                  ),
                ),
                if (settings.recordingSubPath != null) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () => settings.setRecordingSubPath(null),
                    icon: const Icon(Icons.close, color: Colors.redAccent),
                    tooltip: loc.useRootFolderTooltip,
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCacheSection(BuildContext context, SettingsService settings, TileCacheService cacheService) {
    final loc = AppLocalizations.of(context)!;
    return Container(
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
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(loc.cacheSizeLabel, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              Text('${settings.tileCacheLimitMb.round()} MB', style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
            ],
          ),
          Slider(
            value: settings.tileCacheLimitMb,
            min: 100,
            max: 5000,
            divisions: 49,
            label: '${settings.tileCacheLimitMb.round()} MB',
            onChanged: (v) => settings.setTileCacheLimitMb(v),
            activeColor: Colors.greenAccent,
            inactiveColor: Colors.white12,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(loc.currentUsageLabel, style: const TextStyle(color: Colors.white70, fontSize: 12)),
              Text('${cacheService.currentSizeMb.toStringAsFixed(1)} MB', style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: (cacheService.currentSizeMb / settings.tileCacheLimitMb).clamp(0, 1),
            backgroundColor: Colors.white10,
            valueColor: const AlwaysStoppedAnimation<Color>(Colors.greenAccent),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () => cacheService.clearAll(),
            icon: const Icon(Icons.delete_sweep),
            label: Text(loc.clearCacheButton),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: const BorderSide(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}
