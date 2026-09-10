import 'dart:io';

import 'package:uuid/uuid.dart';

import '../database/isar_service.dart';
import '../models/roadbook.dart';

const _uuid = Uuid();

/// Génération initiale d'un carnet de route pour une trace
/// (spec-galerie-photos-carnet-de-route.md §2.2, "Créer un carnet de route").
///
/// À n'appeler QUE lorsqu'aucun `Roadbook` n'existe encore pour [gpxName] :
/// l'appelant (menu de dossier de la galerie) résout d'abord
/// `IsarService.roadbookForTrace` et n'ouvre la génération que si le résultat
/// est null. Le carnet retourné est déjà persisté.
Future<Roadbook> generateRoadbookForTrace(
    IsarService isar, String gpxName) async {
  final waypoints = (await isar.photoWaypoints())
      .where((w) => w.associatedGpxName == gpxName)
      .toList();

  // Aplatir en photos individuelles, chacune avec son horodatage (même
  // source que le clustering : date de modification du fichier — l'EXIF
  // DateTimeOriginal serait préférable mais n'est pas lu ailleurs dans le
  // projet).
  final entries = <({String path, DateTime taken, String wpUuid, String caption, String? description})>[];
  for (final w in waypoints) {
    for (final path in w.photoPaths) {
      DateTime taken;
      try {
        taken = File(path).lastModifiedSync();
      } catch (_) {
        taken = w.createdAt;
      }
      entries.add((
        path: path,
        taken: taken,
        wpUuid: w.localUuid,
        caption: w.name,
        description: w.description,
      ));
    }
  }
  entries.sort((a, b) => a.taken.compareTo(b.taken));

  final blocks = entries
      .map((e) => RoadbookBlock()
        ..type = RoadbookBlockType.photo
        ..photoPath = e.path
        ..sourceWaypointUuid = e.wpUuid
        ..caption = e.caption
        ..description = e.description)
      .toList();

  final roadbook = Roadbook()
    ..localUuid = _uuid.v4()
    ..title = 'Carnet de route — $gpxName'
    ..associatedGpxName = gpxName
    ..blocks = blocks;

  await isar.saveRoadbook(roadbook);
  return roadbook;
}
