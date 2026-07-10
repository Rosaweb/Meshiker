import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../../database/isar_service.dart';
import '../../models/waypoint.dart';

class WaypointEditScreen extends StatefulWidget {
  final Waypoint? waypoint;
  final double? latitude;
  final double? longitude;
  final IsarService isarService;

  const WaypointEditScreen({
    super.key,
    this.waypoint,
    this.latitude,
    this.longitude,
    required this.isarService,
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
    _associatedGpx = widget.waypoint?.associatedGpxName;
    
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
    wp.colorHex = _currentColor.value;
    wp.photoPaths = _photoPaths;
    wp.headerPhotoIndex = _headerPhotoIndex;
    wp.associatedGpxName = _associatedGpx;
    wp.category.value = _selectedCategory;

    await widget.isarService.saveWaypoint(wp);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    // We wrap the content in a Material and Container to look like a centered card
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
            // HEADER IMAGE / COLOR
            _buildHeader(),
            
            // FORM
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFormField(
                        controller: _nameController,
                        style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                        decoration: const InputDecoration(
                          hintText: 'Nom du point',
                          hintStyle: TextStyle(color: Colors.white24),
                          border: InputBorder.none,
                        ),
                        validator: (v) => (v == null || v.isEmpty) ? 'Requis' : null,
                      ),
                      const Divider(color: Colors.white10),
                      DropdownButton<WaypointCategory>(
                        isExpanded: true,
                        dropdownColor: Colors.grey[850],
                        value: _selectedCategory,
                        hint: const Text('Sélectionner un type', style: TextStyle(color: Colors.white38)),
                        items: _categories.map((c) => DropdownMenuItem(
                          value: c, 
                          child: Row(
                            children: [
                              Icon(_getIcon(c.iconName), color: Colors.greenAccent, size: 18),
                              const SizedBox(width: 12),
                              Text(c.name, style: const TextStyle(color: Colors.white)),
                            ],
                          )
                        )).toList(),
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
                          fillColor: Colors.white.withOpacity(0.05),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text('PHOTOS', style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      _buildPhotoGrid(),
                    ],
                  ),
                ),
              ),
            ),
            
            // ACTIONS
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('ANNULER', style: TextStyle(color: Colors.white54)),
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
      height: 140,
      width: double.infinity,
      color: _currentColor.withOpacity(0.2),
      child: Stack(
        children: [
          if (_photoPaths.isNotEmpty)
            Image.file(File(_photoPaths[_headerPhotoIndex]), width: double.infinity, height: 140, fit: BoxFit.cover),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black.withOpacity(0.7)],
              ),
            ),
          ),
          Positioned(
            right: 12,
            bottom: 12,
            child: Row(
              children: [
                _RoundAction(icon: Icons.palette, onTap: _pickColor),
                const SizedBox(width: 8),
                _RoundAction(icon: Icons.add_a_photo, onTap: _pickImage),
              ],
            ),
          ),
          Positioned(
            left: 16,
            top: 16,
            child: CircleAvatar(
              backgroundColor: _currentColor,
              child: const Icon(Icons.location_on, color: Colors.white),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildPhotoGrid() {
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

  IconData _getIcon(String iconName) {
    switch (iconName) {
      case 'water_drop': return Icons.water_drop;
      case 'home': return Icons.home;
      case 'tent': return Icons.terrain;
      case 'terrain': return Icons.terrain;
      default: return Icons.location_on;
    }
  }
}

class _RoundAction extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _RoundAction({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withOpacity(0.5), border: Border.all(color: Colors.white24)),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}
