import 'dart:convert';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/isar_service.dart';
import '../gpx/gpx_serializer.dart';
import '../models/trace.dart';
import '../utils/supabase_bootstrap_service.dart';
import 'trace_share_models.dart';

/// Orchestre le partage d'une [Trace] : export GPX, upload dans le
/// bucket Supabase Storage `trace-shares`, réservation d'un token via la
/// RPC `create_trace_share`. Ne s'occupe que de la génération du partage
/// — le scan/réception côté destinataire est un chantier séparé.
class TraceShareService {
  TraceShareService({required this.isarService, required this.supabaseBootstrap});

  final IsarService isarService;
  final SupabaseBootstrapService supabaseBootstrap;

  static const _bucket = 'trace-shares';
  static const _shareUrlBase = 'https://meshiker.com/share/gpx';

  Future<TraceShareResult> createShare(Trace trace) async {
    final ready = await supabaseBootstrap.ensureReady();
    final client = supabaseBootstrap.clientOrNull;
    if (!ready || client == null) {
      throw const TraceShareException(
        'Partage indisponible : aucune connexion au service de partage. '
        'Vérifiez votre connexion réseau et réessayez.',
      );
    }

    final points = await isarService.getTraceTrackPoints(trace);
    if (points.isEmpty) {
      throw const TraceShareException('Cette trace ne contient aucun point à partager.');
    }

    final gpxXml = GpxSerializer.serializeTrace(points: points, traceName: trace.name);

    final String token;
    try {
      final rows = await client.rpc('create_trace_share', params: {
        'p_trace_local_uuid': trace.localUuid,
        'p_trace_name': trace.name,
      }) as List<dynamic>;
      token = (rows.first as Map<String, dynamic>)['token'] as String;
    } catch (e) {
      throw TraceShareException('Impossible de créer le partage : $e');
    }

    try {
      await client.storage.from(_bucket).uploadBinary(
            '$token.gpx',
            Uint8List.fromList(utf8.encode(gpxXml)),
            fileOptions: const FileOptions(contentType: 'application/gpx+xml', upsert: false),
          );
    } catch (e) {
      throw TraceShareException('Impossible d\'envoyer le fichier GPX : $e');
    }

    return TraceShareResult(token: token, shareUrl: '$_shareUrlBase/$token');
  }
}
