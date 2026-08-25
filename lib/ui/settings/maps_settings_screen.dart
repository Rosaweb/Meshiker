import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:isar_community/isar.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../utils/offline_map_download_service.dart';
import '../../utils/settings_service.dart';
import '../../database/isar_service.dart';
import '../../models/offline_map/offline_map.dart';

class MapSourceInfo {
  final String id;
  final String name;
  final String url;
  final String description;

  MapSourceInfo({required this.id, required this.name, required this.url, required this.description});
}

final List<MapSourceInfo> availableSources = [
  MapSourceInfo(
    id: 'osm_standard',
    name: 'OpenStreetMap',
    url: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    description: 'Carte routière et sentiers standard.',
  ),
  MapSourceInfo(
    id: 'opentopo',
    name: 'OpenTopoMap',
    url: 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
    description: 'Carte topographique avec courbes de niveau.',
  ),
  MapSourceInfo(
    id: 'cyclosm',
    name: 'CyclOSM',
    url: 'https://{s}.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png',
    description: 'Orientée vélo et relief accentué.',
  ),
  MapSourceInfo(
    id: 'google_sat',
    name: 'Google Satellite',
    url: 'https://mt1.google.com/vt/lyrs=s&x={x}&y={y}&z={z}',
    description: 'Vue satellite mondiale par Google.',
  ),
  MapSourceInfo(
    id: 'arcgis_sat',
    name: 'ArcGIS Satellite',
    url: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    description: 'Imagerie mondiale haute résolution ArcGIS.',
  ),
];

class MapsSettingsScreen extends StatelessWidget {
  const MapsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return DefaultTabController(
      length: 2,
      child: Container(
        color: Colors.black.withValues(alpha: 0.85),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: Text(loc.mapsSettingsTitle),
            backgroundColor: Colors.transparent,
            elevation: 0,
            foregroundColor: Colors.white,
            bottom: TabBar(
              tabs: [
                Tab(text: loc.onlineSourcesTabLabel),
                Tab(text: loc.offlineMapsTabLabel),
              ],
              indicatorColor: Colors.greenAccent,
              labelColor: Colors.greenAccent,
              unselectedLabelColor: Colors.white70,
            ),
          ),
          body: const TabBarView(
            children: [
              _OnlineSourcesTab(),
              _OfflineMapsTab(),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnlineSourcesTab extends StatelessWidget {
  const _OnlineSourcesTab();

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Consumer<SettingsService>(
      builder: (context, settings, child) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                loc.favoriteMapsInstructionText,
                style: const TextStyle(color: Colors.white38),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: availableSources.length,
                itemBuilder: (context, index) {
                  final source = availableSources[index];
                  final favIndex = settings.favoriteMapIds.indexOf(source.id);
                  final isSelected = favIndex != -1;

                  return ListTile(
                    title: Text(source.name, style: const TextStyle(color: Colors.white)),
                    subtitle: Text(source.description, style: const TextStyle(color: Colors.white70)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isSelected)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.greenAccent.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.5)),
                            ),
                            child: Text(
                              loc.priorityBadgeLabel(favIndex + 1),
                              style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ),
                        Checkbox(
                          value: isSelected,
                          onChanged: (checked) {
                            List<String> current = List.from(settings.favoriteMapIds);
                            if (checked == true) {
                              if (current.length < 3) current.add(source.id);
                            } else {
                              current.remove(source.id);
                            }
                            settings.setFavoriteMaps(current);
                          },
                          checkColor: Colors.black,
                          activeColor: Colors.greenAccent,
                          side: const BorderSide(color: Colors.white38),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _OfflineMapsTab extends StatelessWidget {
  const _OfflineMapsTab();

  @override
  Widget build(BuildContext context) {
    final isar = context.watch<IsarService>();
    final settings = context.watch<SettingsService>();
    final loc = AppLocalizations.of(context)!;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    settings.startMapCreation();
                    Navigator.pop(context); // Close panels to show map
                  },
                  icon: const Icon(Icons.add_location_alt),
                  label: Text(loc.createOfflineMapButton),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.greenAccent,
                    foregroundColor: Colors.black,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () async {
                    // FileType.custom + allowedExtensions plante sur
                    // certains appareils Android avec "Unsupported filter"
                    // dès que l'extension n'a pas de type MIME enregistré
                    // par le système (cas de .mbtiles) — on filtre donc
                    // nous-mêmes après coup, comme suggéré par le plugin.
                    final result = await FilePicker.platform.pickFiles(
                      type: FileType.any,
                    );
                    final path = result?.files.single.path;
                    if (path == null) return;
                    if (!path.toLowerCase().endsWith('.mbtiles')) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content: Text(loc.selectMbtilesFileMessage)),
                        );
                      }
                      return;
                    }
                    // TODO: l'import effectif (copie + enregistrement en
                    // OfflineMap) n'est pas encore implémenté — le
                    // téléchargement de "Créer une carte" est lui-même un
                    // mock pour le moment (cf. _showSaveDialog).
                  },
                  icon: const Icon(Icons.file_download),
                  label: Text(loc.importButton),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white10,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<OfflineMap>>(
            stream: isar.isar.offlineMaps.where().watch(fireImmediately: true),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              final maps = snapshot.data!;

              if (maps.isEmpty) {
                return Center(
                  child: Text(loc.noOfflineMapsMessage, style: const TextStyle(color: Colors.white38)),
                );
              }

              return ListView.builder(
                itemCount: maps.length,
                itemBuilder: (context, index) {
                  final map = maps[index];
                  final sizeMb = (map.sizeBytes / (1024 * 1024)).toStringAsFixed(1);
                  final description = map.description;
                  // Téléchargement coupé en route (app tuée, perte réseau)
                  // avant d'atteindre 100% ou d'être marqué en erreur --
                  // distinct de isError (échec confirmé) et de isDownloading
                  // (en cours dans CETTE session). Voir
                  // IsarService.resetStuckOfflineMapDownloads.
                  final isInterrupted = !map.isDownloading &&
                      !map.isError &&
                      map.downloadProgress > 0 &&
                      map.downloadProgress < 1.0;

                  return ListTile(
                    leading: const Icon(Icons.map, color: Colors.greenAccent),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            map.name,
                            style: const TextStyle(color: Colors.white),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                        Text(
                          '  •  $sizeMb MB',
                          style: const TextStyle(color: Colors.white38),
                        ),
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (description != null && description.isNotEmpty)
                          Text(
                            description,
                            style: const TextStyle(color: Colors.white38),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        if (map.isDownloading)
                          Padding(
                            padding: const EdgeInsets.only(top: 8.0),
                            child: Row(
                              children: [
                                Expanded(
                                  child: LinearProgressIndicator(
                                    value: map.downloadProgress,
                                    backgroundColor: Colors.white10,
                                    valueColor: const AlwaysStoppedAnimation(Colors.greenAccent),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  '${(map.downloadProgress * 100).round()}%',
                                  style: const TextStyle(color: Colors.greenAccent, fontSize: 10, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          ),
                        if (map.isError)
                          Text(loc.downloadErrorTapToResumeMessage, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                        if (isInterrupted)
                          Text(loc.downloadInterruptedTapToResumeMessage, style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
                      ],
                    ),
                    onTap: () {
                      if ((map.isError || isInterrupted) && !map.isDownloading) {
                        OfflineMapDownloadService(isarService: isar).download(
                            map,
                            headers: const {'User-Agent': 'Meshiker/1.0'});
                        return;
                      }
                      if (map.isDownloading) return;
                      _showMapDetailsDialog(context, isar, map);
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  void _showMapDetailsDialog(BuildContext context, IsarService isar, OfflineMap map) {
    final loc = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.grey[900],
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        map.name,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.pop(dialogContext),
                      tooltip: loc.closeTooltip,
                    ),
                  ],
                ),
                if (map.description != null && map.description!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    map.description!,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () async {
                      await OfflineMapDownloadService(isarService: isar)
                          .deleteFiles(map.localUuid);
                      await isar.deleteOfflineMap(map.id);
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                    },
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                    label: Text(loc.deleteButtonLabel, style: const TextStyle(color: Colors.redAccent)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
