import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Exécution arrière-plan Android du mode Auto (spec
/// spec-partage-position-live-tracking.md §6) : une alarme exacte système
/// par heure de check-in configurée (1 à 3, spec §3), déclenchée que l'app
/// soit ouverte, en arrière-plan ou tuée — via l'isolate dédié géré par
/// `android_alarm_manager_plus`. Aucun service de premier plan, aucune
/// notification permanente, à l'opposé du mode Live (qui réutilise le
/// flux de localisation déjà actif de `RecordingService`).
class LocationAutoAlarmService {
  const LocationAutoAlarmService._();

  static const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  // Même nom de paramètre que `SupabaseBootstrapService` : `anonKey` est
  // dépréciée côté package mais SUPABASE_ANON_KEY reste le nom du secret
  // tel que fourni via --dart-define-from-file.
  static const _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool _initialized = false;

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    _initialized = await AndroidAlarmManager.initialize();
  }

  /// À demander explicitement dès Android 14 (obligatoire, spec §6) avant
  /// de planifier une alarme `exact: true` — sans quoi Android lève une
  /// exception et l'alarme n'est jamais programmée. En cas de refus,
  /// [schedule] retombe sur une alarme inexacte plutôt que d'échouer :
  /// mieux vaut un check-in à l'heure approximative qu'aucun check-in.
  static Future<bool> hasExactAlarmPermission() async {
    final status = await ph.Permission.scheduleExactAlarm.status;
    if (status.isGranted) return true;
    final requested = await ph.Permission.scheduleExactAlarm.request();
    return requested.isGranted;
  }

  /// Planifie une alarme quotidienne par entrée de [autoTimes]
  /// (`"HH:mm:ss"`, tel que renvoyé par Postgres pour `location_shares
  /// .auto_times`). Remplace toute alarme déjà enregistrée pour ce
  /// partage (mêmes ids, déterministes à partir de [shareId]).
  ///
  /// [userId] est l'id Supabase (`auth.uid()`) de l'émetteur — jamais
  /// l'`ownerUuid` local Isar (concept distinct, propre au device, sans
  /// rapport avec l'authentification serveur).
  static Future<void> schedule({
    required String shareId,
    required String userId,
    required List<String> autoTimes,
  }) async {
    await _ensureInitialized();
    final exact = await hasExactAlarmPermission();
    final nowUtc = DateTime.now().toUtc();

    for (var i = 0; i < autoTimes.length; i++) {
      // `autoTimes` est déjà en UTC (converti côté
      // LocationShareCreateScreen avant l'envoi à create_location_share,
      // pour matcher le cron serveur qui compare contre `now()` en UTC) —
      // on construit ici un instant UTC absolu, que `startAt
      // .millisecondsSinceEpoch` transmet ensuite à l'alarme système
      // indépendamment du fuseau local de l'appareil.
      final parts = autoTimes[i].split(':');
      final hour = int.parse(parts[0]);
      final minute = int.parse(parts[1]);
      var startAt = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day, hour, minute);
      if (startAt.isBefore(nowUtc)) startAt = startAt.add(const Duration(days: 1));

      final ok = await AndroidAlarmManager.periodic(
        const Duration(hours: 24),
        _alarmId(shareId, i),
        _checkInCallback,
        startAt: startAt,
        exact: exact,
        wakeup: true,
        allowWhileIdle: true,
        // Un partage Auto court par défaut sur 72h (voir plan
        // d'implémentation) : doit survivre à un redémarrage du téléphone.
        rescheduleOnReboot: true,
        params: {'shareId': shareId, 'userId': userId},
      );
      if (!ok) {
        debugPrint('LocationAutoAlarmService: échec planification alarme #${_alarmId(shareId, i)}');
      }
    }
  }

  /// Annule les alarmes d'un partage (jusqu'à 3 check-ins possibles, spec
  /// §3) — à appeler depuis `stopShare()`/à l'arrêt du partage Auto.
  static Future<void> cancel(String shareId) async {
    for (var i = 0; i < 3; i++) {
      await AndroidAlarmManager.cancel(_alarmId(shareId, i));
    }
  }

  /// Id d'alarme déterministe et stable, dérivé du `share_id` (UUID) et de
  /// l'index du check-in — contrainte de l'API (`assert(id.bitLength <
  /// 32)`), et doit rester identique entre [schedule] et [cancel] pour le
  /// même partage.
  static int _alarmId(String shareId, int index) => (shareId.hashCode & 0x0FFFFFFF) * 10 + index;

  /// Tourne dans l'isolate dédié géré par `android_alarm_manager_plus`,
  /// entièrement indépendant du reste de l'app (pas de Provider, pas de
  /// `LocationShareService`, pas d'UI à prévenir en cas d'échec) — le
  /// plugin natif a déjà démarré un moteur Flutter avec les plugins
  /// enregistrés avant d'invoquer ce callback (pas de
  /// `WidgetsFlutterBinding`/`DartPluginRegistrant` à initialiser
  /// manuellement ici, voir l'exemple officiel du package).
  ///
  /// À VÉRIFIER SUR DEVICE (voir plan d'implémentation) : fiabilité de la
  /// restauration, dans cet isolate séparé, de la session Supabase
  /// persistée sur disque par l'app principale — dégrade silencieusement
  /// (check-in ignoré, réessayé à la prochaine occurrence) si absente.
  @pragma('vm:entry-point')
  static Future<void> _checkInCallback(int id, Map<String, dynamic> params) async {
    final shareId = params['shareId'] as String?;
    final userId = params['userId'] as String?;
    if (shareId == null || userId == null) return;
    if (_supabaseUrl.isEmpty || _supabaseAnonKey.isEmpty) return;

    try {
      await Supabase.initialize(url: _supabaseUrl, publishableKey: _supabaseAnonKey);
      final client = Supabase.instance.client;
      if (client.auth.currentSession == null) {
        debugPrint('LocationAutoAlarmService: pas de session Supabase restaurée, check-in ignoré.');
        return;
      }

      final position = await geo.Geolocator.getCurrentPosition();
      await client.from('location_pings').insert({
        'share_id': shareId,
        'user_id': userId,
        'lat': position.latitude,
        'lng': position.longitude,
        'altitude': position.altitude,
        'speed': position.speed,
        'accuracy': position.accuracy,
      });

      // send-location-share-email (Milestone E) no-op côté serveur si
      // aucun membre `email` n'existe pour ce partage (voir son propre
      // early-return) — appelée systématiquement, pas besoin de connaître
      // les canaux du partage dans cet isolate minimal.
      try {
        await client.functions.invoke('send-location-share-email', body: {'share_id': shareId});
      } catch (e) {
        debugPrint('LocationAutoAlarmService: échec envoi email (non-fatal): $e');
      }
    } catch (e) {
      // Zone blanche : un check-in manqué (réseau, permission GPS révoquée
      // entre-temps...) ne doit jamais faire planter cet isolate — il n'y
      // a de toute façon personne pour voir un crash ici.
      debugPrint('LocationAutoAlarmService: échec check-in (non-fatal): $e');
    }
  }
}
