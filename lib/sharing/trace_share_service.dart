import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/isar_service.dart';
import '../gpx/gpx_import_service.dart';
import '../gpx/gpx_models.dart';
import '../gpx/gpx_serializer.dart';
import '../models/trace.dart';
import '../utils/settings_service.dart';
import '../utils/supabase_bootstrap_service.dart';
import 'trace_share_models.dart';

/// Orchestre le partage d'une [Trace] dans les deux sens :
/// - génération : export GPX (points + waypoints associés), upload dans le
///   bucket Supabase Storage `trace-shares`, réservation d'un token via la
///   RPC `create_trace_share` ;
/// - réception : résolution d'un lien/token en URL publique de ce même
///   bucket, téléchargement et import via [GpxImportService]. Si un dossier
///   GPX personnalisé est configuré, le fichier téléchargé y est aussi
///   écrit (comme n'importe quelle trace scannée depuis ce dossier).
class TraceShareService {
  TraceShareService({
    required this.isarService,
    required this.supabaseBootstrap,
    required this.gpxImportService,
    required this.settingsService,
  });

  final IsarService isarService;
  final SupabaseBootstrapService supabaseBootstrap;
  final GpxImportService gpxImportService;
  final SettingsService settingsService;

  static const _bucket = 'trace-shares';
  static const _shareUrlBase = 'https://meshiker.com/share/gpx';

  /// Même constante que côté `SupabaseBootstrapService`, dupliquée à dessein :
  /// c'est une constante de compilation, pas un état partagé, et la
  /// réception ne doit pas dépendre de l'état d'auth du bootstrap (le bucket
  /// est public, aucune session Supabase n'est nécessaire pour le lire).
  static const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');

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

    final waypoints = await isarService.searchWaypoints(filterGpxName: trace.name);
    final gpxXml = GpxSerializer.serializeTrace(
      points: points,
      traceName: trace.name,
      waypoints: waypoints
          .map((w) => GpxWaypoint(
                latitude: w.latitude,
                longitude: w.longitude,
                name: w.name,
                description: w.description,
              ))
          .toList(),
    );

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

  /// Télécharge et importe la trace correspondant à [tokenOrUrl], qui peut
  /// être soit un lien complet (`https://meshiker.com/share/gpx/{token}`
  /// ou tout autre chemin se terminant par le token), soit le token seul.
  Future<Trace> importFromShare(String tokenOrUrl, {required String ownerUuid}) async {
    if (_supabaseUrl.isEmpty) {
      throw const TraceShareException(
        'Import indisponible : configuration Supabase manquante.',
      );
    }

    final token = _extractToken(tokenOrUrl);
    if (token.isEmpty) {
      throw const TraceShareException('Lien ou code de partage invalide.');
    }

    final uri = Uri.parse('$_supabaseUrl/storage/v1/object/public/$_bucket/$token.gpx');
    debugPrint('TraceShareService: téléchargement depuis $uri (token="$token")');
    final http.Response response;
    try {
      response = await http.get(uri);
    } catch (e) {
      throw TraceShareException('Impossible de télécharger la trace : $e');
    }

    if (response.statusCode != 200) {
      debugPrint('TraceShareService: échec téléchargement ${response.statusCode} : ${response.body}');
      if (response.statusCode == 404 || _isNotFoundBody(response.body)) {
        throw const TraceShareException('Ce partage est introuvable, expiré ou révoqué.');
      }
      throw TraceShareException(
        'Erreur lors du téléchargement (code ${response.statusCode}).',
      );
    }

    final gpxXml = utf8.decode(response.bodyBytes);
    final result = await gpxImportService.importXmlString(gpxXml, ownerUuid: ownerUuid);
    if (result == null) {
      throw const TraceShareException('Ce fichier GPX ne contient aucun point exploitable.');
    }

    // Si un dossier GPX personnalisé est configuré, la trace importée doit y
    // être écrite comme un fichier réel, au même titre que n'importe quelle
    // trace scannée depuis ce dossier (voir GpxScannerService) — sans quoi
    // elle n'existe que dans la base locale, invisible dans ce dossier.
    final folder = settingsService.recordingSubPath ?? settingsService.gpxStoragePath;
    if (folder != null && folder.isNotEmpty) {
      try {
        final fileName = '${_sanitizeFileName(result.trace.name)}.gpx';
        final fullPath = p.join(folder, fileName);
        await File(fullPath).writeAsString(gpxXml);
        result.trace.sourceFilePath = fullPath;
        await isarService.saveTrace(result.trace);
      } catch (e) {
        // Non-bloquant : la trace est déjà importée en base, l'échec
        // d'écriture du fichier ne doit pas faire échouer tout l'import.
        debugPrint('TraceShareService: échec écriture GPX dans le dossier configuré : $e');
      }
    }

    return result.trace;
  }

  /// Si [input] est une URL valide, prend le dernier segment de chemin
  /// (le token) ; sinon traite l'entrée entière, une fois nettoyée des
  /// espaces, comme le token lui-même.
  String _extractToken(String input) {
    final trimmed = input.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.last;
    }
    return trimmed;
  }

  /// Le Storage Supabase renvoie parfois un objet manquant avec un code
  /// HTTP 400 (pas 404) et un corps JSON `{"error":"not_found", ...}` —
  /// observé en pratique avec un token périmé/supprimé. On regarde donc
  /// aussi le corps, pas seulement le code HTTP, pour ce cas précis.
  bool _isNotFoundBody(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) return false;
      return json['error'] == 'not_found' || json['code'] == 'NoSuchKey';
    } catch (_) {
      return false;
    }
  }

  String _sanitizeFileName(String name) {
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }
}
