import 'package:isar_community/isar.dart';
import 'enums.dart';

part 'waypoint.g.dart';

@collection
class WaypointCategory {
  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String localUuid;

  late String name;
  late String iconName; // Identifiant de l'icône (ex: "water_drop")
  late int colorHex;    // Stockage de la couleur en format 0xFF...

  // Référence à OsmPoiCategoryDef.id (lib/map/osm_poi_categories.dart) si
  // cette catégorie correspond à un type OSM connu ; null pour une
  // catégorie créée librement par l'utilisateur.
  String? osmCategoryId;

  DateTime createdAt = DateTime.now();
  DateTime updatedAt = DateTime.now();

  // Lien inverse vers les waypoints (optionnel, utile pour compter les points par catégorie)
  // @Backlink('category')
  // final waypoints = IsarLinks<Waypoint>();
}

@collection
class WaypointFolder {
  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String localUuid;

  late String name;
  
  DateTime createdAt = DateTime.now();
  DateTime updatedAt = DateTime.now();

  // @Backlink('folder')
  // final waypoints = IsarLinks<Waypoint>();
}

@collection
class Waypoint {
  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String localUuid;

  late String name;
  String? description;
  late double latitude;
  late double longitude;

  int? colorHex; // Couleur spécifique optionnelle
  String? associatedGpxName; // Nom du fichier GPX associé
  String? osmNodeId; // Renseigné uniquement si ce waypoint vient d'un import OSM

  // Stockage des chemins locaux des photos
  List<String> photoPaths = [];
  int headerPhotoIndex = 0; // Index de la photo d'entête

  /// true si ce waypoint a été créé via le bouton photo du bandeau de menu
  /// principal (plutôt que par appui long sur la carte). Détermine le
  /// masquage par défaut sur la carte et l'exclusion des listes / compteurs /
  /// exports / annonces par défaut (spec-photos-geolocalisees.md §2.1, §8).
  /// Champ structurel, indépendant de `category` : ne doit jamais être déduit
  /// d'une WaypointCategory, qui reste éditable / supprimable par
  /// l'utilisateur. Migration Isar : nouveau champ, défaut `false`, les
  /// waypoints existants restent `false` sans migration de données.
  bool isPhotoWaypoint = false;

  // Relations
  final category = IsarLink<WaypointCategory>();
  final folder = IsarLink<WaypointFolder>();

  // Metadata pour la synchro
  @enumerated
  SyncStatus syncStatus = SyncStatus.pending;

  DateTime createdAt = DateTime.now();
  DateTime updatedAt = DateTime.now();
}
