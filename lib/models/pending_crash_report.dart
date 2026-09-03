import 'package:isar_community/isar.dart';

import 'enums.dart';

part 'pending_crash_report.g.dart';

/// Rapport de crash Sentry intercepté via `beforeSend` et différé pour un
/// compte premium (spec-crash-reporting.md §5.2/§6) : l'envoi automatique
/// est annulé, l'event est sérialisé ici, et attend `launchesRemaining`
/// cold starts (ou une action utilisateur explicite) avant d'être
/// effectivement transmis à Sentry via `CrashReportingService`.
///
/// N'existe QUE pour les utilisateurs premium — le flux non-premium passe
/// directement par le cache/retry interne du SDK Sentry, sans jamais
/// peupler cette collection.
@collection
class PendingCrashReport {
  Id id = Isar.autoIncrement;

  /// `eventId` généré par le SDK Sentry au moment de la capture (avant même
  /// toute tentative de transmission réseau) — réutilisé tel quel pour le
  /// renvoi manuel/auto et pour `SentryFeedback.associatedEventId`.
  @Index(unique: true, replace: true)
  late String eventId;

  /// Payload JSON complet de l'event (`SentryEvent.toJson()`), pour
  /// reconstruction (`SentryEvent.fromJson`) au moment du renvoi.
  late String serializedEventJson;

  /// Clé de dédoublonnage locale (type d'exception + frame applicatif de
  /// tête) — voir spec §7. Indépendante du fingerprint serveur de Sentry.
  @Index()
  late String fingerprint;

  int occurrenceCount = 1;

  late DateTime firstOccurredAt;
  late DateTime lastOccurredAt;

  /// Décrémenté une fois par cold start réel ; renvoi automatique à zéro.
  /// N'est PAS réinitialisé sur une occurrence répétée (spec §7), pour
  /// qu'un crash très fréquent ne repousse jamais indéfiniment son propre
  /// envoi.
  int launchesRemaining = 3;

  /// Message libre saisi par l'utilisateur dans l'écran "Rapport de bug",
  /// autosauvegardé en brouillon.
  String? draftUserMessage;

  @Enumerated(EnumType.ordinal)
  CrashReportStatus status = CrashReportStatus.pending;

  /// Type d'exception, pour l'affichage liste/détail sans désérialiser le
  /// JSON complet à chaque frame de build.
  String? exceptionType;
}
