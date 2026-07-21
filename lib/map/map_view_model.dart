import 'dart:async';

import 'package:flutter/foundation.dart';

import '../database/isar_service.dart';
import '../models/point_of_interest.dart';
import '../models/segment.dart';
import '../models/waypoint.dart';
import '../models/trace.dart';
import '../sync/sync_engine.dart';
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

  Timer? _debounce;

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
    waypoints.value = await isarService.searchWaypoints(
      minLat: minLat,
      maxLat: maxLat,
      minLon: minLon,
      maxLon: maxLon,
    );

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

  Future<void> _reloadOsmPois(double minLat, double minLon, double maxLat, double maxLon) async {
    // On ne fetch que si on est à un niveau de zoom suffisant pour éviter les requêtes trop larges
    // Cette info n'est pas directement ici, on pourrait passer le zoom ou checker la taille de la bbox
    if ((maxLat - minLat).abs() > 0.5) return; 

    final fetched = await OverpassService.fetchPois(minLat, minLon, maxLat, maxLon);
    osmPois.value = fetched;
  }

  void dispose() {
    _debounce?.cancel();
    segments.dispose();
    pois.dispose();
    isRefreshingCommunityData.dispose();
  }
}
