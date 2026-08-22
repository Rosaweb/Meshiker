import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:isar_community/isar.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../../database/isar_service.dart';
import '../../map/map_view_model.dart';
import '../../models/waypoint.dart';
import '../../search/local_search_engine.dart';
import '../../utils/settings_service.dart';
import '../../utils/waypoint_icons.dart';

class WaypointEditScreen extends StatefulWidget {
  final Waypoint? waypoint;
  final double? latitude;
  final double? longitude;
  final IsarService isarService;
  /// Écran d'où cette fenêtre contextuelle a été ouverte (carte, Track
  /// Manager, Roadmap). Transmis à "Localiser sur la carte" pour que le
  /// bouton "Retour" de la carte sache où rouvrir cette fiche.
  final WaypointLocateOrigin locateOrigin;
  /// Nom de la trace GPX à laquelle rattacher un waypoint NOUVELLEMENT
  /// créé (voir [SettingsService.roadmapTraceName]), pour qu'il apparaisse
  /// dans le Roadmap de cette trace sans attendre un nouveau scan GPX.
  /// Ignoré si [waypoint] est déjà renseigné (édition).
  final String? associatedGpxName;

  const WaypointEditScreen({
    super.key,
    this.waypoint,
    this.latitude,
    this.longitude,
    required this.isarService,
    this.locateOrigin = WaypointLocateOrigin.map,
    this.associatedGpxName,
  });

  @override
  State<WaypointEditScreen> createState() => _WaypointEditScreenState();
}

class _WaypointEditScreenState extends State<WaypointEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _descController;
  
  Color _currentColor = Colors.green;
  WaypointCategory? _selectedCategory;
  List<WaypointCategory> _categories = [];
  List<String> _photoPaths = [];
  int _headerPhotoIndex = 0;
  String? _associatedGpx;

  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.waypoint?.name ?? '');
    _descController = TextEditingController(text: widget.waypoint?.description ?? '');
    _currentColor = widget.waypoint?.colorHex != null ? Color(widget.waypoint!.colorHex!) : Colors.green;
    _photoPaths = widget.waypoint?.photoPaths != null ? List.from(widget.waypoint!.photoPaths) : [];
    _headerPhotoIndex = widget.waypoint?.headerPhotoIndex ?? 0;
    _associatedGpx = widget.waypoint?.associatedGpxName ?? widget.associatedGpxName;
    
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    final cats = await widget.isarService.allCategories();
    setState(() {
      _categories = cats;
      if (widget.waypoint != null) {
        _selectedCategory = cats.where((c) => c.id == widget.waypoint!.category.value?.id).firstOrNull;
      }
    });
  }

  Future<void> _pickImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.camera);
    if (image != null) {
      setState(() {
        _photoPaths.add(image.path);
      });
    }
  }

  void _pickColor() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Choisir une couleur', style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: BlockPicker(
            pickerColor: _currentColor,
            onColorChanged: (color) {
              setState(() => _currentColor = color);
              Navigator.of(context).pop();
            },
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final wp = widget.waypoint ?? Waypoint()
      ..localUuid = const Uuid().v4()
      ..latitude = widget.latitude ?? 0
      ..longitude = widget.longitude ?? 0;

    wp.name = _nameController.text;
    wp.description = _descController.text;
    wp.colorHex = _currentColor.toARGB32();
    wp.photoPaths = _photoPaths;
    wp.headerPhotoIndex = _headerPhotoIndex;
    wp.associatedGpxName = _associatedGpx;
    wp.category.value = _selectedCategory;

    await widget.isarService.saveWaypoint(wp);
    if (mounted) {
      context.read<LocalSearchEngine>().indexWaypoint(wp);
      Navigator.pop(context);
    }
  }

  /// Un waypoint est "nouveau" tant qu'il n'a jamais été enregistré dans
  /// Isar (création par appui long sur la carte, ou pré-rempli depuis un
  /// POI OSM) : dans ce cas on propose ANNULER. Dès qu'il s'agit d'un
  /// waypoint déjà persisté (édité depuis le Waypoint Manager ou depuis un
  /// marqueur existant sur la carte), ANNULER n'a pas de sens et on
  /// propose SUPPRIMER à la place.
  bool get _isNew => widget.waypoint == null || widget.waypoint!.id == Isar.autoIncrement;

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Supprimer', style: TextStyle(color: Colors.white)),
        content: const Text('Voulez-vous vraiment supprimer ce waypoint ?',
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('ANNULER'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('SUPPRIMER', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed == true && widget.waypoint != null) {
      await widget.isarService.deleteWaypoints([widget.waypoint!.id]);
      if (mounted) Navigator.pop(context);
    }
  }

  /// Ferme la fenêtre contextuelle et centre l'écran principal (carte) sur
  /// ce waypoint. Un bouton "Retour" flottant s'affiche sur la carte pour
  /// revenir ici ; disponible uniquement pour un waypoint déjà enregistré
  /// (un waypoint en cours de création n'a pas d'existence persistée à
  /// laquelle revenir).
  void _locateOnMap() {
    final wp = widget.waypoint;
    if (wp == null) return;
    context.read<SettingsService>().startLocateWaypoint(
        wp.localUuid,
        origin: widget.locateOrigin);
    context.read<MapViewModel>().centerRequest.value =
        (lat: wp.latitude, lon: wp.longitude);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DropdownButtonFormField<WaypointCategory>(
                        isExpanded: true,
                        dropdownColor: Colors.grey[850],
                        initialValue: _selectedCategory,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Sélectionner un type',
                          hintStyle: const TextStyle(color: Colors.white38),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.05),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                        ),
                        items: [
                          const DropdownMenuItem<WaypointCategory>(
                            value: null,
                            child: Row(
                              children: [
                                Icon(Icons.block, color: Colors.white38, size: 18),
                                SizedBox(width: 12),
                                Text('Aucun', style: TextStyle(color: Colors.white38)),
                              ],
                            ),
                          ),
                          ..._categories.map((c) => DropdownMenuItem(
                            value: c,
                            child: Row(
                              children: [
                                Icon(iconForWaypointCategory(c.iconName), color: Colors.greenAccent, size: 18),
                                const SizedBox(width: 12),
                                Text(c.name),
                              ],
                            )
                          )),
                        ],
                        onChanged: (v) => setState(() => _selectedCategory = v),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _descController,
                        maxLines: 3,
                        style: const TextStyle(color: Colors.white70),
                        decoration: InputDecoration(
                          hintText: 'Description (facultatif)',
                          hintStyle: const TextStyle(color: Colors.white24),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.05),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          const Text('COULEUR DU POINT', style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.bold)),
                          const Spacer(),
                          GestureDetector(
                            onTap: _pickColor,
                            child: Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: _currentColor,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: Colors.white24),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (!_isNew) ...[
                        const SizedBox(height: 16),
                        InkWell(
                          onTap: _locateOnMap,
                          child: const Row(
                            children: [
                              Icon(Icons.location_searching, color: Colors.greenAccent, size: 18),
                              SizedBox(width: 12),
                              Expanded(
                                child: Text('Localiser sur la carte', style: TextStyle(color: Colors.white)),
                              ),
                              Icon(Icons.chevron_right, color: Colors.white24),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          const Text('PHOTOS', style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.bold)),
                          const Spacer(),
                          IconButton(
                            onPressed: _pickImage,
                            icon: const Icon(Icons.add_a_photo, color: Colors.greenAccent, size: 20),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _buildPhotoGrid(),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_isNew)
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('ANNULER', style: TextStyle(color: Colors.white54)),
                    )
                  else
                    TextButton(
                      onPressed: _confirmDelete,
                      child: const Text('SUPPRIMER', style: TextStyle(color: Colors.redAccent)),
                    ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.greenAccent,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('ENREGISTRER', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.greenAccent.withValues(alpha: 0.8), Colors.green.withValues(alpha: 0.8)],
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: Colors.white.withValues(alpha: 0.2),
            child: Icon(Icons.location_on, color: _currentColor, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: TextFormField(
              controller: _nameController,
              style: const TextStyle(color: Colors.black, fontSize: 18, fontWeight: FontWeight.bold),
              decoration: const InputDecoration(
                hintText: 'Nom du point',
                hintStyle: TextStyle(color: Colors.black26),
                border: InputBorder.none,
                isDense: true,
              ),
              validator: (v) => (v == null || v.isEmpty) ? 'Requis' : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoGrid() {
    if (_photoPaths.isEmpty) {
      return const Text('Aucune photo', style: TextStyle(color: Colors.white12, fontSize: 12));
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (int i = 0; i < _photoPaths.length; i++)
          GestureDetector(
            onTap: () => setState(() => _headerPhotoIndex = i),
            child: Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _headerPhotoIndex == i ? Colors.greenAccent : Colors.transparent, width: 2),
                image: DecorationImage(image: FileImage(File(_photoPaths[i])), fit: BoxFit.cover),
              ),
            ),
          ),
      ],
    );
  }
}
