import 'dart:math' show cos, pi;

import 'package:isar_community/isar.dart';
import 'package:path_provider/path_provider.dart';

import '../models/enums.dart';
import '../models/point_of_interest.dart';
import '../models/recording_draft.dart';
import '../models/segment.dart';
import '../models/trace.dart';
import '../models/trace_segment_entry.dart';
import '../models/utilisateur.dart';
import '../models/waypoint.dart';
import '../utils/geo_utils.dart';

/// Point d'entrée unique vers la base locale.
///
/// Isar est ouvert UNE SEULE FOIS au démarrage de l'app (typiquement dans
/// `main()`, avant `runApp`) et cette instance est réutilisée partout : le
/// service d'enregistrement GPS en arrière-plan, les écrans de carte, et
/// plus tard le moteur de synchronisation.
///
/// Pourquoi Isar (via le fork activement maintenu `isar_community`)
/// plutôt que Hive pour ce projet précis :
/// - les segments contiennent des listes d'objets typés (`List<PointGPS>`)
///   qu'Isar sait indexer/interroger nativement via `@embedded`, alors que
///   Hive resterait un simple store clé/valeur nécessitant une
///   sérialisation JSON manuelle à chaque lecture/écriture ;
/// - Isar permet des requêtes filtrées et indexées (« tous les segments
///   `pending` », « segments dans ce bounding box ») sans charger toute
///   la base en mémoire — indispensable dès que la toile d'araignée
///   locale atteint plusieurs milliers de segments ;
/// - les écritures batch sont rapides, ce qui convient à un flux GPS
///   haute fréquence enregistré en tâche de fond.
///
/// Note de maintenance : le projet Isar historique (`isar`/`isar_flutter_libs`
/// publiés par l'auteur d'origine) a connu un ralentissement de
/// maintenance ; `isar_community` est le fork qui a repris le flambeau et
/// conserve une API quasi identique. Si votre équipe préfère une base
/// relationnelle plus "classique" à long terme, Drift (SQLite) ou
/// ObjectBox restent des alternatives sérieuses avec un modèle de données
/// proche — mais la structure objet/embarquée choisie ici (Segment
/// contenant directement ses PointGPS) resterait la bonne approche quel
/// que soit le moteur retenu.
class IsarService {
  IsarService._(this.isar);

  final Isar isar;

  static IsarService? _instance;

  /// Ouvre (ou réutilise) l'instance Isar unique de l'application.
  static Future<IsarService> open() async {
    if (_instance != null) return _instance!;

    final dir = await getApplicationDocumentsDirectory();
    final isar = await Isar.open(
      [
        SegmentSchema,
        TraceSchema,
        UtilisateurSchema,
        PointOfInterestSchema,
        RecordingDraftSchema,
        RecordingPointBatchSchema,
        RecordingModeOverrideSchema,
        WaypointSchema,
        WaypointCategorySchema,
        WaypointFolderSchema,
      ],
      directory: dir.path,
      // Un seul isolate d'écriture suffit ici : le service d'enregistrement
      // GPS écrit par petits lots (quelques points par minute), pas besoin
      // de multi-isolate pour ce volume. À revoir si l'import GPX en
      // masse devient un goulot d'étranglement.
    );

    _instance = IsarService._(isar);
    await _instance!._initDefaultCategories();
    return _instance!;
  }

  /// Initialise les catégories de waypoints par défaut si la base est vide.
  Future<void> _initDefaultCategories() async {
    final count = await isar.waypointCategorys.count();
    if (count > 0) return;

    final defaults = [
      ('Point d\'eau/Source', 'water_drop', 0xFF2196F3),
      ('Cabane/Refuge', 'home', 0xFF795548),
      ('Bivouac', 'tent', 0xFF4CAF50),
      ('Point de vue', 'terrain', 0xFFFF9800),
    ];

    await isar.writeTxn(() async {
      for (final (name, icon, color) in defaults) {
        final cat = WaypointCategory()
          ..localUuid = '${name.hashCode}_${DateTime.now().millisecondsSinceEpoch}'
          ..name = name
          ..iconName = icon
          ..colorHex = color;
        await isar.waypointCategorys.put(cat);
      }
    });
  }

  Future<void> close() => isar.close();

  // -----------------------------------------------------------------
  // Segments
  // -----------------------------------------------------------------

  Future<void> saveSegment(Segment segment) async {
    segment.updatedAt = DateTime.now();
    await isar.writeTxn(() => isar.segments.put(segment));
  }

  Future<Segment?> segmentByUuid(String localUuid) {
    return isar.segments.filter().localUuidEqualTo(localUuid).findFirst();
  }

  /// Segments dont l'enveloppe géographique intersecte le viewport donné.
  /// Pré-filtrage indexé sur la bounding box ; un affinage géométrique
  /// plus précis (intersection réelle, pas juste les enveloppes) peut
  /// être appliqué en Dart sur ce sous-ensemble déjà restreint si besoin.
  Future<List<Segment>> segmentsInViewport({
    required double minLat,
    required double maxLat,
    required double minLon,
    required double maxLon,
  }) {
    return isar.segments
        .filter()
        .minLatLessThan(maxLat)
        .and()
        .maxLatGreaterThan(minLat)
        .and()
        .minLonLessThan(maxLon)
        .and()
        .maxLonGreaterThan(minLon)
        .findAll();
  }

  /// File d'attente pour le futur worker de synchronisation : tout ce qui
  /// n'a pas encore été poussé vers Supabase. À n'interroger que lorsque
  /// l'app est au premier plan et le réseau disponible — jamais pendant
  /// un enregistrement GPS actif (contrainte batterie, section 4 du brief).
  Future<List<Segment>> pendingSegments() {
    return isar.segments
        .filter()
        .syncStatusEqualTo(SyncStatus.pending)
        .findAll();
  }

  // -----------------------------------------------------------------
  // Traces
  // -----------------------------------------------------------------

  Future<void> saveTrace(Trace trace) async {
    trace.updatedAt = DateTime.now();
    await isar.writeTxn(() => isar.traces.put(trace));
  }

  Future<List<Trace>> tracesForOwner(String ownerUuid) {
    return isar.traces.filter().ownerUuidEqualTo(ownerUuid).findAll();
  }

  Future<List<Trace>> pendingTraces() {
    return isar.traces
        .filter()
        .syncStatusEqualTo(SyncStatus.pending)
        .findAll();
  }

  // -----------------------------------------------------------------
  // Points d'intérêt
  // -----------------------------------------------------------------

  Future<void> savePointOfInterest(PointOfInterest poi) async {
    poi.updatedAt = DateTime.now();
    await isar.writeTxn(() => isar.pointOfInterests.put(poi));
  }

  Future<PointOfInterest?> poiByUuid(String localUuid) {
    return isar.pointOfInterests
        .filter()
        .localUuidEqualTo(localUuid)
        .findFirst();
  }

  /// File d'attente pour le futur worker de synchronisation, symétrique
  /// de [pendingSegments]/[pendingTraces].
  Future<List<PointOfInterest>> pendingPois() {
    return isar.pointOfInterests
        .filter()
        .syncStatusEqualTo(SyncStatus.pending)
        .findAll();
  }

  /// POI dont la position tombe dans le viewport donné. Même logique de
  /// pré-filtrage indexé que [segmentsInViewport] : utilisé par
  /// `GpxImportService` pour ne charger que les POI potentiellement
  /// concernés par un nouvel import, au lieu de toute la base.
  Future<List<PointOfInterest>> poisInViewport({
    required double minLat,
    required double maxLat,
    required double minLon,
    required double maxLon,
  }) {
    return isar.pointOfInterests
        .filter()
        .latitudeGreaterThan(minLat)
        .and()
        .latitudeLessThan(maxLat)
        .and()
        .longitudeGreaterThan(minLon)
        .and()
        .longitudeLessThan(maxLon)
        .findAll();
  }

  /// Segments dans un rayon (mètres) autour d'un point — pratique pour
  /// "les segments proches de ma position" sans construire soi-même un
  /// viewport rectangulaire.
  Future<List<Segment>> segmentsNear({
    required double latitude,
    required double longitude,
    required double radiusMeters,
  }) {
    final box = _approximateBoundingBox(latitude, longitude, radiusMeters);
    return segmentsInViewport(
      minLat: box.minLat,
      maxLat: box.maxLat,
      minLon: box.minLon,
      maxLon: box.maxLon,
    );
  }

  /// POI dans un rayon (mètres) autour d'un point, avec un affinage exact
  /// par Haversine après le pré-filtrage indexé (la bounding box seule
  /// inclurait les coins d'un carré, légèrement plus larges qu'un cercle).
  Future<List<PointOfInterest>> nearbyPois({
    required double latitude,
    required double longitude,
    required double radiusMeters,
  }) async {
    final box = _approximateBoundingBox(latitude, longitude, radiusMeters);
    final candidates = await poisInViewport(
      minLat: box.minLat,
      maxLat: box.maxLat,
      minLon: box.minLon,
      maxLon: box.maxLon,
    );
    return candidates
        .where((p) =>
            GeoUtils.haversineMeters(
              latitude,
              longitude,
              p.latitude,
              p.longitude,
            ) <=
            radiusMeters)
        .toList();
  }

  ({double minLat, double maxLat, double minLon, double maxLon})
      _approximateBoundingBox(
    double lat,
    double lon,
    double radiusMeters,
  ) {
    const mPerDegLat = 111320.0;
    final mPerDegLon = 111320.0 * cos(lat * pi / 180);
    final dLat = radiusMeters / mPerDegLat;
    final dLon = radiusMeters / mPerDegLon;
    return (
      minLat: lat - dLat,
      maxLat: lat + dLat,
      minLon: lon - dLon,
      maxLon: lon + dLon,
    );
  }

  // -----------------------------------------------------------------
  // Enregistrement (staging, étape 3)
  // -----------------------------------------------------------------

  /// Session d'enregistrement laissée en cours (ni arrêtée proprement, ni
  /// finalisée), s'il y en a une. Hypothèse simplificatrice : une seule
  /// session active possible à la fois sur l'appareil, cohérente avec
  /// l'UX d'une seule randonnée enregistrée à la fois. À appeler au
  /// démarrage de l'app pour proposer une reprise (voir
  /// `RecordingService.findAbandonedDraft`).
  Future<RecordingDraft?> currentRecordingDraft() {
    return isar.recordingDrafts.where().findFirst();
  }

  // -----------------------------------------------------------------
  // Utilisateur
  // -----------------------------------------------------------------

  /// Le profil représentant l'utilisateur de CET appareil (il ne peut y
  /// en avoir qu'un, les autres profils en cache ont `isLocalDevice = false`).
  Future<Utilisateur?> currentDeviceUser() {
    return isar.utilisateurs.filter().isLocalDeviceEqualTo(true).findFirst();
  }

  Future<void> saveUser(Utilisateur user) async {
    user.updatedAt = DateTime.now();
    await isar.writeTxn(() => isar.utilisateurs.put(user));
  }

  // -----------------------------------------------------------------
  // Waypoints
  // -----------------------------------------------------------------

  Future<void> saveWaypoint(Waypoint waypoint) async {
    waypoint.updatedAt = DateTime.now();
    await isar.writeTxn(() async {
      await isar.waypoints.put(waypoint);
      await waypoint.category.save();
      await waypoint.folder.save();
    });
  }

  Future<void> deleteWaypoints(List<int> ids) async {
    await isar.writeTxn(() async {
      await isar.waypoints.deleteAll(ids);
    });
  }

  Future<void> moveWaypointsToGpx(List<int> ids, String? gpxName, {int? folderId}) async {
    await isar.writeTxn(() async {
      final wps = await isar.waypoints.getAll(ids);
      for (final wp in wps) {
        if (wp != null) {
          wp.associatedGpxName = gpxName;
          if (folderId != null) {
            wp.folder.value = await isar.waypointFolders.get(folderId);
          } else {
            wp.folder.value = null;
          }
          wp.updatedAt = DateTime.now();
          await isar.waypoints.put(wp);
          await wp.folder.save();
        }
      }
    });
  }

  Future<void> createWaypointFolder(String name) async {
    await isar.writeTxn(() async {
      final folder = WaypointFolder()
        ..localUuid = '${name.hashCode}_${DateTime.now().millisecondsSinceEpoch}'
        ..name = name;
      await isar.waypointFolders.put(folder);
    });
  }

  Future<List<Waypoint>> allWaypoints() {
    return isar.waypoints.where().findAll();
  }

  Future<List<WaypointCategory>> allCategories() {
    return isar.waypointCategorys.where().findAll();
  }

  Future<List<WaypointFolder>> allFolders() {
    return isar.waypointFolders.where().sortByCreatedAt().findAll();
  }

  Future<void> saveFolder(WaypointFolder folder) async {
    folder.updatedAt = DateTime.now();
    await isar.writeTxn(() => isar.waypointFolders.put(folder));
  }

  /// Recherche filtrée de waypoints.
  /// Si [categoryId] est fourni, filtre par catégorie.
  /// Si [query] est fourni, filtre par nom (insensible à la casse).
  Future<List<Waypoint>> searchWaypoints({
    String? query,
    int? category_id,
    double? minLat,
    double? maxLat,
    double? minLon,
    double? maxLon,
    String? filterGpxName, // Ajout du paramètre manquant
  }) async {
    // Utilisation d'une requête simple et filtrage manuel pour la robustesse
    final all = await isar.waypoints.where().findAll();
    
    return all.where((w) {
      bool matches = true;
      
      if (query != null && query.isNotEmpty) {
        matches &= w.name.toLowerCase().contains(query.toLowerCase());
      }
      
      if (category_id != null) {
        matches &= w.category.value?.id == category_id;
      }
      
      if (filterGpxName != null) {
        matches &= w.associatedGpxName == filterGpxName;
      }
      
      if (minLat != null && maxLat != null && minLon != null && maxLon != null) {
        matches &= (w.latitude >= minLat && w.latitude <= maxLat && 
                    w.longitude >= minLon && w.longitude <= maxLon);
      }
           
      return matches;
    }).toList();
  }

  /// Récupère les waypoints groupés par dossier.
  /// Les waypoints sans dossier sont retournés avec la clé 'null'.
  Future<Map<WaypointFolder?, List<Waypoint>>> waypointsGroupedByFolder() async {
    final all = await isar.waypoints.where().findAll();
    // Isar ne charge pas automatiquement les liens, il faut les charger
    for (var w in all) {
      await w.folder.load();
    }

    final Map<WaypointFolder?, List<Waypoint>> grouped = {};
    for (var w in all) {
      final folder = w.folder.value;
      grouped.putIfAbsent(folder, () => []).add(w);
    }
    return grouped;
  }

  // -----------------------------------------------------------------
  // Statistiques (Étape 4+)
  // -----------------------------------------------------------------

  /// Calcule la distance totale parcourue aujourd'hui en sommant la distance
  /// de tous les segments créés aujourd'hui et des lots d'enregistrement
  /// en cours.
  Future<double> getDailyDistanceMeters() async {
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);

    // 1. Somme des segments finalisés aujourd'hui
    final segmentsToday = await isar.segments
        .filter()
        .createdAtGreaterThan(startOfToday)
        .findAll();
    
    double total = 0;
    for (final s in segmentsToday) {
      total += s.distanceMeters;
    }

    // 2. Somme des points en cours d'enregistrement (batches)
    // Note: on utilise recordingPointBatchs (nom généré par Isar)
    final batchesToday = await isar.recordingPointBatchs
        .filter()
        .sessionUuidIsNotEmpty() // Juste pour initier le filtre
        .findAll();
        
    for (final batch in batchesToday) {
      // On ne prend que les points d'aujourd'hui
      final pointsToday = batch.points.where((p) => p.timestamp.isAfter(startOfToday)).toList();
      if (pointsToday.length < 2) continue;

      for (int i = 0; i < pointsToday.length - 1; i++) {
        total += GeoUtils.haversineMeters(
          pointsToday[i].latitude,
          pointsToday[i].longitude,
          pointsToday[i+1].latitude,
          pointsToday[i+1].longitude,
        );
      }
    }

    return total;
  }

  /// Reconstitue la géométrie complète d'une trace sous forme de liste de points.
  Future<List<({double lat, double lon})>> getTracePolyline(Trace trace) async {
    final List<({double lat, double lon})> fullPolyline = [];

    // On trie par index pour être sûr de l'ordre
    final entries = List.from(trace.segments);
    entries.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));

    for (final entry in entries) {
      final segment = await segmentByUuid(entry.segmentUuid);
      if (segment == null) continue;

      final points = entry.traveledForward 
          ? segment.points 
          : segment.points.reversed.toList();
      
      fullPolyline.addAll(points.map((p) => (lat: p.latitude, lon: p.longitude)));
    }

    return fullPolyline;
  }
}
