import 'enums.dart';

/// Contrat commun implémenté par toutes les entités destinées à être
/// synchronisées avec Supabase (`Segment`, `Trace`, `Utilisateur`).
///
/// Volontairement dépourvu de toute annotation Isar : il ne sert qu'à
/// écrire, plus tard, du code de synchronisation générique (« pousser
/// toutes les entités `pending` », « marquer comme `synced` après
/// confirmation »...) sans dépendre du type concret de chaque entité.
///
/// Comme les champs `localUuid`, `remoteId`, `syncStatus` et `updatedAt`
/// existent déjà, tels quels, sur chaque classe qui l'implémente, Dart
/// considère l'interface satisfaite automatiquement — aucune duplication
/// de code n'est nécessaire.
abstract interface class Syncable {
  /// Identifiant stable généré côté client (UUID v4) à la création.
  /// Reste valide même hors-ligne et devient la clé de fusion côté serveur.
  String get localUuid;

  /// Identifiant Supabase une fois l'entité synchronisée. `null` tant que
  /// l'entité n'a jamais atteint le serveur.
  String? get remoteId;

  /// État courant de synchronisation (voir [SyncStatus]).
  SyncStatus get syncStatus;

  /// Date de dernière modification locale, utilisée pour détecter les
  /// conflits (comparaison avec `updated_at` côté serveur).
  DateTime get updatedAt;

  /// Sérialise l'entité vers le format attendu par la table Supabase
  /// correspondante. Volontairement laissé abstrait ici : chaque entité
  /// connaît sa propre table et ses propres noms de colonnes (voir
  /// `supabase/schema.sql`).
  Map<String, dynamic> toSupabaseMap();
}
