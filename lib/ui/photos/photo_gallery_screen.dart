import 'dart:io';

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:provider/provider.dart';

import '../../database/isar_service.dart';
import '../../map/map_view_model.dart';
import '../../models/waypoint.dart';
import '../../search/local_search_engine.dart';
import '../waypoints/waypoint_edit_screen.dart';

/// Galerie "Mes photos" (spec-galerie-photos-carnet-de-route.md Partie 1).
///
/// Décision structurante (§1.2) : une tuile = un [Waypoint]
/// (`isPhotoWaypoint == true`), pas une photo isolée. La vignette montre la
/// photo d'en-tête (`headerPhotoIndex`), avec un badge "+N" si le waypoint
/// porte plusieurs photos. Éditer / Supprimer agissent sur le waypoint
/// entier ; le plein écran défile entre les photos de ce seul waypoint.
class PhotoGalleryScreen extends StatelessWidget {
  const PhotoGalleryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isar = context.read<IsarService>();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Mes photos'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      // Se rafraîchit après une édition / suppression de waypoint photo, sur
      // le même motif que WaypointManagerScreen.
      body: StreamBuilder(
        stream: isar.isar.waypoints.watchLazy(),
        builder: (context, _) {
          return FutureBuilder<List<Waypoint>>(
            future: isar.photoWaypoints(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final photos = snapshot.data!;
              if (photos.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'Aucune photo géolocalisée.\nUtilisez le bouton photo du bandeau pour en ajouter.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38),
                    ),
                  ),
                );
              }
              return _GalleryList(waypoints: photos);
            },
          );
        },
      ),
    );
  }
}

class _GalleryList extends StatelessWidget {
  final List<Waypoint> waypoints;
  const _GalleryList({required this.waypoints});

  @override
  Widget build(BuildContext context) {
    // Groupage identique à WaypointManagerScreen : un groupe par trace GPX
    // (associatedGpxName), puis les indépendants en dernier (§1.3).
    final Map<String, List<Waypoint>> byTrace = {};
    final List<Waypoint> independents = [];
    for (final w in waypoints) {
      final name = w.associatedGpxName;
      if (name == null) {
        independents.add(w);
      } else {
        byTrace.putIfAbsent(name, () => []).add(w);
      }
    }
    final traceNames = byTrace.keys.toList()..sort();

    final slivers = <Widget>[];
    for (final name in traceNames) {
      slivers.add(_GroupHeader(
        title: name,
        waypoints: byTrace[name]!,
        showMenu: true,
      ));
      slivers.add(_PhotoGrid(waypoints: byTrace[name]!));
    }
    if (independents.isNotEmpty) {
      slivers.add(_GroupHeader(
        title: 'Sans trace',
        waypoints: independents,
        showMenu: false,
      ));
      slivers.add(_PhotoGrid(waypoints: independents));
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 24)));

    return CustomScrollView(slivers: slivers);
  }
}

class _GroupHeader extends StatelessWidget {
  final String title;
  final List<Waypoint> waypoints;
  final bool showMenu;
  const _GroupHeader({
    required this.title,
    required this.waypoints,
    required this.showMenu,
  });

  Future<void> _confirmDeleteGroup(BuildContext context) async {
    final isar = context.read<IsarService>();
    final searchEngine = context.read<LocalSearchEngine>();
    final mapViewModel = context.read<MapViewModel>();
    final count = waypoints.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Supprimer le dossier', style: TextStyle(color: Colors.white)),
        content: Text(
          'Voulez-vous vraiment supprimer toutes les photos de « $title » ? '
          'Les $count point(s) photo et leurs fichiers image seront définitivement '
          'supprimés de votre téléphone (pas seulement retirés de la galerie). '
          'Cette action est irréversible.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('ANNULER'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('TOUT SUPPRIMER', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // Suppression réelle des fichiers image (§1.5) puis des waypoints.
    for (final w in waypoints) {
      for (final path in w.photoPaths) {
        try {
          final f = File(path);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {/* best-effort : un fichier déjà absent n'est pas une erreur */}
      }
    }
    final deletedUuids =
        await isar.deleteWaypoints(waypoints.map((w) => w.id).toList());
    for (final uuid in deletedUuids) {
      searchEngine.removeWaypoint(uuid);
    }
    mapViewModel.refreshNow();
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (showMenu)
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Colors.white54, size: 20),
                color: Colors.grey[900],
                onSelected: (v) {
                  if (v == 'delete') _confirmDeleteGroup(context);
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('Supprimer le dossier',
                        style: TextStyle(color: Colors.redAccent)),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _PhotoGrid extends StatelessWidget {
  final List<Waypoint> waypoints;
  const _PhotoGrid({required this.waypoints});

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 4,
          mainAxisSpacing: 4,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, i) => _PhotoTile(waypoint: waypoints[i]),
          childCount: waypoints.length,
        ),
      ),
    );
  }
}

class _PhotoTile extends StatelessWidget {
  final Waypoint waypoint;
  const _PhotoTile({required this.waypoint});

  String? get _headerPath {
    if (waypoint.photoPaths.isEmpty) return null;
    final idx = waypoint.headerPhotoIndex.clamp(0, waypoint.photoPaths.length - 1);
    return waypoint.photoPaths[idx];
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final isar = context.read<IsarService>();
    final searchEngine = context.read<LocalSearchEngine>();
    final mapViewModel = context.read<MapViewModel>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Supprimer', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Voulez-vous vraiment supprimer ce point photo ? Cette action supprime '
          'la ou les photo(s) associée(s).',
          style: TextStyle(color: Colors.white70),
        ),
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
    if (confirmed != true) return;
    final deletedUuids = await isar.deleteWaypoints([waypoint.id]);
    for (final uuid in deletedUuids) {
      searchEngine.removeWaypoint(uuid);
    }
    mapViewModel.refreshNow();
  }

  void _openEditor(BuildContext context) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (context) => WaypointEditScreen(
        waypoint: waypoint,
        isarService: context.read<IsarService>(),
      ),
    ).then((_) {
      if (context.mounted) context.read<MapViewModel>().refreshNow();
    });
  }

  void _openFullscreen(BuildContext context) {
    if (waypoint.photoPaths.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _PhotoFullscreenViewer(
          paths: List<String>.from(waypoint.photoPaths),
          initialIndex:
              waypoint.headerPhotoIndex.clamp(0, waypoint.photoPaths.length - 1),
          title: waypoint.name,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final path = _headerPath;
    final extra = waypoint.photoPaths.length - 1;
    return GestureDetector(
      onTap: () => _openFullscreen(context),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            color: Colors.white10,
            child: path == null
                ? const Icon(Icons.broken_image, color: Colors.white24)
                : Image.file(
                    File(path),
                    fit: BoxFit.cover,
                    // Décodage à taille réduite : ne jamais décoder des photos
                    // de smartphone en pleine résolution dans une grille (§1.4).
                    cacheWidth: 300,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.broken_image, color: Colors.white24),
                  ),
          ),
          if (extra > 0)
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('+$extra',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ),
          Positioned(
            bottom: 0,
            right: 0,
            child: Material(
              color: Colors.black.withValues(alpha: 0.4),
              shape: const CircleBorder(),
              child: PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Colors.white, size: 20),
                color: Colors.grey[900],
                onSelected: (v) {
                  if (v == 'edit') _openEditor(context);
                  if (v == 'delete') _confirmDelete(context);
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text('Éditer', style: TextStyle(color: Colors.white)),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('Supprimer', style: TextStyle(color: Colors.redAccent)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Visualiseur plein écran (§1.6) : un [PageView] de [PhotoView] sur les
/// `photoPaths` du waypoint tapé, zoom pincé natif. Aucune édition ici.
class _PhotoFullscreenViewer extends StatefulWidget {
  final List<String> paths;
  final int initialIndex;
  final String title;
  const _PhotoFullscreenViewer({
    required this.paths,
    required this.initialIndex,
    required this.title,
  });

  @override
  State<_PhotoFullscreenViewer> createState() => _PhotoFullscreenViewerState();
}

class _PhotoFullscreenViewerState extends State<_PhotoFullscreenViewer> {
  late final PageController _controller;
  late int _current;

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          widget.paths.length > 1
              ? '${widget.title}  ·  ${_current + 1}/${widget.paths.length}'
              : widget.title,
          style: const TextStyle(fontSize: 15),
        ),
      ),
      body: PhotoViewGallery.builder(
        itemCount: widget.paths.length,
        pageController: _controller,
        onPageChanged: (i) => setState(() => _current = i),
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        loadingBuilder: (context, _) =>
            const Center(child: CircularProgressIndicator()),
        builder: (context, i) => PhotoViewGalleryPageOptions(
          imageProvider: FileImage(File(widget.paths[i])),
          minScale: PhotoViewComputedScale.contained,
          maxScale: PhotoViewComputedScale.covered * 3,
          heroAttributes: PhotoViewHeroAttributes(tag: widget.paths[i]),
        ),
      ),
    );
  }
}
