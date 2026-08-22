import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../database/isar_service.dart';
import '../../map/map_view_model.dart';
import '../../models/waypoint.dart';
import '../../search/local_search_engine.dart';
import '../../utils/overpass_service.dart';
import '../../utils/settings_service.dart';

/// Fenêtre contextuelle légère affichée au clic sur un POI OSM non
/// sauvegardé : nom, adresse, téléphone, horaires, et un bouton unique
/// "Sauvegarder". Volontairement distincte de WaypointEditScreen -- une
/// étape de trop pour quelqu'un qui veut juste repérer un commerce sur son
/// itinéraire.
class OsmPoiDetailSheet extends StatelessWidget {
  final OsmPoi poi;
  final IsarService isarService;

  const OsmPoiDetailSheet({super.key, required this.poi, required this.isarService});

  String? get _address {
    final parts = [
      poi.tags['addr:housenumber'],
      poi.tags['addr:street'],
      poi.tags['addr:postcode'],
      poi.tags['addr:city'],
    ].where((p) => p != null && p.isNotEmpty).toList();
    return parts.isEmpty ? null : parts.join(' ');
  }

  String? get _phone => poi.tags['contact:phone'] ?? poi.tags['phone'];
  String? get _hours => poi.tags['opening_hours'];

  Future<void> _save(BuildContext context) async {
    final settings = context.read<SettingsService>();
    final category = await isarService.resolveOrCreateCategoryForOsmType(poi.categoryId);

    final wp = Waypoint()
      ..localUuid = const Uuid().v4()
      ..name = poi.name
      ..latitude = poi.location.latitude
      ..longitude = poi.location.longitude
      ..osmNodeId = poi.id
      // Rattachement conditionnel : si une trace est chargée dans le
      // Roadmap (menu "Naviguer" d'une trace), le waypoint est rattaché à
      // son fichier ; sinon il reste indépendant.
      ..associatedGpxName = settings.roadmapTraceName
      // Couleur de la catégorie posée dès la sauvegarde : différenciation
      // visuelle immédiate même si le réglage "icônes par type" reste
      // désactivé, puisque la couleur du marqueur n'en dépend pas.
      ..colorHex = category.colorHex
      ..description = [
        'Nom : ${poi.name}',
        if (_address != null) 'Adresse : $_address',
        if (_phone != null) 'Téléphone : $_phone',
      ].join('\n');
    wp.category.value = category;

    await isarService.saveWaypoint(wp);
    if (context.mounted) {
      context.read<LocalSearchEngine>().indexWaypoint(wp);
      context.read<MapViewModel>().refreshNow();
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.grey[900],
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(poi.name, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text(_address ?? 'Adresse non renseignée', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            if (_phone != null)
              InkWell(
                onTap: () => launchUrl(Uri(scheme: 'tel', path: _phone)),
                child: Text(_phone!,
                    style: const TextStyle(color: Colors.greenAccent, decoration: TextDecoration.underline)),
              )
            else
              const Text('Téléphone non renseigné', style: TextStyle(color: Colors.white38)),
            const SizedBox(height: 8),
            Text(_hours ?? 'Horaires non renseignés', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => _save(context),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.greenAccent),
                child: const Text('SAUVEGARDER', style: TextStyle(color: Colors.black)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
