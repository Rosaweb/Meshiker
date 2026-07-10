import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../utils/settings_service.dart';

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
    return Scaffold(
      appBar: AppBar(title: const Text('Mes cartes')),
      body: Consumer<SettingsService>(
        builder: (context, settings, child) {
          return Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text(
                  'Sélectionnez jusqu\'à 3 cartes favorites. L\'ordre détermine la priorité du bouton MAP.',
                  style: TextStyle(color: Colors.grey),
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
                      title: Text(source.name),
                      subtitle: Text(source.description),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isSelected)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.green,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                'Priorité ${favIndex + 1}',
                                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
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
      ),
    );
  }
}
