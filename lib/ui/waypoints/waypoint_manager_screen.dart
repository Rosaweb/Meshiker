import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../database/isar_service.dart';
import '../../map/map_view_model.dart';
import '../../models/waypoint.dart';
import '../../utils/settings_service.dart';
import '../../recording/recording_service.dart';
import 'waypoint_edit_screen.dart';
import 'waypoint_settings_screen.dart';

class WaypointManagerScreen extends StatefulWidget {
  final bool isSelectionMode; 
  final String? filterGpxName;
  final bool isTransparent;

  const WaypointManagerScreen({
    super.key,
    this.isSelectionMode = false,
    this.filterGpxName,
    this.isTransparent = false,
  });

  @override
  State<WaypointManagerScreen> createState() => _WaypointManagerScreenState();
}

class _WaypointManagerScreenState extends State<WaypointManagerScreen> {
  String _searchQuery = '';
  WaypointCategory? _typeFilter;
  bool _sortByDistance = false;
  List<WaypointCategory> _allCategories = [];
  
  final Set<int> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    final isar = context.read<IsarService>();
    final cats = await isar.allCategories();
    if (mounted) setState(() => _allCategories = cats);
  }

  bool get _isMultiSelectMode => _selectedIds.isNotEmpty;

  void _toggleSelection(int id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isar = context.watch<IsarService>();
    final settings = context.watch<SettingsService>();

    return Scaffold(
      backgroundColor: widget.isTransparent ? Colors.transparent : Colors.black,
      appBar: AppBar(
        title: const Text('Waypoint Manager'),
        backgroundColor: widget.isTransparent ? Colors.transparent : Colors.black,
        foregroundColor: Colors.white,
        leading: _isMultiSelectMode 
          ? IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _selectedIds.clear()),
            )
          : null,
        actions: [
          if (!_isMultiSelectMode) ...[
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WaypointSettingsScreen())),
              tooltip: 'Gérer les types',
            ),
            IconButton(
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: () => _showCreateFolderDialog(isar),
              tooltip: 'Créer un dossier',
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            color: Colors.white.withValues(alpha: 0.05),
            child: _isMultiSelectMode 
              ? _buildSelectionActions(isar) 
              : _buildFilters(),
          ),

          Expanded(
            child: StreamBuilder(
              // On écoute les changements sur les waypoints ET les dossiers
              stream: isar.isar.waypoints.watchLazy(),
              builder: (context, _) {
                return FutureBuilder(
                  future: Future.wait([
                    isar.searchWaypoints(
                      query: _searchQuery,
                      categoryId: _typeFilter?.id,
                      filterGpxName: widget.filterGpxName,
                    ),
                    isar.allFolders(),
                  ]),
                  builder: (context, AsyncSnapshot<List<dynamic>> snapshot) {
                    if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                    
                    final List<Waypoint> waypoints = snapshot.data![0];
                    final List<WaypointFolder> folders = snapshot.data![1];

                    return FutureBuilder(
                      future: _loadLinks(waypoints),
                      builder: (context, _) => _buildDynamicList(waypoints, folders, settings)
                    );
                  },
                );
              }
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _loadLinks(List<Waypoint> list) async {
    for (var w in list) {
      await w.folder.load();
      await w.category.load();
    }
  }

  Widget _buildFilters() {
    return Column(
      children: [
        TextField(
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Rechercher par nom...',
            hintStyle: TextStyle(color: Colors.white38),
            prefixIcon: Icon(Icons.search, color: Colors.white70),
            isDense: true,
            border: InputBorder.none,
          ),
          onChanged: (v) => setState(() => _searchQuery = v),
        ),
        Row(
          children: [
            Expanded(
              child: DropdownButton<WaypointCategory>(
                isExpanded: true,
                hint: const Text('Tous les types', style: TextStyle(color: Colors.white70)),
                value: _typeFilter,
                dropdownColor: Colors.grey[900],
                items: [
                  const DropdownMenuItem(value: null, child: Text('Tous les types', style: TextStyle(color: Colors.white))),
                  ..._allCategories.map((c) => DropdownMenuItem(value: c, child: Text(c.name, style: const TextStyle(color: Colors.white)))),
                ],
                onChanged: (v) => setState(() => _typeFilter = v),
              ),
            ),
            const SizedBox(width: 8),
            FilterChip(
              label: const Text('Proximité', style: TextStyle(fontSize: 12)),
              selected: _sortByDistance,
              onSelected: (v) => setState(() => _sortByDistance = v),
              selectedColor: Colors.greenAccent,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSelectionActions(IsarService isar) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${_selectedIds.length} SÉLECTIONNÉ(S)',
              style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 12),
            ),
            const SizedBox(height: 8),
            const Text('Actions groupées', style: TextStyle(color: Colors.white38, fontSize: 10)),
          ],
        ),
        const VerticalDivider(color: Colors.white10, indent: 20, endIndent: 20),
        _ActionButton(
          icon: Icons.folder_open,
          label: 'DÉPLACER',
          onTap: () => _showMoveDialog(isar),
        ),
        _ActionButton(
          icon: Icons.delete_outline,
          label: 'SUPPRIMER',
          color: Colors.redAccent,
          onTap: () => _confirmDelete(isar),
        ),
      ],
    );
  }

  Widget _buildDynamicList(List<Waypoint> waypoints, List<WaypointFolder> folders, SettingsService settings) {
    if (widget.filterGpxName != null) {
      return _buildFlatList(waypoints, settings);
    }

    final Map<int, List<Waypoint>> customGroups = {};
    final Map<String, List<Waypoint>> gpxGroups = {};
    final List<Waypoint> noFolder = [];

    for (var w in waypoints) {
      if (w.folder.value != null) {
        customGroups.putIfAbsent(w.folder.value!.id, () => []).add(w);
      } else if (w.associatedGpxName != null) {
        if (settings.showGpxWaypoints) {
           gpxGroups.putIfAbsent(w.associatedGpxName!, () => []).add(w);
        }
      } else {
        noFolder.add(w);
      }
    }

    final sortedGpxNames = gpxGroups.keys.toList()..sort();

    return ListView(
      children: [
        // 1. DOSSIERS PERSONNELS (Même si vides)
        for (var folder in folders)
          ExpansionTile(
            initiallyExpanded: false,
            leading: const Icon(Icons.folder, color: Colors.blueAccent, size: 20),
            title: Text(folder.name, style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
            children: (customGroups[folder.id] ?? []).isEmpty 
              ? [const ListTile(title: Text('Dossier vide', style: TextStyle(color: Colors.white24, fontSize: 12)))]
              : customGroups[folder.id]!.map((w) => _WaypointTile(
                  waypoint: w, 
                  isSelected: _selectedIds.contains(w.id),
                  onTap: () => _handleTap(w, settings),
                  onLongPress: () => _toggleSelection(w.id),
                )).toList(),
          ),

        // 2. TRACES GPX
        for (var name in sortedGpxNames)
          ExpansionTile(
            initiallyExpanded: false,
            leading: const Icon(Icons.route, color: Colors.greenAccent, size: 20),
            title: Text(name, style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
            children: gpxGroups[name]!.map((w) => _WaypointTile(
              waypoint: w, 
              isSelected: _selectedIds.contains(w.id),
              onTap: () => _handleTap(w, settings),
              onLongPress: () => _toggleSelection(w.id),
            )).toList(),
          ),
        
        // 3. INDÉPENDANTS
        if (noFolder.isNotEmpty) ...[
          const SizedBox(height: 8),
          ...noFolder.map((w) => _WaypointTile(
            waypoint: w, 
            isSelected: _selectedIds.contains(w.id),
            onTap: () => _handleTap(w, settings),
            onLongPress: () => _toggleSelection(w.id),
          )),
        ],
      ],
    );
  }

  Widget _buildFlatList(List<Waypoint> list, SettingsService settings) {
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (context, index) => _WaypointTile(
        waypoint: list[index], 
        isSelected: _selectedIds.contains(list[index].id),
        onTap: () => _handleTap(list[index], settings),
        onLongPress: () => _toggleSelection(list[index].id),
      ),
    );
  }

  void _handleTap(Waypoint wp, SettingsService settings) {
    if (_isMultiSelectMode) {
      _toggleSelection(wp.id);
    } else if (widget.isSelectionMode) {
      settings.setNavigationWaypoint(wp.localUuid);
      context.read<RecordingService>().setDestination(wp.localUuid);
      Navigator.pop(context);
    } else {
      showDialog(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.7),
        builder: (context) => WaypointEditScreen(
          waypoint: wp,
          isarService: context.read<IsarService>(),
        ),
      ).then((_) {
        if (context.mounted) context.read<MapViewModel>().refreshNow();
      });
    }
  }

  void _confirmDelete(IsarService isar) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Supprimer', style: TextStyle(color: Colors.white)),
        content: Text('Voulez-vous vraiment supprimer ${_selectedIds.length} waypoint(s) ?', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('ANNULER')),
          TextButton(
            onPressed: () async {
              await isar.deleteWaypoints(_selectedIds.toList());
              setState(() => _selectedIds.clear());
              if (mounted) Navigator.pop(context);
            }, 
            child: const Text('SUPPRIMER', style: TextStyle(color: Colors.redAccent))
          ),
        ],
      ),
    );
  }

  void _showMoveDialog(IsarService isar) async {
    final allWps = await isar.allWaypoints();
    final gpxNames = allWps.map((w) => w.associatedGpxName).whereType<String>().toSet().toList()..sort();
    final customFolders = await isar.allFolders();

    if (mounted) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text('Déplacer vers...', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  leading: const Icon(Icons.close, color: Colors.white38),
                  title: const Text('Sortir de tout dossier', style: TextStyle(color: Colors.white)),
                  onTap: () async {
                    await isar.moveWaypointsToGpx(_selectedIds.toList(), null, folderId: null);
                    setState(() => _selectedIds.clear());
                    if (mounted) Navigator.pop(context);
                  },
                ),
                const Divider(color: Colors.white10),
                
                if (customFolders.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text('DOSSIERS PERSONNELS', style: TextStyle(color: Colors.blueAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                  for (var f in customFolders)
                    ListTile(
                      leading: const Icon(Icons.folder, color: Colors.blueAccent, size: 20),
                      title: Text(f.name, style: const TextStyle(color: Colors.white70)),
                      onTap: () async {
                        await isar.moveWaypointsToGpx(_selectedIds.toList(), null, folderId: f.id);
                        setState(() => _selectedIds.clear());
                        if (mounted) Navigator.pop(context);
                      },
                    ),
                  const Divider(color: Colors.white10),
                ],

                if (gpxNames.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text('TRACES GPX', style: TextStyle(color: Colors.greenAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                  for (var name in gpxNames)
                    ListTile(
                      leading: const Icon(Icons.route, color: Colors.greenAccent, size: 20),
                      title: Text(name, style: const TextStyle(color: Colors.white70)),
                      onTap: () async {
                        await isar.moveWaypointsToGpx(_selectedIds.toList(), name, folderId: null);
                        setState(() => _selectedIds.clear());
                        if (mounted) Navigator.pop(context);
                      },
                    ),
                ],
              ],
            ),
          ),
        ),
      );
    }
  }

  void _showCreateFolderDialog(IsarService isar) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Nouveau dossier', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Nom du dossier',
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.greenAccent)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('ANNULER')),
          TextButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                await isar.createWaypointFolder(controller.text);
                if (mounted) Navigator.pop(context);
              }
            }, 
            child: const Text('CRÉER', style: TextStyle(color: Colors.greenAccent))
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

class _WaypointTile extends StatelessWidget {
  final Waypoint waypoint;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _WaypointTile({
    required this.waypoint, 
    required this.isSelected, 
    required this.onTap, 
    required this.onLongPress
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: isSelected ? Colors.blueAccent.withValues(alpha: 0.15) : Colors.transparent,
      child: ListTile(
        leading: Stack(
          alignment: Alignment.center,
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: waypoint.colorHex != null ? Color(waypoint.colorHex!) : Colors.grey,
              child: const Icon(Icons.location_on, color: Colors.white, size: 20),
            ),
            if (isSelected)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.blueAccent.withValues(alpha: 0.8)),
                  child: const Icon(Icons.check, color: Colors.white, size: 20),
                ),
              ),
          ],
        ),
        title: Text(waypoint.name, style: const TextStyle(color: Colors.white)),
        subtitle: Text(waypoint.category.value?.name ?? 'Aucun type', style: const TextStyle(color: Colors.white38)),
        trailing: const Icon(Icons.chevron_right, color: Colors.white24),
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}
