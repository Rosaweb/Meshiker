import 'package:isar_community/isar.dart';
import 'enums.dart';

part 'roadbook.g.dart';

/// Carnet de route (spec-galerie-photos-carnet-de-route.md Partie 2).
///
/// Entité DISTINCTE du [Waypoint] : le carnet travaille au grain de la photo
/// individuelle (une légende par photo, éditable indépendamment), là où un
/// waypoint ne porte qu'un seul nom/description pour tout son `photoPaths`.
/// L'édition dans le carnet n'affecte jamais le waypoint ni la photo
/// d'origine : `caption`/`description` des blocs sont des COPIES figées à la
/// génération, pas des références vivantes (§2.1).
@collection
class Roadbook {
  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String localUuid;

  late String title;

  /// Trace d'origine. Un seul carnet de route par trace (index unique) ;
  /// jamais null — un `Roadbook` n'existe que rattaché à une trace, pas au
  /// groupe "indépendants" de la galerie (§2.1).
  @Index(unique: true)
  late String associatedGpxName;

  /// Contenu ordonné du carnet — l'ordre de la liste EST l'ordre
  /// d'affichage. Blocs photo et blocs texte libre mélangés.
  List<RoadbookBlock> blocks = [];

  @enumerated
  SyncStatus syncStatus = SyncStatus.pending;

  DateTime createdAt = DateTime.now();
  DateTime updatedAt = DateTime.now();
}

@embedded
class RoadbookBlock {
  @enumerated
  RoadbookBlockType type = RoadbookBlockType.photo;

  // --- Bloc photo ---
  /// Copie du chemin au moment de la création du bloc.
  String? photoPath;

  /// Waypoint d'origine — traçabilité seulement, pas de lien vivant.
  String? sourceWaypointUuid;

  /// Titre de la légende. Éditable, vidable indépendamment de [description].
  String? caption;

  /// Description de la légende. Éditable, vidable indépendamment de [caption].
  String? description;

  // --- Bloc texte libre (si type == RoadbookBlockType.text) ---
  String? textContent;
}

enum RoadbookBlockType { photo, text }
