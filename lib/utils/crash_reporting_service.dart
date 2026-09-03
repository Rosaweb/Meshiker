import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../database/isar_service.dart';
import '../models/enums.dart';
import '../models/pending_crash_report.dart';
import 'settings_service.dart';

/// Met en œuvre spec-crash-reporting.md : initialisation Sentry, scrubbing
/// PII, et routage premium (flux différé/éditable, `PendingCrashReport`)
/// vs. non-premium (comportement par défaut du SDK, aucune interception).
///
/// Ne touche jamais `isar.pendingCrashReports` directement : passe toujours
/// par `IsarService`, seule classe autorisée à parler à Isar (cf. CLAUDE.md).
class CrashReportingService {
  CrashReportingService._();

  /// Clé utilisée pour marquer un event qui repasse par `beforeSend` suite à
  /// un renvoi (auto ou manuel) : sans elle, `beforeSend` re-routerait
  /// indéfiniment son propre renvoi vers la file d'attente premium au lieu
  /// de le laisser réellement partir (spec §5.2, note technique).
  static const _resendHintKey = 'meshiker_resend';

  static const _defaultLaunchesRemaining = 3;

  /// DSN fourni via `--dart-define-from-file=env.json` (clé `SENTRY_DSN`),
  /// comme les autres identifiants de service externes du projet (voir
  /// `SupabaseBootstrapService`). Une valeur vide désactive silencieusement
  /// Sentry (utile en développement sans organisation Sentry configurée).
  static const _dsn = String.fromEnvironment('SENTRY_DSN');

  /// À appeler une fois au démarrage, APRÈS `SettingsService.init()` (le
  /// toggle doit être connu avant d'initialiser le SDK, spec §3.1) et avant
  /// que d'autres erreurs de démarrage puissent survenir. Non-fatal si
  /// l'initialisation échoue : le reste de l'app doit démarrer quoi qu'il
  /// arrive (principe "zone blanche").
  static Future<void> init({
    required SettingsService settings,
    required IsarService isarService,
  }) async {
    if (!settings.crashReportingEnabled || _dsn.isEmpty) return;

    try {
      await SentryFlutter.init((options) {
        options.dsn = _dsn;
        // Comportement par défaut déjà `false`, explicité ici pour
        // documenter l'intention (spec §3.2) : pas d'IP, pas de device info
        // étendu au-delà du nécessaire au diagnostic.
        options.sendDefaultPii = false;
        options.beforeSend = (event, hint) => _beforeSend(
              event,
              hint,
              settings: settings,
              isarService: isarService,
            );
      });
    } catch (e) {
      debugPrint('CrashReportingService: init error: $e');
    }
  }

  static Future<SentryEvent?> _beforeSend(
    SentryEvent event,
    Hint hint, {
    required SettingsService settings,
    required IsarService isarService,
  }) async {
    // Renvoi (auto après N lancements, ou manuel) : ne pas re-router vers la
    // file d'attente, laisser l'event partir normalement.
    if (hint.get(_resendHintKey) == true) {
      return scrubPii(event);
    }

    final scrubbed = scrubPii(event);

    if (!settings.crashReportingEnabled) return null;

    // Non-premium (ou statut premium pas encore résolu au moment du crash,
    // cf. SettingsService.lastKnownPremiumStatus) : comportement par défaut
    // du SDK, aucune interception (spec §5.1).
    if (!settings.lastKnownPremiumStatus) return scrubbed;

    try {
      await _routeToPendingQueue(scrubbed, isarService);
    } catch (e) {
      // En cas d'échec de la persistance locale (Isar plein, etc.), on
      // laisse l'event partir immédiatement plutôt que de le perdre
      // silencieusement.
      debugPrint('CrashReportingService: failed to queue report locally: $e');
      return scrubbed;
    }
    return null; // Annule l'envoi automatique (spec §5.2 étape 1).
  }

  /// Retire les données de position précises des events, tous flux
  /// confondus (spec §3.2) — omission complète, pas d'arrondi. Couvre
  /// `extra`, `tags` et les breadcrumbs (message + data) : les trois
  /// canaux explicitement cités par la spec. Un audit exhaustif de tous les
  /// points de logging custom du code (spec §12.2) reste un travail séparé
  /// — ce filtrage par heuristique de nom de clé est un filet de sécurité,
  /// pas un substitut à cet audit.
  @visibleForTesting
  static SentryEvent scrubPii(SentryEvent event) {
    // ignore: deprecated_member_use
    final extra = event.extra;
    if (extra != null && extra.isNotEmpty) {
      extra.removeWhere((key, _) => _looksLikePositionKey(key));
    }

    final tags = event.tags;
    if (tags != null && tags.isNotEmpty) {
      tags.removeWhere((key, _) => _looksLikePositionKey(key));
    }

    final breadcrumbs = event.breadcrumbs;
    if (breadcrumbs != null && breadcrumbs.isNotEmpty) {
      breadcrumbs.removeWhere(_breadcrumbLooksLikePosition);
    }

    return event;
  }

  static bool _breadcrumbLooksLikePosition(Breadcrumb breadcrumb) {
    if (_looksLikePositionText(breadcrumb.message)) return true;
    final data = breadcrumb.data;
    if (data == null) return false;
    return data.keys.any(_looksLikePositionKey);
  }

  static bool _looksLikePositionText(String? text) {
    if (text == null) return false;
    return _looksLikePositionKey(text);
  }

  static bool _looksLikePositionKey(String key) {
    final k = key.toLowerCase();
    return k.contains('lat') ||
        k.contains('lon') ||
        k.contains('lng') ||
        k.contains('position') ||
        k.contains('coordinate') ||
        k.contains('gps');
  }

  static Future<void> _routeToPendingQueue(
      SentryEvent event, IsarService isarService) async {
    final fingerprint = computeFingerprint(event);
    final now = DateTime.now();
    final existing =
        await isarService.pendingCrashReportByFingerprint(fingerprint);

    if (existing != null) {
      existing.occurrenceCount += 1;
      existing.lastOccurredAt = now;
      // launchesRemaining volontairement inchangé (spec §7) : un crash
      // fréquent ne doit pas repousser indéfiniment son propre envoi.
      await isarService.savePendingCrashReport(existing);
      return;
    }

    final report = PendingCrashReport()
      ..eventId = event.eventId.toString()
      ..serializedEventJson = jsonEncode(event.toJson())
      ..fingerprint = fingerprint
      ..occurrenceCount = 1
      ..firstOccurredAt = now
      ..lastOccurredAt = now
      ..launchesRemaining = _defaultLaunchesRemaining
      ..status = CrashReportStatus.pending
      ..exceptionType = event.exceptions?.firstOrNull?.type;
    await isarService.savePendingCrashReport(report);
  }

  /// Type d'exception + fichier/ligne du premier frame applicatif (hors
  /// framework/dépendances) — spec §7. Les frames Sentry sont ordonnées de
  /// la plus ancienne à la plus récente : on part donc de la fin pour
  /// trouver le frame `inApp` le plus proche du point de crash.
  @visibleForTesting
  static String computeFingerprint(SentryEvent event) {
    final exception = event.exceptions?.firstOrNull;
    final type = exception?.type ?? 'Unknown';
    final frames = exception?.stackTrace?.frames ?? const [];
    SentryStackFrame? frame;
    for (var i = frames.length - 1; i >= 0; i--) {
      if (frames[i].inApp == true) {
        frame = frames[i];
        break;
      }
    }
    frame ??= frames.isNotEmpty ? frames.last : null;
    return '$type@${frame?.fileName ?? '?'}:${frame?.lineNo ?? 0}';
  }

  /// Renvoie un rapport spécifique vers Sentry (bouton "Envoyer", ou renvoi
  /// automatique après N lancements) puis supprime l'entrée locale — la
  /// responsabilité de la livraison est ensuite celle du cache/retry interne
  /// du SDK (spec §5.2/§10).
  static Future<void> deliver(
      PendingCrashReport report, IsarService isarService) async {
    try {
      final json = jsonDecode(report.serializedEventJson) as Map<String, dynamic>;
      final event = SentryEvent.fromJson(json);
      final hint = Hint()..set(_resendHintKey, true);
      await Sentry.captureEvent(event, hint: hint);

      final message = report.draftUserMessage?.trim();
      if (message != null && message.isNotEmpty) {
        await Sentry.captureFeedback(
          SentryFeedback(
            message: message,
            associatedEventId: SentryId.fromId(report.eventId),
          ),
          hint: hint,
        );
      }
    } catch (e) {
      debugPrint('CrashReportingService: resend error: $e');
    } finally {
      await isarService.deletePendingCrashReport(report.id);
    }
  }

  /// À appeler une fois par cold start réel : décrémente le compte à
  /// rebours de chaque rapport en attente et renvoie automatiquement ceux
  /// qui viennent d'atteindre zéro (spec §5.2).
  static Future<void> processColdStart(IsarService isarService) async {
    final due = await isarService.decrementLaunchesRemainingAndDue();
    for (final report in due) {
      await deliver(report, isarService);
    }
  }

  /// Downgrade premium → non-premium avec rapport(s) en attente : envoi
  /// immédiat de tout, pour ne pas perdre l'information si l'utilisateur ne
  /// redevient jamais premium (spec §8).
  static Future<void> flushAllOnDowngrade(IsarService isarService) async {
    final pending = await isarService.pendingCrashReports();
    for (final report in pending) {
      await deliver(report, isarService);
    }
  }

  /// Toggle désactivé alors que des rapports sont en attente : purge
  /// silencieuse, aucun envoi (spec §4).
  static Future<void> purgeAllPending(IsarService isarService) {
    return isarService.deleteAllPendingCrashReports();
  }
}
