import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:isar_community/isar.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import '../../database/isar_service.dart';
import '../../models/trace.dart';
import '../../models/enums.dart';
import '../../utils/settings_service.dart';
import '../../recording/recording_service.dart';
import 'track_edit_screen.dart';
import 'import_share_screen.dart';
import '../../gpx/gpx_scanner_service.dart';

enum TrackSortOption {
  none,
  proximity,
  alphabetical,
  distAsc,
  distDesc,
  gainPos,
  lossNeg,
  totalElevation
}

class TrackManagerScreen extends StatefulWidget {
  const TrackManagerScreen({super.key});

  @override
  State<TrackManagerScreen> createState() => _TrackManagerScreenState();
}

class _TrackManagerScreenState extends State<TrackManagerScreen> {
  String _searchQuery = '';
  TrackSortOption _sortOption = TrackSortOption.none;
  // Chemin (liste de noms de dossiers) dans lequel l'utilisateur est "entré"
  // via un double-clic, pour n'afficher que le contenu de ce dossier.
  List<String> _drillPath = [];

  Future<void> _refreshFolder() async {
    final scanner = context.read<GpxScannerService>();
    final settings = context.read<SettingsService>();

    if (settings.gpxStoragePath == null || settings.gpxStoragePath!.isEmpty) return;

    try {
      final result = await scanner.scanFolder(settings.gpxStoragePath!);
      if (mounted) _showScanResultIfNeeded(result);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur lors du scan : $e')),
        );
      }
    }
  }

  void _showScanResultIfNeeded(GpxScanResult result) {
    switch (result) {
      case GpxScanResult.ok:
        return;
      case GpxScanResult.directoryNotFound:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Dossier GPX/KML introuvable.')),
        );
      case GpxScanResult.permissionDenied:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Accès au stockage refusé : autorisez "Tous les fichiers" pour Meshiker dans les paramètres Android, puis relancez le scan.'),
            duration: Duration(seconds: 5),
          ),
        );
    }
  }

  List<Trace> _sortTracks(List<Trace> tracks, LatLng? userPos) {
    List<Trace> filtered = tracks;
    if (_searchQuery.isNotEmpty) {
      filtered = tracks.where((t) => t.name.toLowerCase().contains(_searchQuery.toLowerCase())).toList();
    }

    switch (_sortOption) {
      case TrackSortOption.none:
        break;
      case TrackSortOption.alphabetical:
        filtered.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        break;
      case TrackSortOption.distAsc:
        filtered.sort((a, b) => a.totalDistanceMeters.compareTo(b.totalDistanceMeters));
        break;
      case TrackSortOption.distDesc:
        filtered.sort((a, b) => b.totalDistanceMeters.compareTo(a.totalDistanceMeters));
        break;
      case TrackSortOption.gainPos:
        filtered.sort((a, b) => b.totalElevationGainMeters.compareTo(a.totalElevationGainMeters));
        break;
      case TrackSortOption.lossNeg:
        filtered.sort((a, b) => b.totalElevationLossMeters.compareTo(a.totalElevationLossMeters));
        break;
      case TrackSortOption.totalElevation:
        filtered.sort((a, b) => (b.totalElevationGainMeters + b.totalElevationLossMeters)
            .compareTo(a.totalElevationGainMeters + a.totalElevationLossMeters));
        break;
      case TrackSortOption.proximity:
        if (userPos != null) {
          // Simplification : on ne trie pas par proximité ici car il faudrait charger les points
          // de chaque trace, ce qui est lourd. On garde l'ordre alphabétique en fallback.
          filtered.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        }
        break;
    }
    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final isar = context.watch<IsarService>();
    final settings = context.watch<SettingsService>();
    final gpxScanner = context.watch<GpxScannerService>();
    final recording = context.watch<RecordingService>();
    
    final userPos = recording.currentPosition.value != null 
        ? LatLng(recording.currentPosition.value!.latitude, recording.currentPosition.value!.longitude)
        : null;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Track Manager'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          if (gpxScanner.isScanning)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.0),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.greenAccent),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _refreshFolder(),
              tooltip: 'Scanner le dossier GPX/KML',
            ),
          IconButton(
            icon: const Icon(Icons.done_all),
            onPressed: () async {
              final allTracks = await isar.isar.traces.where().findAll();
              settings.setActiveGpxList(allTracks.map((t) => t.name).toList());
            },
            tooltip: 'Tout activer',
          ),
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ImportShareScreen()),
            ),
            tooltip: 'Importer un partage',
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSearchAndSort(),
          Expanded(
            child: StreamBuilder<List<Trace>>(
              stream: isar.isar.traces.where().watch(fireImmediately: true),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                
                final allTracks = snapshot.data!;
                if (allTracks.isEmpty) {
                  return const Center(
                    child: Text(
                      'Aucune piste importée.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38),
                    ),
                  );
                }

                if (settings.gpxStoragePath == null) {
                  return ListView.builder(
                    itemCount: allTracks.length,
                    itemBuilder: (context, index) => _buildTrackTile(allTracks[index], settings),
                  );
                }

                // Construction de l'arborescence
                return _buildFileExplorer(allTracks, settings, userPos);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAndSort() {
    return Container(
      padding: const EdgeInsets.all(12),
      color: Colors.white.withValues(alpha: 0.05),
      child: Column(
        children: [
          TextField(
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: 'Rechercher une trace...',
              hintStyle: TextStyle(color: Colors.white38),
              prefixIcon: Icon(Icons.search, color: Colors.white70),
              isDense: true,
              border: InputBorder.none,
            ),
            onChanged: (v) => setState(() => _searchQuery = v),
          ),
          const Divider(color: Colors.white10),
          Row(
            children: [
              const Text('Trier par :', style: TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<TrackSortOption>(
                  value: _sortOption,
                  isExpanded: true,
                  dropdownColor: Colors.grey[900],
                  underline: const SizedBox(),
                  style: const TextStyle(color: Colors.greenAccent, fontSize: 13, fontWeight: FontWeight.bold),
                  items: const [
                    DropdownMenuItem(value: TrackSortOption.none, child: Text('Aucun (par défaut)')),
                    DropdownMenuItem(value: TrackSortOption.alphabetical, child: Text('Ordre alphabétique')),
                    DropdownMenuItem(value: TrackSortOption.proximity, child: Text('Proximité')),
                    DropdownMenuItem(value: TrackSortOption.distAsc, child: Text('Distance croissante')),
                    DropdownMenuItem(value: TrackSortOption.distDesc, child: Text('Distance décroissante')),
                    DropdownMenuItem(value: TrackSortOption.gainPos, child: Text('Dénivelé positif')),
                    DropdownMenuItem(value: TrackSortOption.lossNeg, child: Text('Dénivelé négatif')),
                    DropdownMenuItem(value: TrackSortOption.totalElevation, child: Text('Dénivelé cumulé')),
                  ],
                  onChanged: (v) => setState(() => _sortOption = v!),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFileExplorer(List<Trace> allTracks, SettingsService settings, LatLng? userPos) {
    final rootPath = p.canonicalize(settings.gpxStoragePath!);
    
    // Si on a une recherche ou un tri spécifique, on passe en mode liste plate
    if (_searchQuery.isNotEmpty || _sortOption != TrackSortOption.none) {
      final sorted = _sortTracks(allTracks, userPos);
      return ListView.builder(
        itemCount: sorted.length,
        itemBuilder: (context, index) => _buildTrackTile(sorted[index], settings),
      );
    }

    // Construction de l'arborescence récursive
    final tree = _FolderNode('');
    for (final track in allTracks) {
      final rawPath = track.sourceFilePath;
      if (rawPath == null) {
        tree.tracks.add(track);
        continue;
      }

      try {
        final normalizedTrackPath = p.canonicalize(rawPath);
        if (p.isWithin(rootPath, normalizedTrackPath)) {
          final relPath = p.relative(normalizedTrackPath, from: rootPath);
          final parts = p.split(p.dirname(relPath));
          
          _FolderNode current = tree;
          if (parts.isNotEmpty && parts[0] != '.') {
            for (final part in parts) {
              current = current.subfolders.putIfAbsent(part, () => _FolderNode(part));
            }
          }
          current.tracks.add(track);
        } else {
          tree.tracks.add(track);
        }
      } catch (e) {
        tree.tracks.add(track);
      }
    }

    // Si on a "double-cliqué" dans un dossier, on ne montre que son contenu.
    _FolderNode currentNode = tree;
    final validPath = <String>[];
    for (final part in _drillPath) {
      final next = currentNode.subfolders[part];
      if (next == null) break;
      currentNode = next;
      validPath.add(part);
    }
    if (validPath.length != _drillPath.length) {
      // Le dossier affiché a disparu (suppression/renommage) : on remonte
      // au dernier niveau encore valide.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _drillPath = validPath);
      });
    }

    return Column(
      children: [
        if (validPath.isNotEmpty) _buildBreadcrumbBar(validPath),
        Expanded(
          child: ListView(
            children: _buildTreeTiles(currentNode, settings, pathPrefix: validPath),
          ),
        ),
      ],
    );
  }

  Widget _buildBreadcrumbBar(List<String> path) {
    return Material(
      color: Colors.white.withValues(alpha: 0.05),
      child: InkWell(
        onTap: () => setState(() => _drillPath = path.sublist(0, path.length - 1)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              const Icon(Icons.arrow_back, color: Colors.white70),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  path.join(' / '),
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildTreeTiles(_FolderNode node, SettingsService settings,
      {int depth = 0, List<String> pathPrefix = const []}) {
    final List<Widget> tiles = [];

    // Dossiers d'abord (triés par nom)
    final sortedSubfolders = node.subfolders.keys.toList()..sort();
    for (final folderName in sortedSubfolders) {
      final subNode = node.subfolders[folderName]!;
      final subPath = [...pathPrefix, folderName];
      tiles.add(
        GestureDetector(
          // Double-clic : "entre" dans le dossier pour n'afficher que son contenu.
          onDoubleTap: () => setState(() => _drillPath = subPath),
          child: ExpansionTile(
            leading: Padding(
              padding: EdgeInsets.only(left: depth * 16.0),
              child: const Icon(Icons.folder, color: Colors.blueAccent),
            ),
            title: Text(folderName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            children: _buildTreeTiles(subNode, settings, depth: depth + 1, pathPrefix: subPath),
          ),
        ),
      );
    }

    // Traces ensuite (triées par nom)
    final sortedTracks = node.tracks..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    for (final track in sortedTracks) {
      tiles.add(
        Padding(
          padding: EdgeInsets.only(left: depth * 16.0),
          child: _buildTrackTile(track, settings),
        ),
      );
    }

    return tiles;
  }

  Widget _buildTrackTile(Trace track, SettingsService settings) {
    final isActive = settings.activeGpxNames.contains(track.name);
    final isProcessing = track.processingStatus == TraceProcessingStatus.processing || 
                         track.processingStatus == TraceProcessingStatus.pending;

    return ListTile(
      leading: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            Icons.route, 
            color: track.colorHex != null ? Color(track.colorHex!) : (isActive ? Colors.greenAccent : Colors.white38)
          ),
          if (isProcessing)
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 1, color: Colors.greenAccent),
            ),
        ],
      ),
      title: Text(
        track.name.isNotEmpty ? track.name : 'Piste sans nom',
        style: const TextStyle(color: Colors.white),
      ),
      subtitle: Text(
        track.processingStatus == TraceProcessingStatus.ready
            ? '${(track.totalDistanceMeters / 1000).toStringAsFixed(1)} km  •  ${track.totalElevationGainMeters.round()} m +'
            : (track.processingStatus == TraceProcessingStatus.error ? 'Erreur de segmentation' : 'Calcul du Mesh...'),
        style: TextStyle(
          color: track.processingStatus == TraceProcessingStatus.error ? Colors.redAccent : Colors.white38,
          fontSize: 11
        ),
      ),
      trailing: isProcessing 
        ? null 
        : Switch(
            value: isActive,
            onChanged: (value) {
              settings.toggleActiveGpx(track.name);
            },
            activeThumbColor: Colors.greenAccent,
          ),
      onTap: isProcessing ? null : () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => TrackEditScreen(trace: track)),
        );
      },
    );
  }
}

class _FolderNode {
  final String name;
  final Map<String, _FolderNode> subfolders = {};
  final List<Trace> tracks = [];
  _FolderNode(this.name);
}
