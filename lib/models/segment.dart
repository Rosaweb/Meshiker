import 'package:isar_community/isar.dart';

import 'enums.dart';
import 'gps_point.dart';
import 'syncable.dart';

part 'segment.g.dart';

/// Un segment est le brin élémentaire de la "toile d'araignée" : un
/// tronçon de sentier (ou de hors-piste) borné par deux intersections,
/// deux points d'intérêt, ou les extrémités d'une trace isolée.
///
/// Un même segment physique peut être partagé par plusieurs [Trace]
/// (celle qui l'a créé, puis celles d'autres utilisateurs après fusion
/// serveur) : c'est pour cela que l'appartenance à une trace, son ordre
/// et son sens de parcours ne vivent PAS ici, mais dans
/// [TraceSegmentEntry], côté [Trace]. Le [Segment] reste neutre,
/// réutilisable et le plus proche possible de la donnée brute.
@collection
class Segment implements Syncable {
  Segment();

  /// Id interne Isar, propre à CET appareil. Ne jamais l'envoyer au
  /// serveur ni s'en servir comme clé de fusion entre utilisateurs :
  /// utiliser [localUuid] pour toute référence externe ou inter-entités.
  Id id = Isar.autoIncrement;

  /// Identifiant stable généré côté client (UUID v4) à la création.
  /// Sert de clé primaire fonctionnelle y compris hors-ligne, et devient
  /// la clé de fusion côté Supabase (colonne `local_uuid`, voir
  /// `schema.sql`). `unique: true, replace: true` permet un simple
  /// `put()` idempotent au lieu d'un upsert manuel.
  @override
  @Index(unique: true, replace: true)
  late String localUuid;

  /// UUID Supabase une fois le segment synchronisé/fusionné côté serveur.
  /// Peut être identique à [localUuid] si cet appareil est le premier à
  /// avoir "gagné" la fusion, ou différent si un segment équivalent
  /// existait déjà et que le serveur a renvoyé son propre identifiant.
  @override
  String? remoteId;

  /// UUID de l'utilisateur qui a enregistré ce segment sur cet appareil
  /// (premier contributeur connu localement ; l'historique complet des
  /// contributeurs vit côté serveur dans `segment_passages`).
  String? authorUuid;

  /// Tracé brut du segment, dans l'ordre d'enregistrement d'origine.
  /// Neutre vis-à-vis du sens de parcours : c'est [TraceSegmentEntry]
  /// (`traveledForward`) qui indique, par trace, si on le lit à
  /// l'endroit ou à l'envers.
  List<PointGPS> points = [];

  /// UUID locaux ([Waypoint.localUuid]) des waypoints tombant sur ce
  /// segment, résolus par [SegmentationEngine] à partir des `<wpt>` GPX
  /// comme s'ils étaient écrits "in-line" parmi les points de la trace.
  /// Référence par UUID (pas d'[IsarLink]) pour rester cohérent avec
  /// [TraceSegmentEntry.segmentUuid] ; le Waypoint référencé reste géré
  /// et personnalisable indépendamment via son propre écran d'édition.
  List<String> waypointUuids = [];

  /// Mode de progression : sentier connu ("routé", affiché aimanté) ou
  /// tracé libre hors-piste.
  @Enumerated(EnumType.ordinal)
  SegmentMode mode = SegmentMode.routed;

  double distanceMeters = 0;
  double elevationGainMeters = 0;
  double elevationLossMeters = 0;

  @Enumerated(EnumType.ordinal)
  DifficultyLevel difficulty = DifficultyLevel.moderate;

  /// Indice de fiabilité communautaire (0.0 à 1.0), calculé côté serveur
  /// à partir du nombre et de la cohérence des passages, puis mis en
  /// cache ici après synchronisation. `null` tant que le segment n'a
  /// jamais été confronté aux données des autres utilisateurs.
  double? reliabilityIndex;

  /// Identifiant unique de la voie OSM si apparié (Map Matching).
  @Index()
  int? osmWayId;

  /// Identifiants des nœuds (OSM ou virtuels) bornant le segment.
  @Index()
  String? startNodeId;
  @Index()
  String? endNodeId;

  /// Indique si le segment est hors du réseau cartographié (fallback).
  @Index()
  bool isOffRoad = false;

  /// Altitude moyenne (m) pour vérification topologique lors de la fusion.
  double avgAltitude = 0;

  /// Nombre cumulé de passages connus (tous utilisateurs confondus après
  /// sync). Vaut au moins 1 hors-ligne (le passage de l'utilisateur
  /// courant, pas encore confronté au serveur).
  int passageCount = 1;

  /// Date du dernier passage connu tous utilisateurs confondus (après
  /// sync) — alimente le code couleur "récence" à l'écran.
  DateTime? lastPassageAt;

  // --- Filtrage géographique local (sans index spatial natif) ---------
  //
  // Isar ne propose pas d'index spatial type R-Tree/PostGIS. On stocke
  // donc l'enveloppe (bounding box) du segment ainsi qu'un préfixe
  // géohash grossier, tous deux indexés, ce qui permet de restreindre
  // très vite les candidats "segments visibles dans ce viewport" avant
  // un éventuel affinage géométrique en Dart. Le calcul géométrique fin
  // (fusion par buffer, intersections) reste déporté sur Supabase/PostGIS
  // pour préserver la batterie (cf. section 4 du brief).
  @Index()
  double minLat = 0;
  @Index()
  double maxLat = 0;
  @Index()
  double minLon = 0;
  @Index()
  double maxLon = 0;

  /// Préfixe géohash (5 caractères ≈ cellules de quelques km) du point de
  /// départ du segment. Index composite pratique pour un pré-filtrage
  /// grossier avant comparaison exacte de bounding box.
  @Index()
  String geohashPrefix = '';

  @override
  @Index()
  @Enumerated(EnumType.ordinal)
  SyncStatus syncStatus = SyncStatus.pending;

  DateTime createdAt = DateTime.now();

  @override
  DateTime updatedAt = DateTime.now();

  @override
  Map<String, dynamic> toSupabaseMap() => {
        'id': remoteId ?? localUuid,
        'local_uuid': localUuid,
        'author_id': authorUuid,
        'mode': mode.name,
        'distance_meters': distanceMeters,
        'elevation_gain_meters': elevationGainMeters,
        'elevation_loss_meters': elevationLossMeters,
        'difficulty': difficulty.name,
        // La géométrie PostGIS (colonne `geom`) est reconstruite côté
        // serveur à partir des points bruts (ST_MakeLine sur les
        // coordonnées), pas calculée en WKT côté client — on reste sur
        // du JSON simple, facilement versionnable et déboguable.
        'points': points
            .map((p) => {
                  'lat': p.latitude,
                  'lon': p.longitude,
                  'alt': p.altitude,
                  'ts': p.timestamp.toIso8601String(),
                })
            .toList(),
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };
}
