import 'dart:async';

import 'package:flutter/foundation.dart';

import '../database/isar_service.dart';
import '../models/point_of_interest.dart';
import '../models/segment.dart';
import '../models/waypoint.dart';
import '../models/trace.dart';
import '../sync/sync_engine.dart';
import '../utils/geo_utils.dart';
import '../utils/overpass_service.dart';

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
    Duration debounce = const Duration(milliseconds: 300),
  }) {
    _lastBounds = (minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon);
    _lastActiveGpxNames = activeGpxNames;
    _debounce?.cancel();
    _debounce = Timer(debounce, () {
      unawaited(_reload(
        minLat: minLat,
        maxLat: maxLat,
        minLon: minLon,
        maxLon: maxLon,
        activeGpxNames: activeGpxNames,
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
    );
  }

  Future<void> _reload({
    required double minLat,
    required double maxLat,
    required double minLon,
    required double maxLon,
    List<String> activeGpxNames = const [],
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
    
    // Nouveaux waypoints
    final fetchedWaypoints = await isarService.searchWaypoints(
      minLat: minLat,
      maxLat: maxLat,
      minLon: minLon,
      maxLon: maxLon,
    );
    // Isar ne charge pas automatiquement les IsarLinks : sans ce chargement,
    // la fenêtre contextuelle du waypoint (ouverte depuis la carte) ne
    // pourrait jamais présélectionner son type/dossier actuel.
    for (final wp in fetchedWaypoints) {
      await wp.category.load();
      await wp.folder.load();
    }
    waypoints.value = fetchedWaypoints;

    // Traces actives
    activeTraces.value = await isarService.tracesByNames(activeGpxNames);

    // Points OSM (opportuniste)
    _reloadOsmPois(minLat, minLon, maxLat, maxLon);

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

  /// Distance en dessous de laquelle un POI OSM est considéré comme "le
  /// même point" qu'un waypoint local déjà enregistré (ex : un waypoint
  /// créé sur une source ou un refuge déjà répertorié dans OSM).
  static const double _osmDedupThresholdMeters = 25.0;

  Future<void> _reloadOsmPois(double minLat, double minLon, double maxLat, double maxLon) async {
    // On ne fetch que si on est à un niveau de zoom suffisant pour éviter les requêtes trop larges
    // Cette info n'est pas directement ici, on pourrait passer le zoom ou checker la taille de la bbox
    if ((maxLat - minLat).abs() > 0.5) return;

    final fetched = await OverpassService.fetchPois(minLat, minLon, maxLat, maxLon);

    // On exclut les POI OSM qui coïncident avec un waypoint local existant :
    // sinon deux marqueurs se superposent au même endroit et celui du POI
    // OSM (dessiné par-dessus, voir _OsmPoisLayer dans map_screen.dart)
    // intercepte les taps destinés au vrai waypoint, ouvrant par erreur la
    // création d'un doublon au lieu de l'édition du waypoint existant.
    final localWaypoints = waypoints.value;
    osmPois.value = fetched.where((poi) {
      return localWaypoints.every((wp) => GeoUtils.haversineMeters(
            poi.location.latitude,
            poi.location.longitude,
            wp.latitude,
            wp.longitude,
          ) > _osmDedupThresholdMeters);
    }).toList();
  }

  void dispose() {
    _debounce?.cancel();
    segments.dispose();
    pois.dispose();
    isRefreshingCommunityData.dispose();
    liveCamera.dispose();
    centerRequest.dispose();
    centerBoundsRequest.dispose();
  }
}
