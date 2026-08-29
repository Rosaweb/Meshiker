import 'dart:math' as math;

/// Moteur pur (aucune dépendance Isar/TTS/Flutter) qui décide, pour un
/// waypoint et une distance déjà calculée, si une annonce vocale doit être
/// déclenchée et avec quel texte. Utilisé pour les deux contextes
/// indépendants (waypoint manager, roadmap) — cf. spec-assistant-vocal-ia.md §2
/// et UI-annonce-waypoints.txt. Aucun appel réseau, aucune IA : purement
/// déterministe, testable sans Flutter ni base de données.

/// État "déjà annoncé" d'un waypoint, suivi indépendamment par déclencheur
/// (§2.5) pour que le déclenchement de l'un ne désactive pas l'autre.
class AnnouncementTriggerState {
  final bool distanceAnnounced;
  final bool onSpotAnnounced;

  const AnnouncementTriggerState({
    this.distanceAnnounced = false,
    this.onSpotAnnounced = false,
  });

  bool get isFullyAnnounced => distanceAnnounced && onSpotAnnounced;
}

/// Réglages d'annonce pour un contexte donné (waypoint manager ou roadmap) —
/// mêmes champs dans les deux cas, cf. SettingsService.
class AnnouncementSettings {
  final bool onApproachEnabled;
  final bool onSpotEnabled;
  final double approachDistanceMeters;
  final bool announceTitle;
  final bool announceType;
  final bool announceDescription;

  const AnnouncementSettings({
    required this.onApproachEnabled,
    required this.onSpotEnabled,
    required this.approachDistanceMeters,
    required this.announceTitle,
    required this.announceType,
    required this.announceDescription,
  });
}

/// Waypoint candidat minimal nécessaire au moteur — découplé du modèle Isar
/// (le type et la description sont déjà résolus par l'appelant) pour rester
/// pur et testable sans base de données.
class AnnouncementWaypoint {
  final String localUuid;
  final String name;
  final String? typeName;
  final String? description;

  const AnnouncementWaypoint({
    required this.localUuid,
    required this.name,
    this.typeName,
    this.description,
  });
}

class AnnouncementEvent {
  final String waypointLocalUuid;
  final String phrase;

  const AnnouncementEvent(this.waypointLocalUuid, this.phrase);
}

class AnnouncementResult {
  final AnnouncementEvent event;
  final AnnouncementTriggerState state;

  const AnnouncementResult(this.event, this.state);
}

class WaypointAnnouncementEngine {
  WaypointAnnouncementEngine._();

  /// Rayon "sur place" de base (§2.5 : ~15-20m à valider empiriquement sur le
  /// terrain, on retient 20m), élargi dynamiquement à la précision GPS
  /// rapportée si celle-ci est pire — évite un seuil trop serré face à
  /// l'erreur GPS réelle en forêt/relief.
  static const double onSpotBaseRadiusMeters = 20.0;

  /// Troncature de sécurité de la description (§2.7) : uniquement au-delà
  /// d'un seuil généreux, jamais en plein milieu d'un mot.
  static const int descriptionTruncateLimit = 500;

  /// Anticipation de l'annonce d'approche, en secondes de marche à la
  /// vitesse courante. Compense le décalage, mesuré sur le terrain, entre
  /// le franchissement réel du seuil et l'annonce perçue par l'utilisateur
  /// (intervalle de rafraîchissement GPS + traitement + démarrage du moteur
  /// TTS) : sans compensation, l'annonce arrivait ~10m plus tard que prévu
  /// à l'allure de marche (~1,1 m/s, soit ~9s de décalage). Valeur à
  /// affiner par d'autres tests terrain si besoin.
  static const double approachLookaheadSeconds = 3.0;

  /// Évalue si une annonce doit être déclenchée pour [waypoint], situé à
  /// [distanceMeters] de la position actuelle (précision GPS
  /// [accuracyMeters], vitesse [speedMps]), selon [settings] et l'état déjà
  /// connu ([state]) pour ce waypoint. Retourne `null` si rien à annoncer.
  static AnnouncementResult? evaluate({
    required AnnouncementWaypoint waypoint,
    required double distanceMeters,
    required double accuracyMeters,
    required double speedMps,
    required AnnouncementSettings settings,
    required AnnouncementTriggerState state,
  }) {
    if (state.isFullyAnnounced) return null;
    if (!settings.onApproachEnabled && !settings.onSpotEnabled) return null;

    final onSpotRadius = math.max(onSpotBaseRadiusMeters, accuracyMeters);

    // Distance "effective" utilisée pour le déclencheur d'approche : on
    // retranche la distance parcourue pendant le délai de restitution
    // estimé, pour que l'annonce soit perçue au bon endroit plutôt qu'en
    // retard. Le déclencheur "sur place" n'utilise jamais cette
    // anticipation (voir plus bas).
    final effectiveApproachDistanceMeters =
        distanceMeters - (speedMps * approachLookaheadSeconds);

    // Signal GPS trop imprécis pour distinguer les deux anneaux (UI spec
    // point 3) : une seule annonce, phrasée comme une arrivée, avec la
    // mention du signal approximatif — les deux déclencheurs sont marqués
    // faits pour ne plus jamais se déclencher séparément sur ce waypoint.
    final ringsIndistinguishable = settings.onApproachEnabled &&
        settings.onSpotEnabled &&
        accuracyMeters >= (settings.approachDistanceMeters - onSpotRadius);

    if (ringsIndistinguishable) {
      if (state.distanceAnnounced || state.onSpotAnnounced) return null;
      if (effectiveApproachDistanceMeters > settings.approachDistanceMeters) return null;
      final phrase = '${_arrivalPhrase(waypoint, settings)} Signal GPS approximatif.';
      return AnnouncementResult(
        AnnouncementEvent(waypoint.localUuid, phrase),
        const AnnouncementTriggerState(distanceAnnounced: true, onSpotAnnounced: true),
      );
    }

    // Basé sur la distance réelle, sans anticipation : annoncer une
    // arrivée avant d'être effectivement arrivé serait trompeur,
    // contrairement à l'annonce d'approche qui est par nature anticipée.
    if (settings.onSpotEnabled && !state.onSpotAnnounced && distanceMeters <= onSpotRadius) {
      return AnnouncementResult(
        AnnouncementEvent(waypoint.localUuid, _arrivalPhrase(waypoint, settings)),
        AnnouncementTriggerState(distanceAnnounced: state.distanceAnnounced, onSpotAnnounced: true),
      );
    }

    if (settings.onApproachEnabled &&
        !state.distanceAnnounced &&
        effectiveApproachDistanceMeters <= settings.approachDistanceMeters) {
      return AnnouncementResult(
        AnnouncementEvent(waypoint.localUuid, _approachPhrase(waypoint, settings)),
        AnnouncementTriggerState(distanceAnnounced: true, onSpotAnnounced: state.onSpotAnnounced),
      );
    }

    return null;
  }

  static String _approachPhrase(AnnouncementWaypoint wp, AnnouncementSettings s) {
    final leadIn = 'Dans ${s.approachDistanceMeters.round()} mètres';
    final content = _content(wp, s);
    return content.isEmpty ? '$leadIn.' : '$leadIn : $content.';
  }

  static String _arrivalPhrase(AnnouncementWaypoint wp, AnnouncementSettings s) {
    const leadIn = 'Vous êtes arrivé';
    final content = _content(wp, s);
    return content.isEmpty ? '$leadIn.' : '$leadIn : $content.';
  }

  /// Compose le contenu de l'annonce dans l'ordre titre → type →
  /// description, chaque bloc activable indépendamment (§2.6).
  static String _content(AnnouncementWaypoint wp, AnnouncementSettings s) {
    final parts = <String>[];
    if (s.announceTitle && wp.name.trim().isNotEmpty) parts.add(wp.name.trim());
    if (s.announceType && (wp.typeName?.trim().isNotEmpty ?? false)) {
      parts.add(wp.typeName!.trim());
    }
    if (s.announceDescription && (wp.description?.trim().isNotEmpty ?? false)) {
      parts.add(truncateDescription(wp.description!.trim()));
    }
    return parts.join(', ');
  }

  /// Coupe [description] au dernier espace avant [descriptionTruncateLimit],
  /// jamais en plein milieu d'un mot (§2.7). Ne fait rien en-dessous du
  /// seuil.
  static String truncateDescription(String description) {
    if (description.length <= descriptionTruncateLimit) return description;
    final cut = description.substring(0, descriptionTruncateLimit);
    final lastSpace = cut.lastIndexOf(RegExp(r'\s'));
    final trimmed = lastSpace > 0 ? cut.substring(0, lastSpace) : cut;
    return '$trimmed…';
  }
}
