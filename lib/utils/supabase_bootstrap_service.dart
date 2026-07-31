import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Initialise la connexion Supabase (URL + clé anonyme fournies via
/// `--dart-define-from-file=env.json`, voir `env.example.json`) et ouvre
/// une session anonyme si aucune n'existe déjà.
///
/// Ne doit jamais faire échouer le démarrage de l'app : la contrainte
/// "zone blanche" impose que l'app reste pleinement utilisable sans
/// réseau ni configuration Supabase (voir `SubscriptionService.init()`
/// pour le même principe côté RevenueCat).
///
/// [ensureReady] est rejouable : si la tentative précédente a échoué
/// (pas de réseau au démarrage, par exemple), un appel ultérieur
/// retente réellement la connexion, plutôt que de rester bloqué sur le
/// résultat de la toute première tentative. `Supabase.initialize()` ne
/// peut en revanche être appelé qu'une seule fois par processus : on ne
/// le rejoue donc jamais une fois qu'il a réussi, seule la (re)connexion
/// de la session (signInAnonymously) est retentée.
class SupabaseBootstrapService {
  static const _url = String.fromEnvironment('SUPABASE_URL');
  static const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  bool _coreInitialized = false;
  bool _signedIn = false;
  Future<bool>? _pendingAttempt;

  SupabaseClient? get clientOrNull => _coreInitialized ? Supabase.instance.client : null;

  /// Compatibilité avec l'appel fait au démarrage dans main.dart.
  Future<void> init() => ensureReady();

  /// Se résout avec `true` si un client Supabase avec une session active
  /// est disponible. Idempotent : peut être appelé autant de fois que
  /// nécessaire (ex: avant chaque tentative de partage), pas seulement
  /// au démarrage.
  Future<bool> ensureReady() {
    if (_signedIn) return Future.value(true);
    return _pendingAttempt ??= _attempt().whenComplete(() => _pendingAttempt = null);
  }

  Future<bool> _attempt() async {
    if (_url.isEmpty || _anonKey.isEmpty) {
      debugPrint(
        'Supabase: SUPABASE_URL/SUPABASE_ANON_KEY manquants '
        '(lancer avec --dart-define-from-file=env.json, voir env.example.json).',
      );
      return false;
    }
    try {
      if (!_coreInitialized) {
        // `publishableKey` accepte aussi bien l'ancienne clé "anon" (JWT)
        // que la nouvelle "publishable key" (sb_publishable_...) —
        // `anonKey` est dépréciée côté package mais SUPABASE_ANON_KEY
        // reste le nom le plus reconnaissable dans le dashboard Supabase.
        await Supabase.initialize(url: _url, publishableKey: _anonKey);
        _coreInitialized = true;
      }
      final client = Supabase.instance.client;
      if (client.auth.currentSession == null) {
        await client.auth.signInAnonymously();
      }
      _signedIn = true;
      return true;
    } catch (e) {
      debugPrint('Supabase: erreur d\'initialisation: $e');
      return false;
    }
  }
}
