import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/supabase_bootstrap_service.dart';

/// Pont vers le canal natif iOS `meshiker/apns` (voir
/// `ios/Runner/AppDelegate.swift`) : demande d'enregistrement APNs,
/// réception du token, réception des réveils par push silencieux — voir
/// plan d'implémentation, écart Milestone D (canal natif maison plutôt que
/// `flutter_apns_only`, marqué "discontinued" sur pub.dev).
///
/// No-op complet sur Android : le mode Auto y est géré nativement par
/// `LocationAutoAlarmService` (alarme exacte système), sans aucune
/// infrastructure de push.
class PushTokenService {
  PushTokenService({required this.supabaseBootstrap});

  final SupabaseBootstrapService supabaseBootstrap;

  static const _channel = MethodChannel('meshiker/apns');

  /// Appelé quand un push silencieux réveille l'app (mode Auto iOS) —
  /// câblé par `LocationShareService`.
  Future<void> Function()? onSilentPush;

  bool _handlerRegistered = false;

  void _ensureHandlerRegistered() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler(_handleCall);
  }

  Future<dynamic> _handleCall(MethodCall call) async {
    switch (call.method) {
      case 'onToken':
        await _registerToken(call.arguments as String);
        return null;
      case 'onTokenError':
        debugPrint('PushTokenService: échec enregistrement APNs côté natif: ${call.arguments}');
        return null;
      case 'onSilentPush':
        await onSilentPush?.call();
        return null;
      default:
        return null;
    }
  }

  /// Enregistrement PARESSEUX (spec §6) : à appeler uniquement quand
  /// l'utilisateur démarre effectivement un partage Auto sur iOS — jamais
  /// systématiquement au démarrage de l'app, pour ne pas faire vivre un
  /// token push à quelqu'un qui n'utilise jamais ce mode.
  Future<void> registerForPush() async {
    if (!Platform.isIOS) return;
    _ensureHandlerRegistered();
    try {
      await _channel.invokeMethod<void>('register');
    } catch (e) {
      debugPrint('PushTokenService: échec de la demande d\'enregistrement (non-fatal): $e');
    }
  }

  Future<void> _registerToken(String token) async {
    try {
      final ready = await supabaseBootstrap.ensureReady();
      final client = supabaseBootstrap.clientOrNull;
      final userId = client?.auth.currentUser?.id;
      if (!ready || client == null || userId == null) return;
      await client.from('push_tokens').upsert(
        {'user_id': userId, 'platform': 'ios', 'token': token},
        onConflict: 'user_id,platform,token',
      );
    } catch (e) {
      // Zone blanche : un échec d'enregistrement du token ne doit jamais
      // faire planter le démarrage du partage Auto — au pire, ce device ne
      // recevra pas de push tant que le prochain enregistrement n'aboutit
      // pas (retenté à chaque appel de `registerForPush`).
      debugPrint('PushTokenService: échec enregistrement du token (non-fatal): $e');
    }
  }
}
