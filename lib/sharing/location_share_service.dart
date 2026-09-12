import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/isar_service.dart';
import '../gpx/segmentation_persistence.dart';
import '../models/trace.dart';
import '../recording/recording_service.dart';
import '../search/local_search_engine.dart';
import '../utils/supabase_bootstrap_service.dart';
import 'location_auto_alarm_service.dart';
import 'location_share_models.dart';
import 'location_share_trace_builder.dart';
import 'push_token_service.dart';

/// Orchestre le partage de position / live tracking (voir
/// spec-partage-position-live-tracking.md) : création/rejoint d'un
/// partage, échantillonnage Live, sauvegarde locale de trace en fin de
/// session, archive serveur de l'historique de groupe.
///
/// Style `RecordingService` à dessein (classe simple, état exposé via des
/// `ValueNotifier` publics, pas un `ChangeNotifier` global) — voir le plan
/// d'implémentation, "Conventions vérifiées à réutiliser".
///
/// NE DÉCLENCHE JAMAIS d'enregistrement de trace, et un enregistrement en
/// cours ne dépend jamais d'un partage actif (spec §1, principe 2) : cette
/// classe ne fait qu'observer `recordingService.lastAcceptedFix`, jamais
/// démarrer/arrêter son flux de localisation.
class LocationShareService {
  LocationShareService({
    required this.supabaseBootstrap,
    required this.recordingService,
    required this.isarService,
    required this.searchEngine,
  });

  final SupabaseBootstrapService supabaseBootstrap;
  final RecordingService recordingService;
  final IsarService isarService;
  final LocalSearchEngine searchEngine;

  final ValueNotifier<LocationShare?> activeShare = ValueNotifier(null);
  final ValueNotifier<List<LocationShareMember>> members = ValueNotifier(const []);
  final ValueNotifier<List<LocationPing>> myLivePoints = ValueNotifier(const []);
  final ValueNotifier<List<LocationShareJoinResult>> pendingInvites = ValueNotifier(const []);

  /// Dernier `recorded_at` connu par participant (tous, pas seulement
  /// l'utilisateur courant) — alimente la fraîcheur affichée sur l'écran
  /// "Partage actif" ("en direct"/"vu il y a X min"/"hors ligne"), dérivée
  /// de la récence plutôt que de Presence Realtime (voir plan
  /// d'implémentation, écart §2).
  final ValueNotifier<Map<String, DateTime>> lastSeenByUser = ValueNotifier(const {});

  late final PushTokenService _pushTokenService = PushTokenService(supabaseBootstrap: supabaseBootstrap);

  Timer? _liveSamplingTimer;
  RealtimeChannel? _pingsChannel;
  String? _currentUserId;

  /// Id Supabase de l'utilisateur courant, une fois résolu (voir [init]) —
  /// permet à l'UI de savoir si elle est administratrice d'un partage donné
  /// (`share.ownerId == currentUserId`) sans dupliquer l'accès au client
  /// Supabase Auth dans chaque écran.
  String? get currentUserId => _currentUserId;

  /// Résout un éventuel partage déjà actif au démarrage de l'app (créé ou
  /// rejoint avant un kill de l'app). Non-fatal si Supabase est
  /// injoignable — principe "zone blanche" (spec §1) : `activeShare` reste
  /// simplement `null`.
  Future<void> init() async {
    // Câblé inconditionnellement (indépendant du réseau Supabase
    // ci-dessous) : un push silencieux qui réveille l'app doit trouver le
    // handler déjà en place, quel que soit l'état de la connexion au
    // moment du démarrage.
    _pushTokenService.onSilentPush = _performAutoCheckIn;
    try {
      final ready = await supabaseBootstrap.ensureReady();
      final client = supabaseBootstrap.clientOrNull;
      if (!ready || client == null) return;

      final userId = client.auth.currentUser?.id;
      _currentUserId = userId;
      if (userId == null) return;

      final rows = await client
          .from('location_shares')
          .select()
          .eq('owner_id', userId)
          .eq('is_active', true)
          .limit(1);
      if (rows.isNotEmpty) {
        await _activateShare(LocationShare.fromMap(rows.first));
      }
    } catch (e) {
      debugPrint('LocationShareService: init error (non-fatal): $e');
    }
  }

  /// Crée un partage et, pour le mode Manuel, effectue immédiatement
  /// l'envoi unique et termine la session (spec §3 : "Fin de session — Non
  /// applicable, l'envoi termine l'action").
  Future<LocationShare> createShare({
    String? label,
    required LocationShareMode mode,
    required Set<LocationShareChannel> channels,
    LocationShareReciprocity reciprocity = LocationShareReciprocity.unilateral,
    int? liveIntervalSeconds,
    List<String>? autoTimes,
    bool historyEnabled = false,
    bool historyGlobal = false,
    LocationShareWebAccess webAccess = LocationShareWebAccess.public,
    String? webPassword,
    /// Pris en paramètre ICI plutôt que laissé à l'appelant pour les
    /// ajouter après coup : pour le mode Manuel, l'envoi ET l'email
    /// doivent partir avant que `stop_location_share` ne soit appelé dans
    /// ce même appel — un `addEmailRecipient` fait par l'écran APRÈS le
    /// retour de `createShare()` arriverait trop tard.
    Set<String> emailAddresses = const {},
  }) async {
    final client = await _requireClient();
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      throw const LocationShareException('Connexion requise pour créer un partage de position.');
    }

    late final List<dynamic> rows;
    try {
      rows = await client.rpc('create_location_share', params: {
        'p_label': label,
        'p_mode': mode.sqlValue,
        'p_channels': channels.map((c) => c.sqlValue).toList(),
        'p_reciprocity': reciprocity.sqlValue,
        'p_live_interval_seconds': liveIntervalSeconds,
        'p_auto_times': autoTimes,
        'p_history_enabled': historyEnabled,
        'p_history_global': historyGlobal,
        'p_web_access': webAccess.sqlValue,
        'p_web_password': webPassword,
      }) as List<dynamic>;
    } catch (e) {
      throw _mapRpcError(e, 'Impossible de créer le partage de position');
    }

    final row = rows.first as Map<String, dynamic>;
    final share = LocationShare(
      id: row['id'] as String,
      ownerId: userId,
      label: label,
      mode: mode,
      channels: channels,
      reciprocity: mode == LocationShareMode.manual ? LocationShareReciprocity.unilateral : reciprocity,
      liveIntervalSeconds: liveIntervalSeconds,
      autoTimes: autoTimes,
      historyEnabled: historyEnabled,
      historyGlobal: historyGlobal,
      webAccess: webAccess,
      shareToken: row['share_token'] as String,
      isActive: true,
      startedAt: DateTime.now(),
      expiresAt: DateTime.parse(row['expires_at'] as String),
    );

    if (channels.contains(LocationShareChannel.email)) {
      for (final email in emailAddresses) {
        await addEmailRecipient(share.id, email);
      }
    }

    if (mode == LocationShareMode.manual) {
      await _sendSinglePing(client, share, userId);
      if (channels.contains(LocationShareChannel.email)) {
        await _triggerEmail(client, share.id);
      }
      await client.rpc('stop_location_share', params: {'p_share_id': share.id});
      // Jamais de "partage actif" après un envoi Manuel (spec §3) :
      // activeShare n'est jamais renseigné pour ce mode.
      return share;
    }

    await _activateShare(share);
    return share;
  }

  /// Déclenche l'Edge Function `send-location-share-email` (Milestone E) —
  /// no-op côté serveur si aucun membre `email` n'existe pour ce partage
  /// (voir son propre early-return), donc appelable sans vérifier
  /// nous-mêmes la présence du canal à chaque check-in Auto.
  Future<void> _triggerEmail(SupabaseClient client, String shareId) async {
    try {
      await client.functions.invoke('send-location-share-email', body: {'share_id': shareId});
    } catch (e) {
      debugPrint('LocationShareService: échec envoi email (non-fatal): $e');
    }
  }

  /// Démarre l'émission de position pour le partage actif (Auto/Live) —
  /// no-op pour Manuel, déjà géré dans [createShare].
  Future<void> startEmission() async {
    final share = activeShare.value;
    if (share == null) return;

    switch (share.mode) {
      case LocationShareMode.manual:
        return;
      case LocationShareMode.live:
        recordingService.setSharingActive(true);
        _startLiveSampling(share);
        return;
      case LocationShareMode.auto:
        recordingService.setSharingActive(true);
        final userId = _currentUserId;
        final autoTimes = share.autoTimes;
        if (userId == null || autoTimes == null || autoTimes.isEmpty) return;
        if (Platform.isAndroid) {
          // Alarme exacte système, aucune infra serveur nécessaire (spec §6).
          await LocationAutoAlarmService.schedule(
            shareId: share.id,
            userId: userId,
            autoTimes: autoTimes,
          );
        } else if (Platform.isIOS) {
          // Le check-in effectif se fait au réveil par push silencieux
          // (voir _performAutoCheckIn), déclenché côté serveur par
          // send-auto-checkin-push — ce device n'a rien d'autre à faire
          // que s'enregistrer pour le recevoir.
          await _pushTokenService.registerForPush();
        }
        return;
    }
  }

  /// Effectue un relevé unique pour le partage Auto actif — appelé au
  /// réveil par push silencieux iOS (voir [PushTokenService.onSilentPush]),
  /// jamais directement par l'UI.
  Future<void> _performAutoCheckIn() async {
    final share = activeShare.value;
    if (share == null || share.mode != LocationShareMode.auto) return;
    try {
      final client = await _requireClient();
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;
      final position = await geo.Geolocator.getCurrentPosition();
      await _insertPing(client, share, userId, position);
      if (share.channels.contains(LocationShareChannel.email)) {
        await _triggerEmail(client, share.id);
      }
    } catch (e) {
      debugPrint('LocationShareService: échec check-in Auto/iOS (non-fatal): $e');
    }
  }

  /// Active le partage [shareId] pour un membre qui vient d'accepter une
  /// invitation (et, le cas échéant, de répondre au consentement
  /// d'historique global) — distinct de [createShare] : le membre n'est
  /// pas l'administrateur, mais émet et voit les autres exactement de la
  /// même façon une fois accepté (policies RLS déjà couvertes côté
  /// serveur, voir `is_accepted_app_member`).
  Future<void> activateJoinedShare(String shareId) async {
    final client = await _requireClient();
    final rows = await client.from('location_shares').select().eq('id', shareId).limit(1);
    if (rows.isEmpty) {
      throw const LocationShareException('Ce partage est introuvable ou a déjà pris fin.');
    }
    await _activateShare(LocationShare.fromMap(rows.first));
  }

  /// Recharge la liste des membres du partage actif (pseudo, statut
  /// d'invitation, consentement historique) — à appeler depuis l'écran
  /// "Partage actif" (ex. pull-to-refresh) : pas de Realtime dédié sur
  /// `location_share_members` pour rester au plus près du besoin réel
  /// (seuls les pings ont besoin d'un flux continu).
  Future<void> refreshMembers() async {
    final share = activeShare.value;
    if (share == null) return;
    await _loadMembers(share.id);
  }

  Future<LocationShareJoinResult> joinShare(String tokenOrUrl) async {
    final client = await _requireClient();
    final token = _extractToken(tokenOrUrl);
    try {
      final rows = await client.rpc('join_location_share', params: {
        'p_share_token': token,
      }) as List<dynamic>;
      final result = LocationShareJoinResult.fromMap(rows.first as Map<String, dynamic>);
      pendingInvites.value = [...pendingInvites.value, result];
      return result;
    } catch (e) {
      throw _mapRpcError(e, 'Impossible de rejoindre ce partage');
    }
  }

  /// Ajoute un destinataire email au partage actif (canal `email`, spec
  /// §11.1). Pas de statut d'invitation à faire accepter — contrairement à
  /// un membre `app`, un simple contact email n'a pas de compte Meshiker
  /// dont la position pourrait être exposée, `invite_status` vaut donc
  /// directement `accepted`. Insertion directe (policy "owners manage all
  /// members of their shares"), pas de RPC dédiée nécessaire.
  ///
  /// N'envoie PAS encore le mail lui-même : Milestone E
  /// (`send-location-share-email`) n'est pas construite à ce stade — le
  /// contact est enregistré, prêt pour cette future étape.
  Future<void> addEmailRecipient(String shareId, String email) async {
    final client = await _requireClient();
    try {
      await client.from('location_share_members').insert({
        'share_id': shareId,
        'channel': 'email',
        'contact': email,
        'invite_status': 'accepted',
      });
    } catch (e) {
      throw _mapRpcError(e, 'Impossible d\'ajouter ce destinataire');
    }
  }

  Future<void> respondToInvite(String memberId, bool accept) async {
    final client = await _requireClient();
    try {
      await client.rpc('respond_location_share_invite', params: {
        'p_member_id': memberId,
        'p_accept': accept,
      });
      pendingInvites.value = pendingInvites.value.where((i) => i.memberId != memberId).toList();
    } catch (e) {
      throw _mapRpcError(e, 'Impossible de répondre à cette invitation');
    }
  }

  /// Consentement à la conservation durable de l'historique — distinct de
  /// [respondToInvite] à dessein (spec §2/§8.3/§15 : deux consentements
  /// jamais l'un déduit de l'autre).
  Future<void> setHistoryConsent(String memberId, bool consent) async {
    final client = await _requireClient();
    try {
      await client.rpc('set_history_consent', params: {
        'p_member_id': memberId,
        'p_consent': consent,
      });
    } catch (e) {
      throw _mapRpcError(e, 'Impossible d\'enregistrer votre consentement');
    }
  }

  Future<void> extendDuration(Duration extra) async {
    final share = activeShare.value;
    if (share == null) return;
    final client = await _requireClient();
    try {
      final res = await client.rpc('extend_location_share', params: {
        'p_share_id': share.id,
        'p_extra_hours': extra.inHours,
      });
      activeShare.value = _copyWithExpiry(share, DateTime.parse(res as String));
    } catch (e) {
      throw _mapRpcError(e, 'Impossible d\'étendre la durée du partage');
    }
  }

  /// Arrête le partage actif. Ne propose PAS elle-même la sauvegarde —
  /// c'est à l'écran appelant ("Partage actif") de proposer
  /// [saveMyHistoryAsTrace]/[archiveGroupHistory] immédiatement après,
  /// pendant que `myLivePoints`/les pings serveur sont encore disponibles
  /// (voir plan d'implémentation : la purge cron peut intervenir dès 15
  /// min après expiration pour un partage sans historique).
  Future<void> stopShare() async {
    final share = activeShare.value;
    if (share == null) return;
    final client = await _requireClient();
    try {
      await client.rpc('stop_location_share', params: {'p_share_id': share.id});
    } catch (e) {
      throw _mapRpcError(e, 'Impossible d\'arrêter le partage');
    } finally {
      _deactivateShare();
    }
  }

  /// Sauvegarde LOCALE (jamais synchronisée, voir spec §8.4) de l'historique
  /// de l'utilisateur courant pour le partage [shareId], à partir de ses
  /// propres pings encore présents côté serveur.
  Future<Trace> saveMyHistoryAsTrace({
    required String shareId,
    required String ownerUuid,
    required String traceName,
  }) async {
    final client = await _requireClient();
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      throw const LocationShareException('Connexion requise pour sauvegarder cet historique.');
    }

    final rows = await client
        .from('location_pings')
        .select()
        .eq('share_id', shareId)
        .eq('user_id', userId)
        .order('recorded_at');
    final pings = rows.map(LocationPing.fromMap).toList();
    if (pings.length < 2) {
      throw const LocationShareException('Pas assez de points enregistrés pour former une trace.');
    }

    final result = LocationShareTraceBuilder.buildLocalOnly(
      pings: pings,
      ownerUuid: ownerUuid,
      traceName: traceName,
    );
    await SegmentationPersistence.persist(
      isarService: isarService,
      result: result,
      searchEngine: searchEngine,
    );
    return result.trace;
  }

  /// Archive serveur PERMANENTE de l'intégralité du groupe (décision
  /// produit, voir plan d'implémentation) — réservée à l'administrateur
  /// d'un partage à historique global. Renvoie le nombre de points
  /// archivés.
  Future<int> archiveGroupHistory(String shareId) async {
    final client = await _requireClient();
    try {
      final res = await client.rpc('archive_group_location_history', params: {
        'p_share_id': shareId,
      });
      return res as int;
    } catch (e) {
      throw _mapRpcError(e, 'Impossible de sauvegarder l\'historique du groupe');
    }
  }

  void dispose() {
    _liveSamplingTimer?.cancel();
    _pingsChannel?.unsubscribe();
  }

  // ---------------------------------------------------------------------
  // Interne
  // ---------------------------------------------------------------------

  Future<SupabaseClient> _requireClient() async {
    final ready = await supabaseBootstrap.ensureReady();
    final client = supabaseBootstrap.clientOrNull;
    if (!ready || client == null) {
      throw const LocationShareException(
        'Partage de position indisponible : aucune connexion au service. '
        'Vérifiez votre connexion réseau et réessayez.',
      );
    }
    // Tenu à jour ici plutôt que dans le seul `init()` : `init()` peut
    // n'avoir jamais abouti (pas de réseau au démarrage) alors qu'un appel
    // ultérieur réussit une fois la connexion revenue.
    _currentUserId = client.auth.currentUser?.id;
    return client;
  }

  Future<void> _activateShare(LocationShare share) async {
    activeShare.value = share;
    await startEmission();
    _subscribeToPings(share);
    if (share.channels.contains(LocationShareChannel.app)) {
      await _loadMembers(share.id);
    }
  }

  void _deactivateShare() {
    final share = activeShare.value;
    if (share != null && share.mode == LocationShareMode.auto && Platform.isAndroid) {
      // Best-effort, jamais bloquant pour l'arrêt du partage : l'alarme
      // système persiste sinon inutilement jusqu'à sa prochaine tentative
      // de check-in (qui échouera silencieusement, le partage n'étant
      // plus actif côté serveur).
      unawaited(LocationAutoAlarmService.cancel(share.id));
    }
    activeShare.value = null;
    members.value = const [];
    myLivePoints.value = const [];
    lastSeenByUser.value = const {};
    _liveSamplingTimer?.cancel();
    _liveSamplingTimer = null;
    _pingsChannel?.unsubscribe();
    _pingsChannel = null;
    recordingService.setSharingActive(false);
  }

  Future<void> _loadMembers(String shareId) async {
    try {
      final client = await _requireClient();
      final rows = await client
          .from('location_share_members')
          .select('*, profiles(pseudo)')
          .eq('share_id', shareId);
      members.value = rows.map(LocationShareMember.fromMap).toList();
    } catch (e) {
      // Non-fatal : la liste des membres reste simplement vide/périmée,
      // l'émission/réception de position ne dépend pas d'elle.
      debugPrint('LocationShareService: échec chargement des membres (non-fatal): $e');
    }
  }

  void _startLiveSampling(LocationShare share) {
    _liveSamplingTimer?.cancel();
    final interval = Duration(seconds: share.liveIntervalSeconds ?? 30);
    _liveSamplingTimer = Timer.periodic(interval, (_) => _emitLiveTick(share));
  }

  Future<void> _emitLiveTick(LocationShare share) async {
    // Fix déjà filtré par GpsFixQuality (`RecordingService.lastAcceptedFix`)
    // — pas `currentPosition.value`, qui inclut volontairement des fixes
    // rejetés pour le redraw carte, sémantique inadaptée à un envoi
    // discret vers d'autres personnes.
    final fix = recordingService.lastAcceptedFix;
    if (fix == null) return;
    try {
      final client = await _requireClient();
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;
      await _insertPing(client, share, userId, fix);
    } catch (e) {
      // Échec silencieux/loggé — principe "zone blanche" : une coupure
      // réseau pendant un Live ne doit jamais interrompre la session, la
      // reprise se fait automatiquement au tick suivant.
      debugPrint('LocationShareService: échec envoi ping Live (non-fatal): $e');
    }
  }

  Future<void> _sendSinglePing(SupabaseClient client, LocationShare share, String userId) async {
    final position = await geo.Geolocator.getCurrentPosition();
    await _insertPing(client, share, userId, position);
  }

  Future<void> _insertPing(
    SupabaseClient client,
    LocationShare share,
    String userId,
    geo.Position position,
  ) {
    return client.from('location_pings').insert({
      'share_id': share.id,
      'user_id': userId,
      'lat': position.latitude,
      'lng': position.longitude,
      'altitude': position.altitude,
      'speed': position.speed,
      'accuracy': position.accuracy,
    });
  }

  void _subscribeToPings(LocationShare share) {
    final client = supabaseBootstrap.clientOrNull;
    if (client == null) return;
    _pingsChannel?.unsubscribe();
    // Première utilisation de Supabase Realtime dans ce repo — voir plan
    // d'implémentation, section Vérification : à tester explicitement,
    // pas d'analogie fiable avec trace_shares (Storage uniquement).
    _pingsChannel = client.channel('location_pings_${share.id}')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'location_pings',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'share_id',
          value: share.id,
        ),
        callback: (payload) {
          final ping = LocationPing.fromMap(payload.newRecord);
          lastSeenByUser.value = {...lastSeenByUser.value, ping.userId: ping.recordedAt};
          if (ping.userId == _currentUserId) {
            myLivePoints.value = [...myLivePoints.value, ping];
          }
        },
      )
      ..subscribe();
  }

  LocationShare _copyWithExpiry(LocationShare share, DateTime expiresAt) => LocationShare(
        id: share.id,
        ownerId: share.ownerId,
        label: share.label,
        mode: share.mode,
        channels: share.channels,
        reciprocity: share.reciprocity,
        liveIntervalSeconds: share.liveIntervalSeconds,
        autoTimes: share.autoTimes,
        historyEnabled: share.historyEnabled,
        historyGlobal: share.historyGlobal,
        webAccess: share.webAccess,
        shareToken: share.shareToken,
        isActive: share.isActive,
        startedAt: share.startedAt,
        endedAt: share.endedAt,
        expiresAt: expiresAt,
      );

  /// Même logique d'extraction que `TraceShareService._extractToken` : si
  /// [input] est une URL valide, prend le dernier segment de chemin (le
  /// token) ; sinon traite l'entrée entière (nettoyée) comme le token.
  String _extractToken(String input) {
    final trimmed = input.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.last;
    }
    return trimmed;
  }

  LocationShareException _mapRpcError(Object e, String prefix) {
    final message = e is PostgrestException ? e.message : e.toString();
    if (message.contains('premium_required')) {
      return const LocationShareException(
        'Le partage de position est une fonctionnalité premium.',
        isPremiumRequired: true,
      );
    }
    return LocationShareException('$prefix : $message');
  }
}
