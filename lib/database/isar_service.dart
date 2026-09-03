import 'dart:math' show cos, pi;

import 'package:isar_community/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';

import '../map/osm_poi_categories.dart';
import '../models/enums.dart';
import '../models/pending_crash_report.dart';
import '../models/point_of_interest.dart';
import '../models/recording_draft.dart';
import '../models/segment.dart';
import '../models/trace.dart';
import '../models/trace_segment_entry.dart';
import '../models/utilisateur.dart';
import '../models/waypoint.dart';
import '../models/offline_map/offline_map.dart';
import '../utils/geo_utils.dart';
import '../gpx/gpx_models.dart';

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
        OfflineMapSchema,
        PendingCrashReportSchema,
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

  Future<void> deleteSegment(int id) async {
    await isar.writeTxn(() => isar.segments.delete(id));
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

  /// Répercute un renommage de trace sur les waypoints qui lui sont
  /// rattachés ([Waypoint.associatedGpxName]) : sans cela, un waypoint
  /// resterait indexé sous l'ancien nom et disparaîtrait silencieusement du
  /// Waypoint Manager et du Roadmap de cette trace (tous deux filtrent par
  /// nom de trace, voir `searchWaypoints`).
  Future<List<Waypoint>> renameTraceWaypoints(
      String oldName, String newName) async {
    if (oldName == newName) return const [];
    final affected = await isar.waypoints
        .filter()
        .associatedGpxNameEqualTo(oldName)
        .findAll();
    if (affected.isEmpty) return const [];
    await isar.writeTxn(() async {
      for (final w in affected) {
        w.associatedGpxName = newName;
        w.updatedAt = DateTime.now();
        await isar.waypoints.put(w);
      }
    });
    return affected;
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

  Future<List<Trace>> tracesByNames(List<String> names) {
    if (names.isEmpty) return Future.value([]);
    return isar.traces.filter().anyOf(names, (q, name) => q.nameEqualTo(name)).findAll();
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

  /// Supprime les waypoints [ids] et retourne leurs [Waypoint.localUuid],
  /// pour que l'appelant puisse aussi les retirer de l'index de recherche
  /// (voir LocalSearchEngine.removeWaypoint).
  Future<List<String>> deleteWaypoints(List<int> ids) async {
    final localUuids = <String>[];
    await isar.writeTxn(() async {
      final existing = await isar.waypoints.getAll(ids);
      for (final wp in existing) {
        if (wp != null) localUuids.add(wp.localUuid);
      }
      await isar.waypoints.deleteAll(ids);
    });
    return localUuids;
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

  Future<void> setColorForWaypoints(List<int> ids, int colorHex) async {
    await isar.writeTxn(() async {
      final wps = await isar.waypoints.getAll(ids);
      for (final wp in wps) {
        if (wp != null) {
          wp.colorHex = colorHex;
          wp.updatedAt = DateTime.now();
          await isar.waypoints.put(wp);
        }
      }
    });
  }

  Future<void> setCategoryForWaypoints(List<int> ids, int? categoryId) async {
    await isar.writeTxn(() async {
      final wps = await isar.waypoints.getAll(ids);
      final category = categoryId != null ? await isar.waypointCategorys.get(categoryId) : null;
      for (final wp in wps) {
        if (wp != null) {
          wp.category.value = category;
          wp.updatedAt = DateTime.now();
          await isar.waypoints.put(wp);
          await wp.category.save();
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

  Future<Waypoint?> waypointByUuid(String localUuid) {
    return isar.waypoints.filter().localUuidEqualTo(localUuid).findFirst();
  }

  Future<Trace?> traceByUuid(String localUuid) {
    return isar.traces.filter().localUuidEqualTo(localUuid).findFirst();
  }

  Future<List<WaypointCategory>> allCategories() {
    return isar.waypointCategorys.where().sortByUpdatedAt().findAll();
  }

  Future<void> saveCategory(WaypointCategory category) async {
    category.updatedAt = DateTime.now();
    await isar.writeTxn(() => isar.waypointCategorys.put(category));
  }

  /// Retrouve la WaypointCategory correspondant à [osmCategoryId], ou la crée
  /// si elle n'existe pas encore -- garantit qu'importer deux fois un même
  /// type de POI OSM (ex: deux boulangeries) réutilise la même catégorie.
  Future<WaypointCategory> resolveOrCreateCategoryForOsmType(String osmCategoryId) async {
    final def = kOsmPoiCategories.firstWhere((c) => c.id == osmCategoryId);
    final categories = await allCategories();

    // 1. Lien déjà établi (import précédent, ou migration ci-dessous)
    var match = categories.firstWhereOrNull((c) => c.osmCategoryId == osmCategoryId);
    if (match != null) return match;

    // 2. Filet de sécurité : une catégorie du même nom existe déjà (créée
    // manuellement par l'utilisateur) -> on la relie plutôt que d'en dupliquer une.
    match = categories.firstWhereOrNull((c) => c.name.toLowerCase() == def.label.toLowerCase());
    if (match != null) {
      match.osmCategoryId = osmCategoryId;
      await saveCategory(match);
      return match;
    }

    // 3. Rien trouvé -> création automatique
    final created = WaypointCategory()
      ..localUuid = const Uuid().v4()
      ..name = def.label
      ..iconName = def.waypointIconName
      ..colorHex = def.color.toARGB32()
      ..osmCategoryId = osmCategoryId;
    await saveCategory(created);
    return created;
  }

  /// Relie les catégories par défaut historiques ("Point d'eau/Source",
  /// "Cabane/Refuge", créées par `_initDefaultCategories` avant l'existence
  /// d'`osmCategoryId`, donc absentes du filet de sécurité n°2 ci-dessus qui
  /// compare des noms strictement identiques) à leur équivalent OSM. À
  /// appeler une fois au démarrage.
  Future<void> backfillDefaultCategoryOsmIds() async {
    const legacyMapping = {
      'Point d\'eau/Source': 'water',
      'Cabane/Refuge': 'hut',
    };
    final categories = await allCategories();
    for (final cat in categories) {
      if (cat.osmCategoryId != null) continue;
      final osmId = legacyMapping[cat.name];
      if (osmId != null) {
        cat.osmCategoryId = osmId;
        await saveCategory(cat);
      }
    }
  }

  Future<List<WaypointFolder>> allFolders() {
    return isar.waypointFolders.where().sortByCreatedAt().findAll();
  }

  Future<void> saveFolder(WaypointFolder folder) async {
    folder.updatedAt = DateTime.now();
    await isar.writeTxn(() => isar.waypointFolders.put(folder));
  }

  // -----------------------------------------------------------------
  // Cartes hors ligne
  // -----------------------------------------------------------------

  Future<void> saveOfflineMap(OfflineMap map) async {
    map.updatedAt = DateTime.now();
    await isar.writeTxn(() => isar.offlineMaps.put(map));
  }

  /// À appeler une fois au démarrage. `OfflineMap.isDownloading` n'est
  /// repassé à `false` qu'à la toute fin de
  /// `OfflineMapDownloadService.download()` -- si l'app est tuée pendant un
  /// téléchargement, ce flag reste bloqué à `true` pour toujours, et plus
  /// rien dans l'UI ne peut relancer la carte (ni reprise, ni affichage des
  /// détails). Ce reset ne touche ni les tuiles déjà écrites sur disque ni
  /// `downloadProgress` : `download()` les retrouve intactes et ne
  /// retélécharge que ce qui manque.
  Future<void> resetStuckOfflineMapDownloads() async {
    final stuck = await isar.offlineMaps.filter().isDownloadingEqualTo(true).findAll();
    if (stuck.isEmpty) return;
    await isar.writeTxn(() async {
      for (final map in stuck) {
        map.isDownloading = false;
        await isar.offlineMaps.put(map);
      }
    });
  }

  Future<List<OfflineMap>> allOfflineMaps() {
    return isar.offlineMaps.where().sortByCreatedAtDesc().findAll();
  }

  Future<void> deleteOfflineMap(int id) async {
    await isar.writeTxn(() => isar.offlineMaps.delete(id));
  }

  /// Recherche filtrée de waypoints.
  /// Si [categoryId] est fourni, filtre par catégorie.
  /// Si [query] est fourni, filtre par nom (insensible à la casse).
  Future<List<Waypoint>> searchWaypoints({
    String? query,
    int? categoryId,
    double? minLat,
    double? maxLat,
    double? minLon,
    double? maxLon,
    String? filterGpxName, // Ajout du paramètre manquant
    // Variante liste de filterGpxName, pour la carte (waypoints de toutes
    // les traces actuellement affichées, pas une seule) -- voir
    // MapViewModel._reload. Exclut toujours les waypoints indépendants/de
    // dossier (associatedGpxName == null), contrairement à l'absence totale
    // de filtre.
    List<String>? filterGpxNames,
  }) async {
    // Utilisation d'une requête simple et filtrage manuel pour la robustesse
    final all = await isar.waypoints.where().findAll();
    
    return all.where((w) {
      bool matches = true;
      
      if (query != null && query.isNotEmpty) {
        matches &= w.name.toLowerCase().contains(query.toLowerCase());
      }
      
      if (categoryId != null) {
        matches &= w.category.value?.id == categoryId;
      }
      
      if (filterGpxName != null) {
        matches &= w.associatedGpxName == filterGpxName;
      }

      if (filterGpxNames != null) {
        matches &= w.associatedGpxName != null && filterGpxNames.contains(w.associatedGpxName);
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

  /// Inverse le sens de parcours de [trace] : les segments sont relus dans
  /// l'ordre inverse et `traveledForward` est basculé sur chacun, pour que
  /// `getTracePolyline`/`getTraceTrackPoints` reconstituent désormais la
  /// géométrie en partant de l'ancienne arrivée. Les [Segment] référencés
  /// ne sont jamais modifiés (neutres et partagés, cf. TraceSegmentEntry) --
  /// seule cette trace change de sens.
  ///
  /// Le dénivelé positif/négatif cumulé de la trace est direction-dépendant
  /// (une montée devient une descente) et doit donc être échangé ici même :
  /// contrairement à la géométrie, ces agrégats sont calculés une fois à
  /// l'import et mis en cache sur [Trace], pas recalculés à la volée. La
  /// distance totale, elle, ne dépend pas du sens.
  Future<void> reverseTraceDirection(Trace trace) async {
    final entries = List<TraceSegmentEntry>.from(trace.segments)
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));

    trace.segments = [
      for (var i = 0; i < entries.length; i++)
        TraceSegmentEntry.create(
          segmentUuid: entries[entries.length - 1 - i].segmentUuid,
          orderIndex: i,
          traveledForward: !entries[entries.length - 1 - i].traveledForward,
          enteredAt: entries[entries.length - 1 - i].enteredAt,
          exitedAt: entries[entries.length - 1 - i].exitedAt,
        ),
    ];

    final gain = trace.totalElevationGainMeters;
    trace.totalElevationGainMeters = trace.totalElevationLossMeters;
    trace.totalElevationLossMeters = gain;

    // La table serveur trace_segments doit refléter le nouvel ordre/sens.
    trace.syncStatus = SyncStatus.pending;
    await saveTrace(trace);
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

  /// Récupère la liste complète des points typés (avec temps/alt) pour une trace.
  Future<List<GpxTrackPoint>> getTraceTrackPoints(Trace trace) async {
    final List<GpxTrackPoint> trackPoints = [];
    final entries = List.from(trace.segments);
    entries.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));

    for (final entry in entries) {
      final segment = await segmentByUuid(entry.segmentUuid);
      if (segment == null) continue;

      final points = entry.traveledForward 
          ? segment.points 
          : segment.points.reversed.toList();
      
      trackPoints.addAll(points.map((p) => GpxTrackPoint(
        latitude: p.latitude,
        longitude: p.longitude,
        elevation: p.altitude,
        time: p.timestamp,
        startsNewSegment: false, // On pourrait affiner ici si besoin
      )));
    }
    return trackPoints;
  }

  /// Recalcule et met en cache le dénivelé +/- des traces qui référencent
  /// [segmentUuid], après enrichissement altimétrique de ce segment (comblage
  /// des altitudes manquantes via un modèle de terrain).
  ///
  /// La géométrie de la trace ne change pas — seuls ses agrégats de dénivelé,
  /// habituellement figés à l'import (cf. [reverseTraceDirection]), sont
  /// corrigés. C'est une correction de cache **locale** : `syncStatus` reste
  /// inchangé, rien n'est repoussé vers Supabase.
  ///
  /// Le nombre de traces reste faible (les randonnées de l'utilisateur), donc
  /// un balayage complet filtré en Dart est acceptable pour un événement
  /// ponctuel par segment.
  Future<void> recomputeTraceElevationTotals(String segmentUuid) async {
    final allTraces = await isar.traces.where().findAll();
    final affected = allTraces
        .where((t) => t.segments.any((e) => e.segmentUuid == segmentUuid))
        .toList();
    if (affected.isEmpty) return;

    final updates = <(Trace, double, double)>[];
    for (final trace in affected) {
      final points = await getTraceTrackPoints(trace);
      final r = GeoUtils.elevationGainLoss(
          points.map((p) => p.elevation).toList());
      updates.add((trace, r.gain, r.loss));
    }

    await isar.writeTxn(() async {
      for (final (trace, gain, loss) in updates) {
        trace.totalElevationGainMeters = gain;
        trace.totalElevationLossMeters = loss;
        trace.updatedAt = DateTime.now();
        await isar.traces.put(trace);
      }
    });
  }

  // -----------------------------------------------------------------
  // Rapports de crash différés (premium) — spec-crash-reporting.md §6/§7
  // -----------------------------------------------------------------

  /// Rapports en attente d'envoi (ou de décision utilisateur), les plus
  /// récents d'abord — c'est l'ordre affiché dans la section "Rapport de
  /// bug".
  Future<List<PendingCrashReport>> pendingCrashReports() {
    return isar.pendingCrashReports
        .filter()
        .statusEqualTo(CrashReportStatus.pending)
        .sortByLastOccurredAtDesc()
        .findAll();
  }

  Future<PendingCrashReport?> pendingCrashReportByFingerprint(
      String fingerprint) {
    return isar.pendingCrashReports
        .filter()
        .fingerprintEqualTo(fingerprint)
        .statusEqualTo(CrashReportStatus.pending)
        .findFirst();
  }

  Future<PendingCrashReport?> pendingCrashReportById(int id) {
    return isar.pendingCrashReports.get(id);
  }

  Future<void> savePendingCrashReport(PendingCrashReport report) async {
    await isar.writeTxn(() => isar.pendingCrashReports.put(report));
  }

  Future<void> deletePendingCrashReport(int id) async {
    await isar.writeTxn(() => isar.pendingCrashReports.delete(id));
  }

  /// Décrémente `launchesRemaining` de tous les rapports en attente (à
  /// appeler une fois par cold start réel) et renvoie ceux qui viennent
  /// d'atteindre zéro, prêts pour l'envoi automatique.
  Future<List<PendingCrashReport>> decrementLaunchesRemainingAndDue() async {
    final pending = await isar.pendingCrashReports
        .filter()
        .statusEqualTo(CrashReportStatus.pending)
        .findAll();
    if (pending.isEmpty) return const [];

    final due = <PendingCrashReport>[];
    await isar.writeTxn(() async {
      for (final report in pending) {
        report.launchesRemaining -= 1;
        await isar.pendingCrashReports.put(report);
        if (report.launchesRemaining <= 0) due.add(report);
      }
    });
    return due;
  }

  /// Purge silencieuse de toute la file (toggle désactivé, spec §4) : pas
  /// d'envoi, suppression pure et simple.
  Future<void> deleteAllPendingCrashReports() async {
    await isar.writeTxn(() => isar.pendingCrashReports.clear());
  }
}
