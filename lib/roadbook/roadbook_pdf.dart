import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/roadbook.dart';

/// Export PDF d'un carnet de route + partage via la feuille native
/// (spec-galerie-photos-carnet-de-route.md §2.4). Aucun envoi serveur : le
/// PDF est généré localement puis remis au système de partage.
class RoadbookPdf {
  RoadbookPdf._();

  /// Largeur cible des photos réintégrées au PDF (§2.4) : suffisant pour une
  /// lecture écran ou une impression A4/A5, sans embarquer la pleine
  /// résolution d'un capteur de smartphone.
  static const int _maxPhotoWidth = 1800;
  static const int _jpgQuality = 80;

  static Future<Uint8List> build(Roadbook roadbook) async {
    final doc = pw.Document();
    final children = <pw.Widget>[];

    for (final block in roadbook.blocks) {
      if (block.type == RoadbookBlockType.photo) {
        final path = block.photoPath;
        if (path != null) {
          final bytes = await _resizedJpg(path);
          if (bytes != null) {
            children.add(pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 6),
              child: pw.Image(pw.MemoryImage(bytes),
                  fit: pw.BoxFit.contain,
                  alignment: pw.Alignment.centerLeft),
            ));
          }
        }
        final caption = block.caption?.trim() ?? '';
        final description = block.description?.trim() ?? '';
        if (caption.isNotEmpty) {
          children.add(pw.Text(caption,
              style: pw.TextStyle(
                  fontSize: 13, fontWeight: pw.FontWeight.bold)));
        }
        if (description.isNotEmpty) {
          children.add(pw.Text(description,
              style: const pw.TextStyle(fontSize: 11)));
        }
        children.add(pw.SizedBox(height: 18));
      } else {
        final text = block.textContent?.trim() ?? '';
        if (text.isNotEmpty) {
          children.add(pw.Paragraph(
            text: text,
            style: const pw.TextStyle(fontSize: 11),
            margin: const pw.EdgeInsets.only(bottom: 18),
          ));
        }
      }
    }

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: (context) => context.pageNumber == 1
            ? pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 16),
                child: pw.Text(roadbook.title,
                    style: pw.TextStyle(
                        fontSize: 20, fontWeight: pw.FontWeight.bold)),
              )
            : pw.SizedBox(),
        build: (context) => children.isEmpty
            ? [pw.Text('Carnet vide.')]
            : children,
      ),
    );

    return doc.save();
  }

  /// Génère le PDF et le passe à la feuille de partage système.
  static Future<void> share(Roadbook roadbook) async {
    final bytes = await build(roadbook);
    final safeName = roadbook.title
        .replaceAll(RegExp(r'[^\w\s-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    await Printing.sharePdf(
      bytes: bytes,
      filename: '${safeName.isEmpty ? 'carnet_de_route' : safeName}.pdf',
    );
  }

  static Future<Uint8List?> _resizedJpg(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final raw = await file.readAsBytes();
      final decoded = img.decodeImage(raw);
      if (decoded == null) return null;
      final resized = decoded.width > _maxPhotoWidth
          ? img.copyResize(decoded, width: _maxPhotoWidth)
          : decoded;
      return img.encodeJpg(resized, quality: _jpgQuality);
    } catch (_) {
      return null;
    }
  }
}
