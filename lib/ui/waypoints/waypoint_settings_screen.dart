import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../database/isar_service.dart';
import '../../models/waypoint.dart';
import '../../utils/settings_service.dart';
import '../../utils/waypoint_icons.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'waypoint_announcement_settings_section.dart';

const _kWaypointIconNames = [
  'water_drop', 'home', 'tent', 'terrain', 'landscape', 'camera', 'warning', 'info',
  'camping', 'hotel', 'restaurant', 'grocery', 'bakery', 'snack', 'train', 'hospital', 'police',
];

class WaypointSettingsScreen extends StatefulWidget {
  const WaypointSettingsScreen({super.key});

  @override
  State<WaypointSettingsScreen> createState() => _WaypointSettingsScreenState();
}

class _WaypointSettingsScreenState extends State<WaypointSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final isar = context.watch<IsarService>();
    final settings = context.watch<SettingsService>();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Waypoint Settings'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      // CustomScrollView (plutôt qu'un Column fixe) : la section "ANNONCES
      // VOCALES" rend le contenu au-dessus de la liste des types trop haut
      // pour tenir sans défilement sur les petits écrans (bottom overflow).
      // La ReorderableListView est intégrée en shrinkWrap dans un sliver
      // plutôt que dans son propre Expanded, pour que tout défile ensemble.
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.all(16),
              color: Colors.white.withValues(alpha: 0.05),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('OPTIONS D\'AFFICHAGE', style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    title: const Text('Afficher les waypoints GPX', style: TextStyle(color: Colors.white, fontSize: 14)),
                    subtitle: const Text('Désactivez pour ne voir que les waypoints indépendants', style: TextStyle(color: Colors.white38, fontSize: 12)),
                    value: settings.showGpxWaypoints,
                    activeThumbColor: Colors.greenAccent,
                    onChanged: (v) => settings.setShowGpxWaypoints(v),
                  ),
                  SwitchListTile(
                    title: const Text('Afficher tous les waypoints sans dossiers', style: TextStyle(color: Colors.white, fontSize: 14)),
                    subtitle: const Text('Liste à plat de tous les waypoints, y compris ceux rangés dans un dossier', style: TextStyle(color: Colors.white38, fontSize: 12)),
                    value: settings.flattenWaypointFolders,
                    activeThumbColor: Colors.greenAccent,
                    onChanged: (v) => settings.setFlattenWaypointFolders(v),
                  ),
                  SwitchListTile(
                    title: const Text('Icônes personnalisées par type', style: TextStyle(color: Colors.white, fontSize: 14)),
                    subtitle: const Text(
                      "Afficher l'icône du type de waypoint sur la carte plutôt qu'un repère générique",
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                    value: settings.useWaypointCategoryIcons,
                    activeThumbColor: Colors.greenAccent,
                    onChanged: (v) => settings.setUseWaypointCategoryIcons(v),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: WaypointAnnouncementSettingsSection(
              enabled: settings.waypointAnnouncementsEnabled,
              onEnabledChanged: (v) => settings.setWaypointAnnouncementsEnabled(v),
              onApproach: settings.waypointAnnounceOnApproach,
              onApproachChanged: (v) => settings.setWaypointAnnounceTrigger('approach', v),
              onSpot: settings.waypointAnnounceOnSpot,
              onSpotChanged: (v) => settings.setWaypointAnnounceTrigger('onSpot', v),
              approachDistanceMeters: settings.waypointAnnounceDistanceMeters,
              onApproachDistanceChanged: (v) => settings.setWaypointAnnounceDistanceMeters(v),
              announceTitle: settings.waypointAnnounceTitle,
              onAnnounceTitleChanged: (v) => settings.setWaypointAnnounceContent('title', v),
              announceType: settings.waypointAnnounceType,
              onAnnounceTypeChanged: (v) => settings.setWaypointAnnounceContent('type', v),
              announceDescription: settings.waypointAnnounceDescription,
              onAnnounceDescriptionChanged: (v) => settings.setWaypointAnnounceContent('description', v),
            ),
          ),
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('GESTION DES TYPES', style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: FutureBuilder<List<WaypointCategory>>(
              future: isar.allCategories(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final categories = snapshot.data!;

                return ReorderableListView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  onReorder: (oldIndex, newIndex) async {
                    if (newIndex > categories.length) newIndex = categories.length;
                    setState(() {
                      if (newIndex > oldIndex) newIndex -= 1;
                      final item = categories.removeAt(oldIndex);
                      categories.insert(newIndex, item);
                    });

                    await isar.isar.writeTxn(() async {
                      for (int i = 0; i < categories.length; i++) {
                        categories[i].updatedAt = DateTime.now().add(Duration(milliseconds: i));
                        await isar.isar.waypointCategorys.put(categories[i]);
                      }
                    });
                  },
                  children: [
                    for (int i = 0; i < categories.length; i++)
                      ListTile(
                        key: ValueKey(categories[i].id),
                        leading: CircleAvatar(
                          backgroundColor: Color(categories[i].colorHex).withValues(alpha: 0.2),
                          child: Icon(iconForWaypointCategory(categories[i].iconName), color: Color(categories[i].colorHex), size: 20),
                        ),
                        title: Text(categories[i].name, style: const TextStyle(color: Colors.white)),
                        trailing: ReorderableDragStartListener(
                          index: i,
                          child: const Icon(Icons.drag_handle, color: Colors.white24),
                        ),
                        onTap: () => _editCategory(categories[i]),
                      ),
                    ListTile(
                      key: const ValueKey('new_waypoint_type'),
                      leading: CircleAvatar(
                        backgroundColor: Colors.greenAccent.withValues(alpha: 0.2),
                        child: const Icon(Icons.add, color: Colors.greenAccent, size: 20),
                      ),
                      title: const Text('Nouveau type', style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                      onTap: () => _editCategory(null),
                    ),
                  ],
                );
              },
            ),
          ),
          // Espace en bas pour que le dernier élément ne soit pas masqué
          // par le FloatingActionButton "+".
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
      ),
    );
  }

  void _confirmDeleteCategory(WaypointCategory category) {
    final isar = context.read<IsarService>();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Supprimer le type', style: TextStyle(color: Colors.white)),
        content: Text(
          'Voulez-vous vraiment supprimer le type "${category.name}" ? Les waypoints associés perdront ce type.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('ANNULER')),
          TextButton(
            onPressed: () async {
              await isar.isar.writeTxn(() => isar.isar.waypointCategorys.delete(category.id));
              if (mounted) {
                setState(() {});
                Navigator.pop(context); // Ferme la confirmation
                Navigator.pop(context); // Ferme la fenêtre d'édition du type
              }
            },
            child: const Text('SUPPRIMER', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  void _editCategory(WaypointCategory? category) {
    final isar = context.read<IsarService>();
    final nameController = TextEditingController(text: category?.name);
    int selectedColor = category?.colorHex ?? Colors.blue.toARGB32();
    String selectedIcon = category?.iconName ?? 'location_on';

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: Colors.grey[900],
          title: Row(
            children: [
              Expanded(
                child: Text(category == null ? 'Nouveau Type' : 'Modifier Type', style: const TextStyle(color: Colors.white)),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white70),
                onPressed: () => Navigator.pop(context),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(labelText: 'Nom', labelStyle: TextStyle(color: Colors.white70)),
                ),
                const SizedBox(height: 20),
                const Text('Icône', style: TextStyle(color: Colors.white70)),
                Wrap(
                  spacing: 10,
                  children: _kWaypointIconNames.map((icon) {
                    return IconButton(
                      icon: Icon(iconForWaypointCategory(icon), color: selectedIcon == icon ? Colors.greenAccent : Colors.white38),
                      onPressed: () => setDialogState(() => selectedIcon = icon),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 20),
                const Text('Couleur', style: TextStyle(color: Colors.white70)),
                ColorPicker(
                  pickerColor: Color(selectedColor),
                  onColorChanged: (color) => setDialogState(() => selectedColor = color.toARGB32()),
                  pickerAreaHeightPercent: 0.5,
                  enableAlpha: false,
                  displayThumbColor: true,
                  paletteType: PaletteType.hsvWithHue,
                  labelTypes: const [],
                ),
              ],
            ),
          ),
          actions: [
            if (category != null)
              TextButton(
                onPressed: () => _confirmDeleteCategory(category),
                child: const Text('SUPPRIMER', style: TextStyle(color: Colors.redAccent)),
              ),
            TextButton(
              onPressed: () async {
                if (nameController.text.isEmpty) return;

                final cat = category ?? WaypointCategory();
                cat.name = nameController.text;
                cat.colorHex = selectedColor;
                cat.iconName = selectedIcon;
                if (category == null) {
                   cat.localUuid = DateTime.now().millisecondsSinceEpoch.toString();
                }

                await isar.isar.writeTxn(() => isar.isar.waypointCategorys.put(cat));
                if (mounted) {
                  setState(() {});
                  Navigator.pop(context);
                }
              },
              child: const Text('ENREGISTRER', style: TextStyle(color: Colors.greenAccent))
            ),
          ],
        ),
      ),
    );
  }
}
