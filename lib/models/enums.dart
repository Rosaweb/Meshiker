/// Mode de progression d'un [Segment] : sur sentier connu/balisé ("routé",
/// affiché aimanté sur la carte) ou hors-piste (ligne libre reliant les
/// points GPS bruts). C'est cet attribut qui permet à une [Trace]
/// d'alterner librement entre portions routées et portions libres.
enum SegmentMode {
  routed,
  offPath,
}

/// État de traitement d'une trace (Segmentation / Mesh)
enum TraceProcessingStatus {
  /// En attente de traitement lourd
  pending,

  /// En cours de segmentation (Valhalla, etc.)
  processing,

  /// Prête (segments créés et liés)
  ready,

  /// Erreur lors du traitement
  error,
}

/// État de synchronisation d'une entité par rapport à Supabase.
///
/// Sert de file d'attente pour le futur moteur de synchronisation : on ne
/// fait JAMAIS d'appel réseau pendant l'enregistrement GPS (contrainte
/// batterie), on marque juste les entités "pending" localement, et un
/// worker de fond les pousse plus tard, quand le réseau est disponible et
/// que l'enregistrement n'est pas actif.
enum SyncStatus {
  /// Créée ou modifiée localement, jamais encore envoyée au serveur.
  pending,

  /// Poussée et confirmée par Supabase, aucune modification locale en attente.
  synced,

  /// Poussée mais en conflit avec une version serveur plus récente
  /// (ex : le segment a été fusionné entre-temps avec celui d'un autre
  /// utilisateur). À arbitrer par le moteur de sync, pas ici.
  conflict,

  /// Une tentative de synchronisation a échoué (réseau, validation...).
  error,
}

/// Visibilité d'une trace vis-à-vis de la communauté.
enum TraceVisibility {
  private,
  friendsOnly,
  public,
}

/// Type d'activité. Utile pour le filtrage et le typage visuel des traces
/// (une trace de raquette n'a pas le même code couleur qu'un trail).
enum ActivityType {
  hiking,
  trailRunning,
  bikepacking,
  snowshoeing,
  climbing,
  other,
}

/// Difficulté normalisée d'un segment, calculée localement à partir de la
/// pente/distance à la création, puis potentiellement affinée côté serveur
/// à partir des retours communautaires.
enum DifficultyLevel {
  easy,
  moderate,
  difficult,
  veryDifficult,
  expert,
}

/// Catégorie d'un [PointOfInterest]. Alimentée soit par une classification
/// best-effort des waypoints GPX importés (voir
/// `SegmentationEngine._classifyPoiType`), soit par un choix explicite de
/// l'utilisateur lors d'un ajout manuel.
enum POIType {
  summit,
  viewpoint,
  waterSource,
  campsite,
  shelter,
  parking,
  junction,
  danger,
  other,
}

/// État d'un [PendingCrashReport] dans la file d'attente locale (rapports
/// de crash différés, réservés aux comptes premium — voir
/// spec-crash-reporting.md §5.2/§6).
enum CrashReportStatus {
  /// En attente d'envoi automatique (compte à rebours en cours) ou de
  /// décision utilisateur (envoi manuel / suppression).
  pending,

  /// Envoyé à Sentry (auto après N lancements, ou manuellement).
  sent,

  /// Supprimé par l'utilisateur sans envoi.
  deleted,
}
