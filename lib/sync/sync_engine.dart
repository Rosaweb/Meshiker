import 'package:isar_community/isar.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show SupabaseClient;

import '../database/isar_service.dart';
import '../models/enums.dart';
import '../models/point_of_interest.dart';
import '../models/segment.dart';
import '../models/utilisateur.dart';
import 'supabase_mapper.dart';
import 'sync_config.dart';
import 'sync_models.dart';

/// Synchronise la base locale avec Supabase.
///
/// ## Ce que ce moteur fait
/// - POUSSE les entités `pending` par lots, via les fonctions RPC de
///   `supabase/functions.sql` (`upsert_segments_batch`, `upsert_pois_batch`)
///   qui gèrent la fusion par buffer spatial côté serveur — le client
///   n'a JAMAIS à décider lui-même si son segment est "le même" qu'un
///   autre déjà connu du serveur, ce calcul reste entièrement serveur.
/// - TIRE les mises à jour communautaires (fiabilité, fréquentation) pour
///   les segments déjà connus localement, et les nouveaux segments/POI
///   apparus dans un viewport donné (contribués par d'autres utilisateurs).
///
/// ## Ce que ce moteur NE fait PAS
/// - Il ne décide PAS quand se déclencher. C'est à l'appelant (écran,
///   listener de connectivité...) d'appeler `pushPending()` au bon moment
///   — typiquement sur reprise réseau ET application au premier plan ET
///   `!recordingService.isActive` (contrainte batterie du brief, section
///   4 : jamais de synchronisation pendant un enregistrement actif).
/// - Il suppose une session Supabase Auth déjà active
///   (`client.auth.currentUser != null`). La création de compte/connexion
///   est un flux UI à part entière, hors du périmètre de ce moteur.
class SyncEngine {
  SyncEngine({
    required this.isarService,
    required this.client,
    this.config = const SyncConfig(),
  });

  final IsarService isarService;
  final SupabaseClient client;
  final SyncConfig config;

  // -----------------------------------------------------------------
  // Push
  // -----------------------------------------------------------------

  /// Pousse toutes les entités `pending` : profil, segments, POI, puis
  /// traces (dans cet ordre — les traces référencent des segments qui
  /// doivent déjà avoir un `remoteId`).
  Future<SyncSummary> pushPending() async {
    if (client.auth.currentUser == null) {
      return const SyncSummary(
        errors: ['Aucune session Supabase active : connexion requise avant de synchroniser.'],
      );
    }

    var summary = const SyncSummary();
    summary = summary + await _pushProfile();
    summary = summary + await _pushSegments();
    summary = summary + await _pushPois();
    summary = summary + await _pushTraces();
    return summary;
  }

  Future<SyncSummary> _pushProfile() async {
    final authUser = client.auth.currentUser!;
    final local = await isarService.isar.utilisateurs
        .filter()
        .isLocalDeviceEqualTo(true)
        .findFirst();
    if (local == null || local.syncStatus != SyncStatus.pending) {
      return const SyncSummary();
    }

    try {
      // La ligne `profiles` existe déjà (créée par le trigger
      // `handle_new_user` à l'inscription) : on ne fait que mettre à jour
      // les champs modifiables, jamais un insert qui risquerait la
      // contrainte de clé étrangère vers auth.users.
      await client.from('profiles').update({
        'pseudo': local.pseudo,
        'avatar_url': local.avatarUrl,
      }).eq('id', authUser.id);

      local
        ..remoteId = authUser.id
        ..syncStatus = SyncStatus.synced
        ..lastSyncAt = DateTime.now();
      await isarService.saveUser(local);
      return const SyncSummary();
    } catch (e) {
      return SyncSummary(errors: ['Profil : $e']);
    }
  }

  Future<SyncSummary> _pushSegments() async {
    final pending = await isarService.pendingSegments();
    if (pending.isEmpty) return const SyncSummary();

    final authorId = client.auth.currentUser!.id;
    var pushed = 0, merged = 0;
    final errors = <String>[];

    for (final chunk in _chunks(pending, config.maxBatchSize)) {
      final byLocalUuid = {for (final s in chunk) s.localUuid: s};
      final payload = chunk
          .map((s) => {
                'local_uuid': s.localUuid,
                // On envoie toujours l'auteur de la session Supabase EN
                // COURS, pas s.authorUuid (qui peut n'être qu'un
                // identifiant local placeholder si l'utilisateur s'est
                // connecté après avoir déjà enregistré des randonnées).
                'author_id': authorId,
                'points': s.points
                    .map((p) => {
                          'lat': p.latitude,
                          'lon': p.longitude,
                          'alt': p.altitude,
                        })
                    .toList(),
                'mode': s.mode.name,
                'distance_meters': s.distanceMeters,
                'elevation_gain_meters': s.elevationGainMeters,
                'elevation_loss_meters': s.elevationLossMeters,
                'difficulty': s.difficulty.name,
              })
          .toList();

      try {
        final rows = await client.rpc('upsert_segments_batch', params: {
          'p_segments': payload,
        }) as List<dynamic>;

        for (final raw in rows.cast<Map<String, dynamic>>()) {
          final local = byLocalUuid[raw['local_uuid'] as String];
          if (local == null) continue;
          local
            ..remoteId = raw['segment_id'] as String
            ..syncStatus = SyncStatus.synced
            ..updatedAt = DateTime.now();
          await isarService.saveSegment(local);
          pushed++;
          if (raw['was_merged'] == true) merged++;
        }
      } catch (e) {
        for (final s in chunk) {
          s.syncStatus = SyncStatus.error;
          await isarService.saveSegment(s);
        }
        errors.add('Segments (lot de ${chunk.length}) : $e');
      }
    }

    return SyncSummary(segmentsPushed: pushed, segmentsMerged: merged, errors: errors);
  }

  Future<SyncSummary> _pushPois() async {
    final pending = await isarService.pendingPois();
    if (pending.isEmpty) return const SyncSummary();

    final authorId = client.auth.currentUser!.id;
    var pushed = 0, merged = 0;
    final errors = <String>[];

    for (final chunk in _chunks(pending, config.maxBatchSize)) {
      final byLocalUuid = {for (final p in chunk) p.localUuid: p};
      final payload = chunk
          .map((p) => {
                'local_uuid': p.localUuid,
                'author_id': authorId,
                'name': p.name,
                'description': p.description,
                'type': p.type.name,
                'latitude': p.latitude,
                'longitude': p.longitude,
                'altitude': p.location.altitude,
              })
          .toList();

      try {
        final rows = await client.rpc('upsert_pois_batch', params: {
          'p_pois': payload,
        }) as List<dynamic>;

        for (final raw in rows.cast<Map<String, dynamic>>()) {
          final local = byLocalUuid[raw['local_uuid'] as String];
          if (local == null) continue;
          local
            ..remoteId = raw['poi_id'] as String
            ..syncStatus = SyncStatus.synced
            ..updatedAt = DateTime.now();
          await isarService.savePointOfInterest(local);
          pushed++;
          if (raw['was_merged'] == true) merged++;
        }
      } catch (e) {
        for (final p in chunk) {
          p.syncStatus = SyncStatus.error;
          await isarService.savePointOfInterest(p);
        }
        errors.add('Points d\'intérêt (lot de ${chunk.length}) : $e');
      }
    }

    return SyncSummary(poisPushed: pushed, poisMerged: merged, errors: errors);
  }

  /// Les traces n'ont pas de fusion (elles appartiennent exclusivement à
  /// leur créateur) : un simple upsert suffit, pas de fonction RPC dédiée.
  /// Ne pousse la ligne de jointure `trace_segments` que pour les
  /// segments qui ont déjà un `remoteId` — un segment encore `pending`
  /// (ex : son propre push a échoué juste au-dessus) sera rattrapé à la
  /// prochaine synchronisation, sans bloquer le reste de la trace.
  Future<SyncSummary> _pushTraces() async {
    final pending = await isarService.pendingTraces();
    if (pending.isEmpty) return const SyncSummary();

    var pushed = 0;
    final errors = <String>[];

    for (final trace in pending) {
      try {
        await client.from('traces').upsert(trace.toSupabaseMap());

        final joinRows = <Map<String, dynamic>>[];
        for (final entry in trace.segments) {
          final seg = await isarService.segmentByUuid(entry.segmentUuid);
          if (seg?.remoteId == null) continue;
          joinRows.add({
            'trace_id': trace.remoteId ?? trace.localUuid,
            'segment_id': seg!.remoteId,
            'order_index': entry.orderIndex,
            'traveled_forward': entry.traveledForward,
          });
        }
        if (joinRows.isNotEmpty) {
          await client.from('trace_segments').upsert(joinRows);
        }

        trace
          ..remoteId = trace.remoteId ?? trace.localUuid
          ..syncStatus = SyncStatus.synced
          ..updatedAt = DateTime.now();
        await isarService.saveTrace(trace);
        pushed++;
      } catch (e) {
        trace.syncStatus = SyncStatus.error;
        await isarService.saveTrace(trace);
        errors.add('Trace ${trace.localUuid} : $e');
      }
    }

    return SyncSummary(tracesPushed: pushed, errors: errors);
  }

  // -----------------------------------------------------------------
  // Pull
  // -----------------------------------------------------------------

  /// Rafraîchit `reliabilityIndex`/`passageCount`/`lastPassageAt` pour les
  /// segments déjà connus localement (déjà synchronisés), et suit une
  /// éventuelle redirection `merged_into` si ce segment a été fusionné
  /// avec un autre après coup (voir schema.sql — mécanisme prêt côté
  /// données, aucun job de fusion asynchrone ne l'alimente encore).
  Future<SyncSummary> pullAggregatesForKnownSegments() async {
    final known = await isarService.isar.segments
        .filter()
        .syncStatusEqualTo(SyncStatus.synced)
        .findAll();
    final remoteIds = known.map((s) => s.remoteId).whereType<String>().toList();
    if (remoteIds.isEmpty) return const SyncSummary();

    final byRemoteId = {for (final s in known) s.remoteId: s};
    final errors = <String>[];
    var updated = 0;

    try {
      for (final chunk in _chunks(remoteIds, config.maxBatchSize)) {
        final rows = await client
            .from('segments')
            .select(
              'id, passage_count, reliability_index, last_passage_at, merged_into',
            )
            .inFilter('id', chunk) as List<dynamic>;

        for (final raw in rows.cast<Map<String, dynamic>>()) {
          final local = byRemoteId[raw['id'] as String];
          if (local == null) continue;

          final mergedInto = raw['merged_into'] as String?;
          if (mergedInto != null) local.remoteId = mergedInto;

          local
            ..passageCount = raw['passage_count'] as int
            ..reliabilityIndex = (raw['reliability_index'] as num).toDouble()
            ..lastPassageAt = raw['last_passage_at'] != null
                ? DateTime.parse(raw['last_passage_at'] as String)
                : null
            ..updatedAt = DateTime.now();
          await isarService.saveSegment(local);
          updated++;
        }
      }
    } catch (e) {
      errors.add('Rafraîchissement des segments connus : $e');
    }

    return SyncSummary(segmentsRefreshed: updated, errors: errors);
  }

  /// Segments contribués par d'autres utilisateurs, présents côté serveur
  /// mais absents de la base locale, dans le rectangle donné.
  Future<SyncSummary> pullSegmentsInViewport({
    required double minLat,
    required double maxLat,
    required double minLon,
    required double maxLon,
  }) async {
    try {
      final rows = await client.rpc('segments_in_viewport', params: {
        'p_min_lon': minLon,
        'p_min_lat': minLat,
        'p_max_lon': maxLon,
        'p_max_lat': maxLat,
      }) as List<dynamic>;

      var imported = 0;
      for (final raw in rows.cast<Map<String, dynamic>>()) {
        final remoteId = raw['id'] as String;
        final already = await isarService.isar.segments
            .filter()
            .remoteIdEqualTo(remoteId)
            .findFirst();
        if (already != null) continue;

        final segment = SupabaseMapper.segmentFromViewportRow(raw);
        await isarService.saveSegment(segment);
        imported++;
      }
      return SyncSummary(segmentsPulled: imported);
    } catch (e) {
      return SyncSummary(errors: ['Lecture des segments du viewport : $e']);
    }
  }

  /// Symétrique de [pullSegmentsInViewport] pour les points d'intérêt.
  Future<SyncSummary> pullPoisInViewport({
    required double minLat,
    required double maxLat,
    required double minLon,
    required double maxLon,
  }) async {
    try {
      final rows = await client.rpc('pois_in_viewport', params: {
        'p_min_lon': minLon,
        'p_min_lat': minLat,
        'p_max_lon': maxLon,
        'p_max_lat': maxLat,
      }) as List<dynamic>;

      var imported = 0;
      for (final raw in rows.cast<Map<String, dynamic>>()) {
        final remoteId = raw['id'] as String;
        final already = await isarService.isar.pointOfInterests
            .filter()
            .remoteIdEqualTo(remoteId)
            .findFirst();
        if (already != null) continue;

        final poi = SupabaseMapper.poiFromViewportRow(raw);
        await isarService.savePointOfInterest(poi);
        imported++;
      }
      return SyncSummary(poisPulled: imported);
    } catch (e) {
      return SyncSummary(errors: ['Lecture des POI du viewport : $e']);
    }
  }

  // -----------------------------------------------------------------

  Iterable<List<T>> _chunks<T>(List<T> items, int size) sync* {
    for (var i = 0; i < items.length; i += size) {
      yield items.sublist(i, i + size > items.length ? items.length : i + size);
    }
  }
}
