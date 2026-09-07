import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import '../../database/isar_service.dart';
import '../../utils/crash_reporting_service.dart';
import '../../utils/settings_service.dart';
import '../../utils/tile_cache_service.dart';
import '../../utils/photo_scanner_service.dart';
import '../../gpx/gpx_scanner_service.dart';

class SystemSettingsScreen extends StatelessWidget {
  const SystemSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Paramètres système'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
        ),
        body: Consumer2<SettingsService, TileCacheService>(
          builder: (context, settings, cacheService, child) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('UNITÉS DE MESURE', style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                _buildUnitsSection(context, settings),
                const SizedBox(height: 32),
                const Text('STOCKAGE GPX/KML', style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                _buildGpxStorageSection(context, settings),
                const SizedBox(height: 32),
                const Text('ENREGISTREMENT DES TRACES', style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                _buildRecordingSection(context, settings),
                const SizedBox(height: 32),
                const Text('CACHE DES CARTES', style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                _buildCacheSection(context, settings, cacheService),
                const SizedBox(height: 32),
                const Text('RÉSEAU ET TÉLÉCHARGEMENT', style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                _buildNetworkSection(context, settings),
                const SizedBox(height: 32),
                const Text('PHOTOS', style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                _buildPhotoSection(context),
                const SizedBox(height: 32),
                const Text('ASSISTANT IA', style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                _buildAiAssistantSection(context, settings),
                const SizedBox(height: 32),
                const Text('RAPPORTS DE PLANTAGE', style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                _buildCrashReportingSection(context, settings),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildUnitsSection(BuildContext context, SettingsService settings) {
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
                    const Text('Métrique', style: labelStyle),
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
                    const Text('Impérial', style: labelStyle),
                  ],
                ),
              ),
            ],
          ),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'S\'applique à toute l\'application, météo comprise (température, '
              'vent, précipitations). La pression reste en hPa.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoSection(BuildContext context) {
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
          const Text('Stockage public', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'Les photos prises dans l\'app sont enregistrées dans le dossier "Images/Meshiker" de votre téléphone pour être visibles dans votre galerie habituelle.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () async {
              final scanner = PhotoScannerService();
              final messenger = ScaffoldMessenger.of(context);
              messenger.showSnackBar(
                const SnackBar(content: Text('Recherche de nouvelles photos...')),
              );
              
              final photos = await scanner.scanPhotos();
              
              messenger.showSnackBar(
                SnackBar(content: Text('${photos.length} photos trouvées dans le dossier Meshiker.')),
              );
            },
            icon: const Icon(Icons.photo_library),
            label: const Text('Synchroniser la galerie'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.white10, foregroundColor: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildNetworkSection(BuildContext context, SettingsService settings) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: SwitchListTile(
        title: const Text('Wi-Fi uniquement', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        subtitle: const Text('N\'autoriser le téléchargement des cartes qu\'en Wi-Fi', style: TextStyle(color: Colors.white38, fontSize: 12)),
        value: settings.wifiOnlyDownload,
        onChanged: (v) => settings.setWifiOnlyDownload(v),
        activeThumbColor: Colors.greenAccent,
        contentPadding: EdgeInsets.zero,
      ),
    );
  }

  Widget _buildGpxStorageSection(BuildContext context, SettingsService settings) {
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
          const Text('Dossier personnalisé', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            settings.gpxStoragePath ?? 'Utiliser le stockage par défaut',
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
                               content: const Text(
                                   'Accès au stockage refusé : autorisez "Tous les fichiers" pour Meshiker dans les paramètres Android.'),
                               duration: const Duration(seconds: 5),
                               action: SnackBarAction(
                                 label: 'PARAMÈTRES',
                                 onPressed: () => ph.openAppSettings(),
                               ),
                             ),
                           );
                         }
                      }
                    }
                  },
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Sélectionner'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.white10, foregroundColor: Colors.white),
                ),
              ),
              if (settings.gpxStoragePath != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () => settings.setGpxStoragePath(null),
                  icon: const Icon(Icons.refresh, color: Colors.orangeAccent),
                  tooltip: 'Réinitialiser',
                ),
              ],
            ],
          ),
          
          if (settings.gpxStoragePath != null) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
            ),
            const Text('Dossier des traces enregistrées', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
                              const SnackBar(content: Text('Le dossier doit être à l\'intérieur du répertoire racine GPX.')),
                            );
                          }
                        }
                      }
                    },
                    icon: const Icon(Icons.create_new_folder),
                    label: const Text('Sélectionner'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.white10, foregroundColor: Colors.white),
                  ),
                ),
                if (settings.recordingSubPath != null) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () => settings.setRecordingSubPath(null),
                    icon: const Icon(Icons.close, color: Colors.redAccent),
                    tooltip: 'Utiliser la racine',
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRecordingSection(BuildContext context, SettingsService settings) {
    const labelStyle = TextStyle(color: Colors.white, fontSize: 14);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          SwitchListTile(
            title: const Text('Enregistrer les pauses dans la trace', style: labelStyle),
            subtitle: const Text(
              'Désactivé par défaut : les points GPS pendant un arrêt prolongé '
              'ne sont pas ajoutés à la trace. À activer pour que la trace '
              'reflète fidèlement les pauses (repas, photo...).',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            value: settings.recordPauses,
            onChanged: (v) => settings.setRecordPauses(v),
            activeThumbColor: Colors.greenAccent,
            contentPadding: EdgeInsets.zero,
          ),
          const Divider(color: Colors.white12, height: 24),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Durée avant détection d\'une pause', style: labelStyle),
            subtitle: Text(settings.stationaryWindowPreset.label, style: const TextStyle(color: Colors.white38, fontSize: 12)),
            trailing: const Icon(Icons.chevron_right, color: Colors.white38),
            onTap: () => _pickStationaryWindow(context, settings),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Rayon de détection d\'une pause', style: labelStyle),
            subtitle: Text(settings.stationaryRadiusPreset.label, style: const TextStyle(color: Colors.white38, fontSize: 12)),
            trailing: const Icon(Icons.chevron_right, color: Colors.white38),
            onTap: () => _pickStationaryRadius(context, settings),
          ),
        ],
      ),
    );
  }

  void _pickStationaryWindow(BuildContext context, SettingsService settings) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Durée avant détection d\'une pause', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final preset in StationaryWindowPreset.values)
              RadioListTile<StationaryWindowPreset>(
                contentPadding: EdgeInsets.zero,
                dense: true,
                activeColor: Colors.greenAccent,
                title: Text(preset.label, style: const TextStyle(color: Colors.white)),
                value: preset,
                groupValue: settings.stationaryWindowPreset,
                onChanged: (value) {
                  if (value != null) settings.setStationaryWindowPreset(value);
                  Navigator.pop(context);
                },
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('ANNULER')),
        ],
      ),
    );
  }

  void _pickStationaryRadius(BuildContext context, SettingsService settings) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Rayon de détection d\'une pause', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final preset in StationaryRadiusPreset.values)
              RadioListTile<StationaryRadiusPreset>(
                contentPadding: EdgeInsets.zero,
                dense: true,
                activeColor: Colors.greenAccent,
                title: Text(preset.label, style: const TextStyle(color: Colors.white)),
                value: preset,
                groupValue: settings.stationaryRadiusPreset,
                onChanged: (value) {
                  if (value != null) settings.setStationaryRadiusPreset(value);
                  Navigator.pop(context);
                },
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('ANNULER')),
        ],
      ),
    );
  }

  Widget _buildAiAssistantSection(BuildContext context, SettingsService settings) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: SwitchListTile(
        title: const Text('Désactiver l\'assistant IA', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        subtitle: const Text(
          'Masque les points d\'entrée de l\'assistant conversationnel dans l\'aide et la navigation. '
          'Les annonces vocales des waypoints ne sont pas concernées.',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
        value: settings.aiAssistantDisabled,
        onChanged: (v) => settings.setAiAssistantDisabled(v),
        activeThumbColor: Colors.greenAccent,
        contentPadding: EdgeInsets.zero,
      ),
    );
  }

  Widget _buildCrashReportingSection(BuildContext context, SettingsService settings) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          SwitchListTile(
            title: const Text('Envoyer des rapports de plantage automatiques', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            subtitle: const Text(
              'Aide à identifier et corriger les bugs. Les comptes Premium peuvent '
              'relire, annoter ou annuler un rapport avant son envoi depuis '
              '"Mon compte > Rapport de bug". Un changement ne prend effet qu\'au '
              'prochain lancement de l\'app.',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            value: settings.crashReportingEnabled,
            onChanged: (v) async {
              await settings.setCrashReportingEnabled(v);
              if (!v && context.mounted) {
                // Purge silencieuse immédiate des rapports premium en attente
                // (spec-crash-reporting.md §4) : aucun envoi, aucune notification.
                await CrashReportingService.purgeAllPending(context.read<IsarService>());
              }
            },
            activeThumbColor: Colors.greenAccent,
            contentPadding: EdgeInsets.zero,
          ),
          // Vérification Sentry : uniquement en build de debug, jamais livré
          // aux utilisateurs. Lève une exception NON interceptée pour exercer
          // le vrai chemin de capture automatique (FlutterError.onError ->
          // intégration Sentry). Pour un compte Premium, l'event part d'abord
          // dans la file d'attente locale (spec §5.2) : le pousser ensuite
          // depuis "Mon compte > Rapport de bug", ou attendre 3 lancements.
          if (kDebugMode) ...[
            const Divider(color: Colors.white12, height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () {
                  throw StateError('Meshiker: test de vérification Sentry (déclenché manuellement)');
                },
                icon: const Icon(Icons.bug_report),
                label: const Text('Déclencher une erreur test (debug)'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.orangeAccent,
                  side: const BorderSide(color: Colors.orangeAccent),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCacheSection(BuildContext context, SettingsService settings, TileCacheService cacheService) {
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
              const Text('Taille du cache', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
              const Text('Utilisation actuelle', style: TextStyle(color: Colors.white70, fontSize: 12)),
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
            label: const Text('VIDER LE CACHE'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: const BorderSide(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}
