import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import '../ui/tracks/import_share_screen.dart';
import 'share_link.dart';

/// Reçoit les liens `https://meshiker.com/share/gpx/{token}` ouverts depuis
/// l'extérieur (navigateur, message, scan d'un QR code par l'appareil photo) :
/// Android les route vers l'app grâce à l'`intent-filter` `autoVerify` du
/// manifest (App Links, vérifié via `/.well-known/assetlinks.json`).
///
/// Ouvre l'écran d'import PRÉ-REMPLI mais n'importe rien tout seul : un lien
/// peut être déclenché par n'importe quelle page ou application, on ne doit
/// pas ajouter de trace à la bibliothèque sans que l'utilisateur confirme.
///
/// Doit rester non bloquant et silencieux en cas d'échec : un lien reçu ne
/// doit jamais faire planter l'app ni gêner son démarrage.
class DeepLinkService {
  DeepLinkService({required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;
  StreamSubscription<Uri>? _subscription;

  /// À appeler tôt (juste après `runApp`) : `uriLinkStream` rejoue le lien qui
  /// a lancé l'app à froid, puis émet les suivants.
  void init() {
    if (_subscription != null) return;
    try {
      _subscription = AppLinks().uriLinkStream.listen(
            _handle,
            onError: (Object e) => debugPrint('DeepLinkService: erreur flux (ignorée): $e'),
          );
    } catch (e) {
      debugPrint('DeepLinkService: init impossible (ignoré): $e');
    }
  }

  void dispose() => _subscription?.cancel();

  void _handle(Uri uri) {
    if (shareTokenFromUri(uri) == null) {
      debugPrint('DeepLinkService: lien ignoré (pas un partage GPX Meshiker).');
      return;
    }
    // Au démarrage à froid le Navigator n'existe pas encore : on attend
    // qu'il soit monté plutôt que de perdre le lien.
    _openImportWhenReady(uri.toString(), attemptsLeft: 30);
  }

  void _openImportWhenReady(String link, {required int attemptsLeft}) {
    final navigator = navigatorKey.currentState;
    if (navigator != null) {
      navigator.push(
        MaterialPageRoute(builder: (_) => ImportShareScreen(initialInput: link)),
      );
      return;
    }
    if (attemptsLeft <= 0) return;
    Future<void>.delayed(
      const Duration(milliseconds: 200),
      () => _openImportWhenReady(link, attemptsLeft: attemptsLeft - 1),
    );
  }
}
