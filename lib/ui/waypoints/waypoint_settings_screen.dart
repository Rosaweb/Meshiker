import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../database/isar_service.dart';
import '../../models/waypoint.dart';
import '../../utils/settings_service.dart';
import '../../utils/waypoint_icons.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

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
      body: Column(
        children: [
          Container(
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
          const Padding(
            padding: EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('GESTION DES TYPES', style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<WaypointCategory>>(
              future: isar.allCategories(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                final categories = snapshot.data!;

                return ReorderableListView(
                  onReorder: (oldIndex, newIndex) async {
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
                    for (final cat in categories)
                      ListTile(
                        key: ValueKey(cat.id),
                        leading: CircleAvatar(
                          backgroundColor: Color(cat.colorHex).withValues(alpha: 0.2),
                          child: Icon(iconForWaypointCategory(cat.iconName), color: Color(cat.colorHex), size: 20),
                        ),
                        title: Text(cat.name, style: const TextStyle(color: Colors.white)),
                        trailing: const Icon(Icons.drag_handle, color: Colors.white24),
                        onTap: () => _editCategory(cat),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _editCategory(null),
        backgroundColor: Colors.greenAccent,
        child: const Icon(Icons.add, color: Colors.black),
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
          title: Text(category == null ? 'Nouveau Type' : 'Modifier Type', style: const TextStyle(color: Colors.white)),
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
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('ANNULER')),
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
