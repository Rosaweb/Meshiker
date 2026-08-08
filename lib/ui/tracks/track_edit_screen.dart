import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../../database/isar_service.dart';
import '../../gpx/gpx_models.dart';
import '../../models/offline_map/offline_map.dart';
import '../../models/trace.dart';
import '../../recording/recording_service.dart';
import '../../search/local_search_engine.dart';
import '../../utils/offline_map_download_service.dart';
import '../../utils/settings_service.dart';
import '../settings/maps_settings_screen.dart';
import '../waypoints/waypoint_manager_screen.dart';
import 'elevation_chart_painter.dart';
import 'elevation_profile_data.dart';
import 'roadmap_screen.dart';
import 'trace_elevation_profile_screen.dart';
import 'trace_map_preview.dart';
import 'trace_share_screen.dart';

enum _TraceMenuAction { navigate, waypoints, share, offlineMap, color, move, delete }

class TrackEditScreen extends StatefulWidget {
  final Trace trace;

  const TrackEditScreen({super.key, required this.trace});

  @override
  State<TrackEditScreen> createState() => _TrackEditScreenState();
}

class _TrackEditScreenState extends State<TrackEditScreen> {
  late TextEditingController _nameController;
  late TextEditingController _descController;
  late Color _currentColor;
  late final Future<List<GpxTrackPoint>> _pointsFuture;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.trace.name);
    _descController = TextEditingController(text: widget.trace.description ?? '');
    _currentColor = widget.trace.colorHex != null ? Color(widget.trace.colorHex!) : Colors.greenAccent;
    _pointsFuture = context.read<IsarService>().getTraceTrackPoints(widget.trace);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final isar = context.read<IsarService>();
    final oldName = widget.trace.name;
    final newName = _nameController.text.trim();
    widget.trace.name = newName;
    widget.trace.description = _descController.text.trim().isEmpty ? null : _descController.text.trim();
    widget.trace.colorHex = _currentColor.toARGB32();

    await isar.saveTrace(widget.trace);
    final renamedWaypoints = await isar.renameTraceWaypoints(oldName, newName);
    if (mounted) {
      final searchEngine = context.read<LocalSearchEngine>();
      for (final w in renamedWaypoints) {
        searchEngine.indexWaypoint(w);
      }
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final dist = settings.unitSystem == UnitSystem.metric
        ? '${(widget.trace.totalDistanceMeters / 1000).toStringAsFixed(1)} km'
        : '${(widget.trace.totalDistanceMeters * 0.000621371).toStringAsFixed(1)} mi';

    return Scaffold(
      backgroundColor: Colors.grey[900],
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TraceMapPreview(trace: widget.trace),
                    const SizedBox(height: 24),
                    _buildInfoCard(dist),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _descController,
                      maxLines: 3,
                      style: const TextStyle(color: Colors.white70),
                      decoration: InputDecoration(
                        hintText: 'Description (optionnel)',
                        hintStyle: const TextStyle(color: Colors.white24),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.05),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 24),
                    _buildElevationPreview(),
                  ],
                ),
              ),
            ),
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
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.blueAccent.withValues(alpha: 0.8), Colors.blue.withValues(alpha: 0.8)],
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.black87),
            onPressed: () => Navigator.pop(context),
            visualDensity: VisualDensity.compact,
          ),
          CircleAvatar(
            radius: 20,
            backgroundColor: Colors.white.withValues(alpha: 0.2),
            child: Icon(Icons.route, color: _currentColor, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: TextFormField(
              controller: _nameController,
              style: const TextStyle(color: Colors.black, fontSize: 18, fontWeight: FontWeight.bold),
              decoration: const InputDecoration(
                hintText: 'Nom de la trace',
                hintStyle: TextStyle(color: Colors.black26),
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
          PopupMenuButton<_TraceMenuAction>(
            icon: const Icon(Icons.more_vert, color: Colors.black87),
            color: Colors.grey[900],
            onSelected: _onMenuAction,
            itemBuilder: (context) => [
              _menuItem(_TraceMenuAction.navigate, Icons.navigation, 'Naviguer', color: Colors.greenAccent),
              _menuItem(_TraceMenuAction.waypoints, Icons.location_on_outlined, 'Voir les waypoints'),
              _menuItem(_TraceMenuAction.share, Icons.qr_code, 'Partager la trace'),
              _menuItem(_TraceMenuAction.offlineMap, Icons.download_for_offline_outlined, 'Créer carte hors-ligne'),
              const PopupMenuDivider(),
              _menuItem(_TraceMenuAction.color, Icons.palette_outlined, 'Couleur de la trace'),
              _menuItem(_TraceMenuAction.move, Icons.drive_file_move_outline, 'Déplacer'),
              _menuItem(_TraceMenuAction.delete, Icons.delete_outline, 'Supprimer', color: Colors.redAccent),
            ],
          ),
        ],
      ),
    );
  }

  PopupMenuItem<_TraceMenuAction> _menuItem(
    _TraceMenuAction action,
    IconData icon,
    String label, {
    bool enabled = true,
    Color? color,
  }) {
    final effectiveColor = enabled ? (color ?? Colors.white) : Colors.white24;
    return PopupMenuItem(
      value: action,
      enabled: enabled,
      child: Row(
        children: [
          Icon(icon, color: effectiveColor, size: 18),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: effectiveColor)),
        ],
      ),
    );
  }

  void _onMenuAction(_TraceMenuAction action) {
    switch (action) {
      case _TraceMenuAction.navigate:
        _navigate();
        break;
      case _TraceMenuAction.waypoints:
        _viewWaypoints();
        break;
      case _TraceMenuAction.share:
        _shareTrace();
        break;
      case _TraceMenuAction.offlineMap:
        _createOfflineMap();
        break;
      case _TraceMenuAction.color:
        _showColorPicker();
        break;
      case _TraceMenuAction.move:
        _moveSourceFile();
        break;
      case _TraceMenuAction.delete:
        _confirmDelete();
        break;
    }
  }

  Future<void> _navigate() async {
    final settings = context.read<SettingsService>();
    final recording = context.read<RecordingService>();
    // On repart sur une destination par défaut (fin de la trace) plutôt que
    // de garder une éventuelle sélection manuelle faite lors d'une
    // précédente navigation sur une autre trace.
    await settings.setNavigationWaypoint(null);
    await recording.setDestination(null);
    await settings.setRoadmapTraceName(widget.trace.name);
    if (!settings.activeGpxNames.contains(widget.trace.name)) {
      await settings.toggleActiveGpx(widget.trace.name);
    }
    if (!mounted) return;
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const RoadmapScreen()),
    );
  }

  void _viewWaypoints() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => WaypointManagerScreen(filterGpxName: widget.trace.name)),
    );
  }

  void _shareTrace() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TraceShareScreen(trace: widget.trace)),
    );
  }

  /// Calcule le plus petit quadrilatère (bounding box) contenant
  /// intégralement la trace, télécharge les tuiles correspondantes et
  /// enregistre le résultat dans "Mes cartes > Hors ligne" sous le même nom
  /// que la trace. La carte créée est liée à la trace (OfflineMap.
  /// linkedTraceName) pour que la retrouver dans la liste rouvre
  /// directement le Roadmap de cette trace (cf. _OfflineMapsTab).
  Future<void> _createOfflineMap() async {
    final isar = context.read<IsarService>();
    final settings = context.read<SettingsService>();
    final messenger = ScaffoldMessenger.of(context);

    final polyline = await isar.getTracePolyline(widget.trace);
    if (polyline.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Cette trace ne contient aucun point.')),
      );
      return;
    }

    var minLat = polyline.first.lat, maxLat = polyline.first.lat;
    var minLon = polyline.first.lon, maxLon = polyline.first.lon;
    for (final point in polyline) {
      if (point.lat < minLat) minLat = point.lat;
      if (point.lat > maxLat) maxLat = point.lat;
      if (point.lon < minLon) minLon = point.lon;
      if (point.lon > maxLon) maxLon = point.lon;
    }

    // Même fond de carte que celui affiché à l'écran, mêmes bornes de zoom
    // que celles proposées par défaut pour une création manuelle (cf.
    // SettingsService.startMapCreation).
    final favIds = settings.favoriteMapIds;
    final sourceId = favIds.isNotEmpty
        ? favIds[settings.currentMapIndex % favIds.length]
        : 'osm_standard';
    final source = availableSources.firstWhere((s) => s.id == sourceId,
        orElse: () => availableSources.first);

    final map = OfflineMap()
      ..localUuid = const Uuid().v4()
      ..name = widget.trace.name
      ..minLat = minLat
      ..maxLat = maxLat
      ..minLon = minLon
      ..maxLon = maxLon
      ..minZoom = 10
      ..maxZoom = 15
      ..sourceId = source.id
      ..urlTemplate = source.url
      ..linkedTraceName = widget.trace.name
      ..isDownloading = true
      ..downloadProgress = 0.0;

    await isar.saveOfflineMap(map);
    if (!mounted) return;
    Navigator.pop(context);

    messenger.showSnackBar(
      SnackBar(
        content: Text('Téléchargement de la carte "${map.name}" démarré',
            textAlign: TextAlign.center),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );

    unawaited(OfflineMapDownloadService(isarService: isar)
        .download(map, headers: const {'User-Agent': 'Meshiker/1.0'}));
  }

  Future<void> _moveSourceFile() async {
    final sourcePath = widget.trace.sourceFilePath;
    if (sourcePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cette trace n\'a pas de fichier source associé.')),
      );
      return;
    }

    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Fichier source introuvable sur le disque.')),
        );
      }
      return;
    }

    final destDir = await FilePicker.platform.getDirectoryPath();
    if (destDir == null || !mounted) return;

    if (p.canonicalize(p.dirname(sourcePath)) == p.canonicalize(destDir)) {
      return;
    }

    final newPath = p.join(destDir, p.basename(sourcePath));
    try {
      await sourceFile.rename(newPath);
    } on FileSystemException {
      // rename() échoue entre systèmes de fichiers différents (ex. carte SD) :
      // on retente en copiant puis en supprimant l'original.
      await sourceFile.copy(newPath);
      await sourceFile.delete();
    }

    if (!mounted) return;
    final isar = context.read<IsarService>();
    widget.trace.sourceFilePath = newPath;
    await isar.saveTrace(widget.trace);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fichier déplacé.')),
      );
    }
  }

  void _confirmDelete() {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Supprimer la trace', style: TextStyle(color: Colors.white)),
        content: Text(
          'Voulez-vous vraiment supprimer "${widget.trace.name}" ? Le fichier source sera aussi supprimé du stockage de l\'appareil. Cette action est irréversible.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('ANNULER'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await _deleteTrace();
            },
            child: const Text('SUPPRIMER', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteTrace() async {
    final isar = context.read<IsarService>();
    final searchEngine = context.read<LocalSearchEngine>();

    final sourcePath = widget.trace.sourceFilePath;
    if (sourcePath != null) {
      final file = File(sourcePath);
      if (await file.exists()) {
        await file.delete();
      }
    }

    await isar.isar.writeTxn(() => isar.isar.traces.delete(widget.trace.id));
    searchEngine.removeTrace(widget.trace.localUuid);

    if (mounted) Navigator.pop(context);
  }

  Widget _buildInfoCard(String dist) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _infoStat('Distance', dist),
          _infoStat('Dénivelé +', '${widget.trace.totalElevationGainMeters.round()}m'),
          _infoStat('Dénivelé -', '${widget.trace.totalElevationLossMeters.round()}m'),
        ],
      ),
    );
  }

  Widget _infoStat(String label, String value) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 10)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
      ],
    );
  }

  Widget _buildElevationPreview() {
    return FutureBuilder<List<GpxTrackPoint>>(
      future: _pointsFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox(
            height: 140,
            child: Center(
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.greenAccent),
            ),
          );
        }

        final points = snapshot.data!;
        if (points.isEmpty || points.every((p) => p.elevation == null)) {
          return Container(
            height: 140,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              'Aucune donnée d\'altitude disponible.',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          );
        }

        final series = ElevationSeries.fromPoints(points);
        final settings = context.watch<SettingsService>();

        return GestureDetector(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TraceElevationProfileScreen(trace: widget.trace, points: points),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              height: 140,
              width: double.infinity,
              child: CustomPaint(
                painter: ElevationChartPainter(
                  distancesM: series.distancesM,
                  elevations: series.elevations,
                  minEle: series.minEle,
                  maxEle: series.maxEle,
                  windowStartM: 0,
                  windowWidthM: series.totalDistanceM > 0 ? series.totalDistanceM : 1,
                  highlightIndex: null,
                  unitSystem: settings.unitSystem,
                  lineColor: Colors.greenAccent,
                  fillColor: Colors.greenAccent.withValues(alpha: 0.15),
                  gridColor: Colors.white12,
                  textColor: Colors.white38,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showColorPicker() {
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
}
