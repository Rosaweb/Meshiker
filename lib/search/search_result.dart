/// Type de document renvoye par une recherche.
enum SearchDocType { trace, pointOfInterest, waypoint }

/// Un resultat de recherche, pret a afficher dans une liste (titre,
/// sous-titre, score) sans que l'UI ait besoin de connaitre le detail du
/// moteur d'indexation.
class SearchResult {
  const SearchResult({
    required this.docType,
    required this.uuid,
    required this.title,
    required this.score,
    this.subtitle,
  });

  final SearchDocType docType;

  /// UUID local de l'entite trouvee (Trace.localUuid, PointOfInterest.localUuid
  /// ou Waypoint.localUuid selon [docType]).
  final String uuid;

  final String title;
  final String? subtitle;

  /// Score de pertinence (voir TrigramIndex), utile pour trier ou pour
  /// debugger la qualite du matching, pas destine a etre affiche tel quel
  /// a l'utilisateur.
  final double score;
}
