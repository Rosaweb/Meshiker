import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import 'trace_share_models.dart';

/// Serveur HTTP local (pur Dart, `package:shelf`) servant un GPX déjà en
/// mémoire, pour le partage "réseau wifi" (même réseau local, sans accès
/// internet — voir spec-partage-gpx-hors-reseau-mdns.md). Pas de découverte
/// mDNS ici : l'URL retournée par [start] est affichée en QR/texte et
/// scannée/collée manuellement côté récepteur, exactement comme un lien
/// Supabase.
class LocalGpxServer {
  HttpServer? _server;

  bool get isRunning => _server != null;

  /// Démarre le serveur et retourne l'URL complète
  /// (`http://<ip-locale>:<port>/gpx/<token>`) à partager. [gpxContent] est
  /// servi tel quel, entièrement depuis la mémoire (aucun fichier écrit sur
  /// disque côté émetteur).
  Future<Uri> start(String gpxContent) async {
    final token = const Uuid().v4();
    final ip = await _localIPv4Address();

    final router = Router();
    router.get('/gpx/<token>', (Request request, String requestToken) {
      if (requestToken != token) {
        return Response.forbidden('Token invalide');
      }
      return Response.ok(
        utf8.encode(gpxContent),
        headers: {'Content-Type': 'application/gpx+xml'},
      );
    });

    final handler = const Pipeline().addHandler(router.call);
    _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, 0);

    return Uri(scheme: 'http', host: ip, port: _server!.port, path: '/gpx/$token');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// Cherche une adresse IPv4 locale non-loopback (typiquement l'IP WiFi de
  /// l'appareil). Pure `dart:io`, pas besoin de `network_info_plus`.
  Future<String> _localIPv4Address() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (!address.isLoopback) return address.address;
      }
    }
    throw const TraceShareException(
      'Aucune adresse réseau locale trouvée. Vérifiez que le WiFi est activé.',
    );
  }
}
