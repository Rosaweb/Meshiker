import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/isar_service.dart';
import '../../models/roadbook.dart';
import '../../roadbook/roadbook_pdf.dart';

/// Écran d'édition d'un carnet de route
/// (spec-galerie-photos-carnet-de-route.md §2.3).
///
/// Travaille sur une copie éditable en mémoire des blocs ; rien n'est
/// persisté tant que l'utilisateur n'appuie pas sur "Sauvegarder". L'édition
/// n'affecte jamais les waypoints / photos d'origine.
class RoadbookScreen extends StatefulWidget {
  final Roadbook roadbook;
  const RoadbookScreen({super.key, required this.roadbook});

  @override
  State<RoadbookScreen> createState() => _RoadbookScreenState();
}

class _RoadbookScreenState extends State<RoadbookScreen> {
  late final TextEditingController _titleController;
  late final List<_BlockEdit> _blocks;
  bool _dirty = false;
  bool _deleted = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.roadbook.title)
      ..addListener(_markDirty);
    _blocks = widget.roadbook.blocks.map(_BlockEdit.from).toList();
    for (final b in _blocks) {
      b.attachDirtyListener(_markDirty);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    for (final b in _blocks) {
      b.dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  // --- Composition / persistance ---------------------------------------------

  String? _nullIfEmpty(String s) => s.trim().isEmpty ? null : s.trim();

  Roadbook _compose() {
    widget.roadbook.title = _titleController.text.trim().isEmpty
        ? 'Carnet de route'
        : _titleController.text.trim();
    widget.roadbook.blocks = _blocks.map((b) {
      final rb = RoadbookBlock()..type = b.type;
      if (b.type == RoadbookBlockType.photo) {
        rb
          ..photoPath = b.photoPath
          ..sourceWaypointUuid = b.sourceWaypointUuid
          ..caption = _nullIfEmpty(b.captionController!.text)
          ..description = _nullIfEmpty(b.descriptionController!.text);
      } else {
        rb.textContent = _nullIfEmpty(b.textController!.text);
      }
      return rb;
    }).toList();
    return widget.roadbook;
  }

  Future<void> _save() async {
    await context.read<IsarService>().saveRoadbook(_compose());
    if (!mounted) return;
    setState(() => _dirty = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Carnet enregistré.')),
    );
  }

  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      await RoadbookPdf.share(_compose());
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Échec de l\'export : $e')),
      );
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Supprimer le carnet', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Voulez-vous vraiment supprimer ce carnet de route ? Le titre et les '
          'descriptions saisis dans le carnet seront perdus.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ANNULER')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('SUPPRIMER', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<IsarService>().deleteRoadbook(widget.roadbook.id);
    if (!mounted) return;
    _deleted = true;
    Navigator.of(context).pop();
  }

  // --- Blocs ---------------------------------------------------------------

  Future<void> _removePhotoBlock(int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Retirer la photo', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Retirer cette photo du carnet ? Le titre et la description saisis ici '
          'seront supprimés. La photo elle-même reste sur la trace et son point '
          'd\'origine.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ANNULER')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('RETIRER', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _blocks.removeAt(index).dispose();
      _dirty = true;
    });
  }

  void _removeTextBlock(int index) {
    setState(() {
      _blocks.removeAt(index).dispose();
      _dirty = true;
    });
  }

  void _insertTextBlock(int atIndex) {
    setState(() {
      _blocks.insert(atIndex, _BlockEdit.newText()..attachDirtyListener(_markDirty));
      _dirty = true;
    });
  }

  Future<bool> _confirmLeave() async {
    if (!_dirty) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Modifications non enregistrées',
            style: TextStyle(color: Colors.white)),
        content: const Text('Quitter sans sauvegarder le carnet de route ?',
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('RESTER')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('QUITTER', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    return leave == true;
  }

  Future<void> _handlePopAttempt() async {
    final shouldLeave = await _confirmLeave();
    if (!shouldLeave) return;
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty || _deleted,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handlePopAttempt();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('Carnet de route'),
          actions: [
            PopupMenuButton<String>(
              color: Colors.grey[900],
              onSelected: (v) {
                if (v == 'export') _export();
                if (v == 'delete') _delete();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                    value: 'export',
                    child: Text('Exporter', style: TextStyle(color: Colors.white))),
                PopupMenuItem(
                    value: 'delete',
                    child: Text('Supprimer', style: TextStyle(color: Colors.redAccent))),
              ],
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            TextField(
              controller: _titleController,
              style: const TextStyle(
                  color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              decoration: const InputDecoration(
                labelText: 'Titre du carnet',
                labelStyle: TextStyle(color: Colors.white54),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24)),
              ),
            ),
            const SizedBox(height: 8),
            for (int i = 0; i < _blocks.length; i++) ...[
              _InsertTextButton(onTap: () => _insertTextBlock(i)),
              _blocks[i].type == RoadbookBlockType.photo
                  ? _PhotoBlockCard(
                      edit: _blocks[i],
                      onRemove: () => _removePhotoBlock(i),
                    )
                  : _TextBlockCard(
                      edit: _blocks[i],
                      onRemove: () => _removeTextBlock(i),
                    ),
            ],
            _InsertTextButton(onTap: () => _insertTextBlock(_blocks.length)),
            if (_blocks.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Ce carnet ne contient aucun bloc.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38)),
              ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: ElevatedButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Sauvegarder'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.greenAccent,
                foregroundColor: Colors.black,
                minimumSize: const Size.fromHeight(46),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- Modèle d'édition en mémoire -------------------------------------------

class _BlockEdit {
  _BlockEdit._(this.type,
      {this.photoPath,
      this.sourceWaypointUuid,
      this.captionController,
      this.descriptionController,
      this.textController});

  factory _BlockEdit.from(RoadbookBlock b) {
    if (b.type == RoadbookBlockType.photo) {
      return _BlockEdit._(
        RoadbookBlockType.photo,
        photoPath: b.photoPath,
        sourceWaypointUuid: b.sourceWaypointUuid,
        captionController: TextEditingController(text: b.caption ?? ''),
        descriptionController: TextEditingController(text: b.description ?? ''),
      );
    }
    return _BlockEdit._(
      RoadbookBlockType.text,
      textController: TextEditingController(text: b.textContent ?? ''),
    );
  }

  factory _BlockEdit.newText() => _BlockEdit._(
        RoadbookBlockType.text,
        textController: TextEditingController(),
      );

  final RoadbookBlockType type;
  final String? photoPath;
  final String? sourceWaypointUuid;
  final TextEditingController? captionController;
  final TextEditingController? descriptionController;
  final TextEditingController? textController;

  void attachDirtyListener(VoidCallback l) {
    captionController?.addListener(l);
    descriptionController?.addListener(l);
    textController?.addListener(l);
  }

  void dispose() {
    captionController?.dispose();
    descriptionController?.dispose();
    textController?.dispose();
  }
}

// --- Widgets de bloc ------------------------------------------------------

class _InsertTextButton extends StatelessWidget {
  final VoidCallback onTap;
  const _InsertTextButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TextButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.add, size: 16, color: Colors.white38),
        label: const Text('Bloc texte',
            style: TextStyle(color: Colors.white38, fontSize: 12)),
        style: TextButton.styleFrom(
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: 8)),
      ),
    );
  }
}

class _PhotoBlockCard extends StatelessWidget {
  final _BlockEdit edit;
  final VoidCallback onRemove;
  const _PhotoBlockCard({required this.edit, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260, minHeight: 120),
                child: edit.photoPath == null
                    ? const Center(
                        child: Icon(Icons.broken_image, color: Colors.white24))
                    : Image.file(
                        File(edit.photoPath!),
                        width: double.infinity,
                        fit: BoxFit.cover,
                        cacheWidth: 700,
                        errorBuilder: (_, __, ___) => const SizedBox(
                          height: 120,
                          child: Center(
                              child: Icon(Icons.broken_image,
                                  color: Colors.white24)),
                        ),
                      ),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white, size: 18),
                    onPressed: onRemove,
                    tooltip: 'Retirer du carnet',
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(
                  controller: edit.captionController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    hintText: 'Titre',
                    hintStyle: TextStyle(color: Colors.white38),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: edit.descriptionController,
                  style: const TextStyle(color: Colors.white70),
                  maxLines: 3,
                  minLines: 1,
                  decoration: const InputDecoration(
                    hintText: 'Description',
                    hintStyle: TextStyle(color: Colors.white24),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TextBlockCard extends StatelessWidget {
  final _BlockEdit edit;
  final VoidCallback onRemove;
  const _TextBlockCard({required this.edit, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: edit.textController,
              style: const TextStyle(color: Colors.white),
              maxLines: null,
              minLines: 2,
              decoration: const InputDecoration(
                hintText: 'Texte libre',
                hintStyle: TextStyle(color: Colors.white38),
                border: InputBorder.none,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white38, size: 18),
            onPressed: onRemove,
            tooltip: 'Supprimer le bloc',
          ),
        ],
      ),
    );
  }
}
