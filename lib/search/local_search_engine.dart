import 'package:isar_community/isar.dart';
import '../database/isar_service.dart';
import '../models/point_of_interest.dart';
import '../models/trace.dart';
import 'search_result.dart';
import 'trigram_index.dart';

/// Moteur de recherche local : indexe les Trace et PointOfInterest deja
/// presents dans la base Isar de l'appareil et permet une recherche
/// floue instantanee, sans aucun appel reseau.
///
/// L'index vit entierement en memoire (voir TrigramIndex) et se
/// reconstruit au demarrage de l'app via rebuildFromDatabase, puis se met
/// a jour de facon incrementale a chaque ecriture (indexTrace/indexPoi/
/// removeDocument) plutot que par reconstruction complete -- important
/// pour rester reactif y compris apres plusieurs annees d'usage, quand la
/// base locale contient plusieurs milliers d'entites.
class LocalSearchEngine {
  LocalSearchEngine();

  final TrigramIndex _index = TrigramIndex();

  // Metadonnees d'affichage associees a chaque id de document, pour ne
  // pas avoir a retourner en base a chaque resultat de recherche.
  final Map<String, SearchDocType> _docTypes = {};
  final Map<String, String> _titles = {};
  final Map<String, String?> _subtitles = {};

  int get documentCount => _index.documentCount;

  /// Reconstruit entierement l'index a partir de la base locale. A
  /// appeler une fois au demarrage de l'app, juste apres IsarService.open.
  Future<void> rebuildFromDatabase(IsarService db) async {
    _index.clear();
    _docTypes.clear();
    _titles.clear();
    _subtitles.clear();

    final traces = await db.isar.traces.where().findAll();
    for (final trace in traces) {
      indexTrace(trace);
    }

    final pois = await db.isar.pointOfInterests.where().findAll();
    for (final poi in pois) {
      indexPoi(poi);
    }
  }

  void indexTrace(Trace trace) {
    final docId = 'trace:${trace.localUuid}';
    final text = [trace.name, trace.description ?? ''].join(' ');
    _index.indexDocument(docId, text);
    _docTypes[docId] = SearchDocType.trace;
    _titles[docId] = trace.name;
    _subtitles[docId] =
        '${(trace.totalDistanceMeters / 1000).toStringAsFixed(1)} km';
  }

  void indexPoi(PointOfInterest poi) {
    final docId = 'poi:${poi.localUuid}';
    final text = [poi.name, poi.description ?? ''].join(' ');
    _index.indexDocument(docId, text);
    _docTypes[docId] = SearchDocType.pointOfInterest;
    _titles[docId] = poi.name;
    _subtitles[docId] = poi.type.name;
  }

  void removeTrace(String localUuid) => _remove('trace', localUuid);
  void removePoi(String localUuid) => _remove('poi', localUuid);

  void _remove(String prefix, String localUuid) {
    final docId = '$prefix:$localUuid';
    _index.removeDocument(docId);
    _docTypes.remove(docId);
    _titles.remove(docId);
    _subtitles.remove(docId);
  }

  /// Recherche floue sur l'ensemble des traces et POI indexes.
  List<SearchResult> search(String query, {int limit = 20}) {
    if (query.trim().isEmpty) return [];
    final hits = _index.search(query, limit: limit);
    return hits.map((entry) {
      final docId = entry.key;
      final uuid = docId.substring(docId.indexOf(':') + 1);
      return SearchResult(
        docType: _docTypes[docId]!,
        uuid: uuid,
        title: _titles[docId] ?? '',
        subtitle: _subtitles[docId],
        score: entry.value,
      );
    }).toList();
  }
}
