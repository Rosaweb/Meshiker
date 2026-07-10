import 'package:isar_community/isar.dart';
import '../database/isar_service.dart';
import '../models/point_of_interest.dart';
import '../models/segment.dart';
import '../models/trace.dart';
import '../search/local_search_engine.dart';
import 'segmentation_engine.dart';

/// Persiste un [SegmentationResult] (segments/POI à upserter + trace) et
/// met à jour l'index de recherche en conséquence.
///
/// Factorisé ici car TROIS chemins produisent désormais un
/// `SegmentationResult` à persister de façon identique : l'import GPX
/// (étape 2, `GpxImportService`), l'enregistrement en direct (étape 3,
/// `RecordingService`) et le mode planification (étape 5,
/// `PlanningController`). Dupliquer cette transaction une quatrième fois
/// n'aurait apporté aucune valeur.
class SegmentationPersistence {
  const SegmentationPersistence._();

  static Future<void> persist({
    required IsarService isarService,
    required SegmentationResult result,
    required LocalSearchEngine searchEngine,
    /// Travail supplémentaire exécuté dans LA MÊME transaction, juste
    /// après les upserts — par exemple la suppression des données de
    /// staging d'un enregistrement en direct (voir `RecordingService`),
    /// qui doit réussir ou échouer atomiquement avec le reste.
    Future<void> Function()? additionalWork,
  }) async {
    await isarService.isar.writeTxn(() async {
      for (final segment in result.segmentsToUpsert) {
        await isarService.isar.segments.put(segment);
      }
      for (final poi in result.poisToUpsert) {
        await isarService.isar.pointOfInterests.put(poi);
      }
      await isarService.isar.traces.put(result.trace);
      if (additionalWork != null) await additionalWork();
    });

    searchEngine.indexTrace(result.trace);
    for (final poi in result.poisToUpsert) {
      searchEngine.indexPoi(poi);
    }
  }
}
