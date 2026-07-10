/// Résultat d'une synchronisation (push et/ou pull). Les différentes
/// étapes de `SyncEngine` renvoient chacune un `SyncSummary` partiel,
/// combinables via l'opérateur `+` pour obtenir un résumé global à
/// afficher ou logger ("12 segments envoyés, 3 fusionnés côté serveur,
/// 2 erreurs").
class SyncSummary {
  const SyncSummary({
    this.segmentsPushed = 0,
    this.segmentsMerged = 0,
    this.segmentsRefreshed = 0,
    this.poisPushed = 0,
    this.poisMerged = 0,
    this.tracesPushed = 0,
    this.segmentsPulled = 0,
    this.poisPulled = 0,
    this.errors = const [],
  });

  final int segmentsPushed;

  /// Parmi les segments poussés, combien ont été fusionnés avec un
  /// segment déjà existant côté serveur plutôt que créés en tant que
  /// nouveau segment canonique.
  final int segmentsMerged;

  /// Segments déjà connus localement dont les agrégats communautaires
  /// (fiabilité, fréquentation) ont été rafraîchis depuis le serveur.
  final int segmentsRefreshed;

  final int poisPushed;
  final int poisMerged;
  final int tracesPushed;

  /// Segments/POI découverts côté serveur (contribués par d'autres
  /// utilisateurs) et importés localement pour la première fois.
  final int segmentsPulled;
  final int poisPulled;

  /// Messages d'erreur lisibles (pas de trace technique brute) — à
  /// afficher tels quels ou à journaliser selon le contexte applicatif.
  final List<String> errors;

  bool get hasErrors => errors.isNotEmpty;

  SyncSummary operator +(SyncSummary other) => SyncSummary(
        segmentsPushed: segmentsPushed + other.segmentsPushed,
        segmentsMerged: segmentsMerged + other.segmentsMerged,
        segmentsRefreshed: segmentsRefreshed + other.segmentsRefreshed,
        poisPushed: poisPushed + other.poisPushed,
        poisMerged: poisMerged + other.poisMerged,
        tracesPushed: tracesPushed + other.tracesPushed,
        segmentsPulled: segmentsPulled + other.segmentsPulled,
        poisPulled: poisPulled + other.poisPulled,
        errors: [...errors, ...other.errors],
      );

  @override
  String toString() =>
      'SyncSummary(segments: +$segmentsPushed poussés ($segmentsMerged fusionnés, '
      '$segmentsRefreshed rafraîchis) / $segmentsPulled reçus, '
      'POI: +$poisPushed poussés ($poisMerged fusionnés) / $poisPulled reçus, '
      'traces: +$tracesPushed, erreurs: ${errors.length})';
}
