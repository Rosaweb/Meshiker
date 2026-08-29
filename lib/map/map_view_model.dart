import 'dart:async';

import 'package:flutter/foundation.dart';

import '../database/isar_service.dart';
import '../models/point_of_interest.dart';
import '../models/segment.dart';
import '../models/waypoint.dart';
import '../models/trace.dart';
import '../sync/sync_engine.dart';
import '../utils/overpass_service.dart';
import '../utils/osm_poi_cache.dart';

/// Alimente MapScreen en segments/POI visibles dans le viewport courant.
///
/// Lecture TOUJOURS locale (Isar) en premier lieu : la carte reste
/// utilisable en zone blanche, conformement a la contrainte "100%
/// deconnecte" du brief. Le pull communautaire via syncEngine est un
/// bonus opportuniste quand le reseau est disponible, jamais un
/// prerequis a l'affichage.
class MapViewModel {
  MapViewModel({required this.isarService, this.syncEngine});

  final IsarService isarService;

  /// null si l'app est utilisee sans compte/hors-ligne -- la carte reste
  /// alors purement locale, sans jamais tenter d'appel reseau.
  final SyncEngine? syncEngine;

  final ValueNotifier<List<Segment>> segments = ValueNotifier(const []);
  final ValueNotifier<List<PointOfInterest>> pois = ValueNotifier(const []);
  final ValueNotifier<List<Waypoint>> waypoints = ValueNotifier(const []);
  final ValueNotifier<List<Trace>> activeTraces = ValueNotifier(const []);
  final ValueNotifier<List<OsmPoi>> osmPois = ValueNotifier(const []);
  final ValueNotifier<bool> isRefreshingCommunityData = ValueNotifier(false);
  final ValueNotifier<bool> isLoadingOsmPois = ValueNotifier(false);

  /// Cache par grille des POI OSM déjà récupérés dans la session en cours
  /// (voir OsmPoiCache) -- évite de rappeler Overpass pour une zone déjà
  /// visitée.
  final OsmPoiCache _osmPoiCache = OsmPoiCache();

  /// Dernière position caméra connue de MapScreen (centre + zoom), tenue à
  /// jour à chaque déplacement. Lu par MainNavigationScreen à la mise en
  /// arrière-plan pour mémoriser où l'utilisateur a laissé la carte.
  final ValueNotifier<({double lat, double lon, double zoom})?> liveCamera =
      ValueNotifier(null);

  /// Demande ponctuelle de recentrage (ex: "Localiser sur la carte" depuis
  /// la fenêtre contextuelle d'un waypoint). MapScreen l'écoute, exécute le
  /// déplacement puis remet la valeur à null.
  final ValueNotifier<({double lat, double lon})?> centerRequest =
      ValueNotifier(null);

  /// Demande ponctuelle de cadrage sur une zone (ex: "Localiser sur la
  /// carte" depuis la fiche d'une trace GPX, qui doit cadrer toute
  /// l'étendue de la trace plutôt qu'un simple point). MapScreen l'écoute,
  /// exécute le cadrage puis remet la valeur à null.
  final ValueNotifier<({double minLat, double maxLat, double minLon, double maxLon})?>
      centerBoundsRequest = ValueNotifier(null);

  Timer? _debounce;

  ({double minLat, double maxLat, double minLon, double maxLon})?
      _lastBounds;
  List<String> _lastActiveGpxNames = const [];
  double _lastZoom = 15;
  bool _lastOsmPoisEnabled = false;
  Set<String> _lastOsmPoiCategoryIds = const {};
  String? _lastRoadmapTraceName;
  bool _lastShowEveryWaypoint = false;

  /// A appeler quand le viewport de la carte change (deplacement, zoom).
  /// Debounce volontairement les appels rapproches (l'utilisateur qui
  /// deplace la carte declenche autrement des dizaines de requetes Isar
  /// par seconde) et ne tire les donnees communautaires qu'une fois le
  /// deplacement stabilise.
  void onViewportChanged({
    required double minLat,
    required double maxLat,
    required double minLon,
    required double maxLon,
    List<String> activeGpxNames = const [],
    double zoom = 15,
    bool osmPoisEnabled = false,
    Set<String> osmPoiCategoryIds = const {},
    String? roadmapTraceName,
    bool showEveryWaypoint = false,
    Duration debounce = const Duration(milliseconds: 300),
  }) {
    _lastBounds = (minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon);
    _lastActiveGpxNames = activeGpxNames;
    _lastZoom = zoom;
    _lastOsmPoisEnabled = osmPoisEnabled;
    _lastOsmPoiCategoryIds = osmPoiCategoryIds;
    _lastRoadmapTraceName = roadmapTraceName;
    _lastShowEveryWaypoint = showEveryWaypoint;
    _debounce?.cancel();
    _debounce = Timer(debounce, () {
      unawaited(_reload(
        minLat: minLat,
        maxLat: maxLat,
        minLon: minLon,
        maxLon: maxLon,
        activeGpxNames: activeGpxNames,
        zoom: zoom,
        osmPoisEnabled: osmPoisEnabled,
        osmPoiCategoryIds: osmPoiCategoryIds,
        roadmapTraceName: roadmapTraceName,
        showEveryWaypoint: showEveryWaypoint,
      ));
    });
  }

  /// Recharge immediatement (sans debounce) le dernier viewport connu.
  /// A appeler juste apres une ecriture ponctuelle (ex: creation d'un
  /// waypoint depuis la carte) pour que le nouvel element apparaisse sans
  /// attendre que l'utilisateur deplace la carte et redeclenche
  /// [onViewportChanged] lui-meme.
  Future<void> refreshNow() async {
    final b = _lastBounds;
    if (b == null) return;
    await _reload(
      minLat: b.minLat,
      maxLat: b.maxLat,
      minLon: b.minLon,
      maxLon: b.maxLon,
      activeGpxNames: _lastActiveGpxNames,
      zoom: _lastZoom,
      osmPoisEnabled: _lastOsmPoisEnabled,
      osmPoiCategoryIds: _lastOsmPoiCategoryIds,
      roadmapTraceName: _lastRoadmapTraceName,
      showEveryWaypoint: _lastShowEveryWaypoint,
    );
  }

  /// Rechargement immédiat dédié au bouton d'affichage des waypoints (tap
  /// / appui long) : contrairement à [refreshNow], les nouvelles valeurs
  /// sont fournies explicitement plutôt que rejouées depuis le dernier
  /// [onViewportChanged] connu, qui serait sinon périmé tant que la carte
  /// n'a pas rebougé.
  Future<void> reloadWaypointDisplay({
    required String? roadmapTraceName,
    required bool showEveryWaypoint,
  }) async {
    _lastRoadmapTraceName = roadmapTraceName;
    _lastShowEveryWaypoint = showEveryWaypoint;
    final b = _lastBounds;
    if (b == null) return;
    await _reload(
      minLat: b.minLat,
      maxLat: b.maxLat,
      minLon: b.minLon,
      maxLon: b.maxLon,
      activeGpxNames: _lastActiveGpxNames,
      zoom: _lastZoom,
      osmPoisEnabled: _lastOsmPoisEnabled,
      osmPoiCategoryIds: _lastOsmPoiCategoryIds,
      roadmapTraceName: roadmapTraceName,
      showEveryWaypoint: showEveryWaypoint,
    );
  }

  Future<void> _reload({
    required double minLat,
    required double maxLat,
    required double minLon,
    required double maxLon,
    List<String> activeGpxNames = const [],
    double zoom = 15,
    bool osmPoisEnabled = false,
    Set<String> osmPoiCategoryIds = const {},
    String? roadmapTraceName,
    bool showEveryWaypoint = false,
  }) async {
    // 1. Local d'abord, toujours : c'est ce qui garantit l'usage en zone
    // blanche.
    segments.value = await isarService.segmentsInViewport(
      minLat: minLat,
      maxLat: maxLat,
      minLon: minLon,
      maxLon: maxLon,
    );
    pois.value = await isarService.poisInViewport(
      minLat: minLat,
      maxLat: maxLat,
      minLon: minLon,
      maxLon: maxLon,
    );
    // Waypoints -- portée dépendante du contexte (voir doc utilisateur
    // "Affichage des waypoints" / HelpScreen) :
    // - appui long actif (showEveryWaypoint) : tout, sans filtre de trace ;
    // - une trace est chargée en navigation ET toujours affichée : ses
    //   seuls waypoints ;
    // - sinon : les waypoints de toutes les traces actuellement affichées
    //   (aucune si aucune trace n'est affichée).
    final effectiveRoadmapTrace =
        (roadmapTraceName != null && activeGpxNames.contains(roadmapTraceName))
            ? roadmapTraceName
            : null;

    final List<Waypoint> fetchedWaypoints;
    if (showEveryWaypoint) {
      fetchedWaypoints = await isarService.searchWaypoints(
        minLat: minLat,
        maxLat: maxLat,
        minLon: minLon,
        maxLon: maxLon,
      );
    } else if (effectiveRoadmapTrace != null) {
      fetchedWaypoints = await isarService.searchWaypoints(
        minLat: minLat,
        maxLat: maxLat,
        minLon: minLon,
        maxLon: maxLon,
        filterGpxName: effectiveRoadmapTrace,
      );
    } else if (activeGpxNames.isNotEmpty) {
      fetchedWaypoints = await isarService.searchWaypoints(
        minLat: minLat,
        maxLat: maxLat,
        minLon: minLon,
        maxLon: maxLon,
        filterGpxNames: activeGpxNames,
      );
    } else {
      fetchedWaypoints = const [];
    }
    // Isar ne charge pas automatiquement les IsarLinks : sans ce chargement,
    // la fenêtre contextuelle du waypoint (ouverte depuis la carte) ne
    // pourrait jamais présélectionner son type/dossier actuel, et les icônes
    // de catégorie sur la carte (voir `useWaypointCategoryIcons`) resteraient
    // vides -- toujours chargé, indépendamment de ce réglage d'affichage.
    for (final wp in fetchedWaypoints) {
      await wp.category.load();
      await wp.folder.load();
    }
    waypoints.value = fetchedWaypoints;

    // Traces actives
    activeTraces.value = await isarService.tracesByNames(activeGpxNames);

    // Points OSM (opportuniste)
    unawaited(_reloadOsmPois(
      minLat, minLon, maxLat, maxLon, zoom, osmPoisEnabled, osmPoiCategoryIds,
    ));

    // 2. Pull communautaire opportuniste, si un moteur de sync est
    // configure. Les erreurs (hors-ligne, notamment) sont silencieuses
    // ici : la carte reste utilisable avec les seules donnees locales, ce
    // n'est pas une erreur bloquante pour l'utilisateur.
    final engine = syncEngine;
    if (engine == null) return;

    isRefreshingCommunityData.value = true;
    try {
      await engine.pullSegmentsInViewport(
        minLat: minLat,
        maxLat: maxLat,
        minLon: minLon,
        maxLon: maxLon,
      );
      await engine.pullPoisInViewport(
        minLat: minLat,
        maxLat: maxLat,
        minLon: minLon,
        maxLon: maxLon,
      );
      // Recharge locale apres le pull, pour afficher ce qui vient d'etre
      // importe sans dupliquer la logique de fusion des ValueNotifier.
      segments.value = await isarService.segmentsInViewport(
        minLat: minLat,
        maxLat: maxLat,
        minLon: minLon,
        maxLon: maxLon,
      );
      pois.value = await isarService.poisInViewport(
        minLat: minLat,
        maxLat: maxLat,
        minLon: minLon,
        maxLon: maxLon,
      );
    } catch (_) {
      // Silencieux par conception, voir commentaire ci-dessus.
    } finally {
      isRefreshingCommunityData.value = false;
    }
  }

  /// Charge les POI OSM visibles dans le viewport, via le cache par grille
  /// avant tout appel reseau. Gate explicite sur le zoom (au lieu de
  /// l'ancienne heuristique sur la taille de bbox) : au-delà d'un certain
  /// dezoom la requete Overpass deviendrait a la fois trop lourde et peu
  /// lisible sur la carte.
  Future<void> _reloadOsmPois(
    double minLat,
    double minLon,
    double maxLat,
    double maxLon,
    double zoom,
    bool enabled,
    Set<String> categoryIds,
  ) async {
    if (!enabled || categoryIds.isEmpty || zoom < 13) {
      osmPois.value = const [];
      return;
    }

    isLoadingOsmPois.value = true;
    try {
      final cells = OsmPoiCache.cellsInBbox(minLat, minLon, maxLat, maxLon);

      for (final catId in categoryIds) {
        final hasMissingCell =
            cells.any((cell) => !_osmPoiCache.hasCell(cell.$1, cell.$2, catId));
        if (!hasMissingCell) continue;

        // Simplification volontaire : on refetch le bbox visible entier
        // pour cette catégorie plutôt que de calculer précisément le
        // sous-polygone manquant (plus économe en données, nettement plus
        // complexe pour un gain marginal).
        final fetched = await OverpassService.fetchPois(
          minLat: minLat,
          minLon: minLon,
          maxLat: maxLat,
          maxLon: maxLon,
          categoryIds: {catId},
        );
        for (final cell in cells) {
          final inCell = fetched.where((poi) {
            final idx = OsmPoiCache.cellIndex(poi.location.latitude, poi.location.longitude);
            return idx == cell;
          }).toList();
          _osmPoiCache.put(cell.$1, cell.$2, catId, inCell);
        }
      }

      final merged = <String, OsmPoi>{};
      for (final cell in cells) {
        for (final catId in categoryIds) {
          for (final poi in _osmPoiCache.cell(cell.$1, cell.$2, catId)) {
            merged[poi.id] = poi;
          }
        }
      }

      osmPois.value = _deduplicateAgainstSavedWaypoints(merged.values.toList());
    } finally {
      isLoadingOsmPois.value = false;
    }
  }

  /// Exclut de la couche OSM tout POI déjà sauvegardé en tant que Waypoint
  /// (identifié par Waypoint.osmNodeId) -- une fois sauvegardé, il est
  /// affiché par _WaypointsLayer et ne doit plus apparaître en double dans
  /// la couche OSM non sauvegardée.
  List<OsmPoi> _deduplicateAgainstSavedWaypoints(List<OsmPoi> candidates) {
    if (candidates.isEmpty) return candidates;
    final savedOsmIds = waypoints.value
        .where((w) => w.osmNodeId != null)
        .map((w) => w.osmNodeId)
        .toSet();
    return candidates.where((poi) => !savedOsmIds.contains(poi.id)).toList();
  }

  void dispose() {
    _debounce?.cancel();
    segments.dispose();
    pois.dispose();
    isRefreshingCommunityData.dispose();
    isLoadingOsmPois.dispose();
    liveCamera.dispose();
    centerRequest.dispose();
    centerBoundsRequest.dispose();
  }
}
