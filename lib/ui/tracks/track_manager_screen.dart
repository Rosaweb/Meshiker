import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:isar_community/isar.dart';
import '../../database/isar_service.dart';
import '../../models/trace.dart';
import '../../gpx/gpx_import_service.dart';
import '../../search/local_search_engine.dart';
import '../../utils/settings_service.dart';

class TrackManagerScreen extends StatefulWidget {
  const TrackManagerScreen({super.key});

  @override
  State<TrackManagerScreen> createState() => _TrackManagerScreenState();
}

class _TrackManagerScreenState extends State<TrackManagerScreen> {
  bool _isImporting = false;

  Future<void> _importGpx() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['gpx'],
    );

    if (result == null || result.files.single.path == null) return;

    if (!mounted) return;
    setState(() => _isImporting = true);

    try {
      final file = File(result.files.single.path!);
      final isarService = context.read<IsarService>();
      final searchEngine = context.read<LocalSearchEngine>();

      final importService = GpxImportService(
        isarService: isarService,
        searchEngine: searchEngine,
      );

      // ownerUuid is hardcoded for now in main.dart as 'user-local-123'
      await importService.importFile(
        file, 
        ownerUuid: 'user-local-123',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Importation réussie !')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur d\'importation : $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isar = context.watch<IsarService>();
    final settings = context.watch<SettingsService>();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Track Manager'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          if (_isImporting)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.0),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.file_upload_outlined),
              onPressed: _importGpx,
              tooltip: 'Importer un GPX',
            ),
        ],
      ),
      body: FutureBuilder<List<Trace>>(
        future: isar.isar.collection<Trace>().where().findAll(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          
          final tracks = snapshot.data!;
          if (tracks.isEmpty) {
            return const Center(
              child: Text(
                'Aucune piste importée.\nAppuyez sur le bouton en haut pour importer un GPX.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38),
              ),
            );
          }

          return ListView.builder(
            itemCount: tracks.length,
            itemBuilder: (context, index) {
              final track = tracks[index];
              final isActive = settings.activeGpxName == track.name;

              return ListTile(
                leading: Icon(
                  Icons.route, 
                  color: isActive ? Colors.greenAccent : Colors.white38
                ),
                title: Text(
                  track.name.isNotEmpty ? track.name : 'Piste sans nom',
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  '${(track.totalDistanceMeters / 1000).toStringAsFixed(1)} km',
                  style: const TextStyle(color: Colors.white38),
                ),
                trailing: Switch(
                  value: isActive,
                  onChanged: (value) {
                    settings.setActiveGpx(value ? track.name : null);
                  },
                  activeColor: Colors.greenAccent,
                ),
                onTap: () {
                  // TODO: Afficher détails ou éditer
                },
              );
            },
          );
        },
      ),
    );
  }
}
