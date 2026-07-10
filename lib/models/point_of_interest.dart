import 'package:isar_community/isar.dart';

import 'enums.dart';
import 'gps_point.dart';
import 'syncable.dart';

part 'point_of_interest.g.dart';

/// Un point d'intérêt (sommet, source, refuge, parking, danger...), qu'il
/// provienne des waypoints (`<wpt>`) d'un fichier GPX importé ou d'un
/// ajout manuel par l'utilisateur.
///
/// Joue un double rôle dans l'étape 2 :
/// - point de coupure potentiel pour [SegmentationEngine] (un segment
///   s'arrête/démarre à un POI majeur) ;
/// - document indexé par [LocalSearchEngine] pour la recherche floue.
@collection
class PointOfInterest implements Syncable {
  PointOfInterest();

  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String localUuid;

  @override
  String? remoteId;

  String name = '';
  String? description;

  @Enumerated(EnumType.ordinal)
  POIType type = POIType.other;

  /// Localisation complète du POI (avec altitude si connue). Un POI est
  /// un point unique, pas un tracé : pas de liste ici, contrairement à
  /// [Segment.points].
  late PointGPS location;

  // Dupliqués en champs scalaires indexés séparément de [location] : Isar
  // ne permet pas d'indexer directement les propriétés d'un objet
  // `@embedded` unique pour des requêtes de plage (min/max) au niveau de
  // la collection — même choix déjà fait pour la bounding box de
  // [Segment].
  @Index()
  double latitude = 0;
  @Index()
  double longitude = 0;

  @Index()
  String geohashPrefix = '';

  /// Nombre de fois où ce POI a été retrouvé/référencé lors d'imports GPX
  /// successifs (dédoublonnage local, voir `SegmentationEngine._resolvePoi`).
  /// Ne remplace pas un vrai compteur de fréquentation communautaire, qui
  /// restera calculé côté serveur une fois la synchronisation active.
  int timesReferenced = 1;

  /// UUID de l'utilisateur ayant importé/créé ce POI sur cet appareil.
  String? authorUuid;

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
        'name': name,
        'description': description,
        'type': type.name,
        'latitude': latitude,
        'longitude': longitude,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };
}
