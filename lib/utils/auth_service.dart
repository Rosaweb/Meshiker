import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:purchases_flutter/purchases_flutter.dart' show Purchases;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../database/isar_service.dart';
import '../models/enums.dart';
import '../models/utilisateur.dart';

/// Web Client ID Google Cloud Console (config manuelle, cf. plan
/// d'implémentation section M5) transmis au SDK natif via `--dart-define`,
/// même mécanisme que SUPABASE_URL/SUPABASE_ANON_KEY dans
/// `SupabaseBootstrapService`.
const _googleWebClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

/// Codes d'erreur gotrue confirmés en lisant le source
/// (`gotrue/lib/src/types/error_code.dart`) plutôt qu'en cherchant du texte
/// dans le message (fragile, dépendant de la langue du dashboard Supabase).
/// Indiquent qu'un email/identité correspond à un compte permanent déjà
/// existant.
const _kAlreadyRegisteredCodes = {
  'email_exists',
  'user_already_exists',
  'identity_already_exists',
};

/// Résultat d'une tentative de "sécurisation" du compte anonyme (écran
/// post-achat, Option A/B, section 4 du spec).
enum SecureAccountOutcome {
  /// Le compte anonyme a été complété avec succès (même UUID conservé).
  linked,

  /// L'utilisateur a annulé le flux (ex: fermeture du sélecteur Google).
  cancelled,

  /// L'email/compte Google correspondait à un compte permanent existant :
  /// on a basculé automatiquement sur une connexion classique sur ce
  /// compte (UUID différent, entitlement RevenueCat transféré via
  /// `Purchases.logIn`).
  fellBackToExistingAccount,
}

/// Gère l'authentification Supabase (anonyme -> compte permanent) et son
/// pont avec RevenueCat (`Purchases.logIn`), ainsi que le cycle de vie de
/// l'enregistrement `Utilisateur` local représentant cet appareil — rien
/// d'autre dans le code ne le crée (cf. doc de `SyncEngine`).
///
/// Voir `spec-authentification-paywall.md` pour l'architecture complète.
class AuthService extends ChangeNotifier {
  AuthService({required this.isarService});

  final IsarService isarService;

  SupabaseClient get _client => Supabase.instance.client;

  User? get currentUser => _client.auth.currentUser;
  bool get isAnonymous => currentUser?.isAnonymous ?? true;

  StreamSubscription<AuthState>? _authSub;
  bool _googleInitialized = false;

  /// À appeler une fois qu'une session Supabase (anonyme ou non) existe,
  /// typiquement juste après `SupabaseBootstrapService.init()` au démarrage.
  Future<void> init() async {
    await _syncLocalUser();
    _authSub ??= _client.auth.onAuthStateChange.listen(
      (_) => unawaited(_syncLocalUser().then((_) => notifyListeners())),
      // gotrue pousse une erreur sur ce stream (notifyException) quand son
      // rafraîchissement de token automatique en arrière-plan échoue (ex:
      // coupure réseau passagère, cf. AuthRetryableFetchException) — sans
      // onError ici, Dart la relance comme erreur non interceptée dans la
      // zone du `runZonedGuarded` de main.dart, qui la traite comme fatale
      // et remplace toute l'UI. Contraire au principe "zone blanche" (cf.
      // SupabaseBootstrapService) : un aléa réseau ne doit jamais faire
      // planter l'app, gotrue retente de lui-même en interne.
      onError: (Object error, StackTrace stack) {
        debugPrint('AuthService: onAuthStateChange error (ignoré): $error');
      },
    );
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  /// Crée l'enregistrement `Utilisateur` local (isLocalDevice) s'il
  /// n'existe pas encore, sinon le met à jour avec le remoteId/email
  /// courants.
  Future<void> _syncLocalUser() async {
    final user = currentUser;
    if (user == null) return;

    final existing = await isarService.currentDeviceUser();
    final local = existing ??
        (Utilisateur()
          ..localUuid = const Uuid().v4()
          ..isLocalDevice = true
          ..pseudo = 'Randonneur');

    final changed = local.remoteId != user.id || local.email != user.email;
    if (!changed && existing != null) return;

    local
      ..remoteId = user.id
      ..email = user.email
      ..syncStatus = SyncStatus.pending;
    await isarService.saveUser(local); // met aussi à jour updatedAt
  }

  Future<void> _ensureGoogleInitialized() async {
    if (_googleInitialized) return;
    await GoogleSignIn.instance.initialize(
      serverClientId: _googleWebClientId.isEmpty ? null : _googleWebClientId,
    );
    _googleInitialized = true;
  }

  // ---------------------------------------------------------------------
  // "Se connecter" (section 6.2/6.3) — remplace toujours la session
  // anonyme active, jamais de tentative de liaison.
  // ---------------------------------------------------------------------

  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) async {
    await _client.auth.signOut();
    final response = await _client.auth.signInWithPassword(
      email: email,
      password: password,
    );
    await _syncLocalUser();
    final userId = response.user?.id;
    if (userId != null) {
      await Purchases.logIn(userId);
    }
  }

  /// `null` si l'utilisateur annule le sélecteur de compte Google.
  Future<bool> signInWithGoogle() async {
    final tokens = await _googleIdToken();
    if (tokens == null) return false;

    final response = await _client.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: tokens.idToken,
      accessToken: tokens.accessToken,
    );
    await _syncLocalUser();
    final userId = response.user?.id;
    if (userId != null) {
      await Purchases.logIn(userId);
    }
    return true;
  }

  // ---------------------------------------------------------------------
  // "Sécurise ton compte" post-achat (section 4) — complète la session
  // anonyme existante ; repli automatique si le compte existe déjà
  // (section 4.1).
  // ---------------------------------------------------------------------

  Future<SecureAccountOutcome> secureWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      await _client.auth.updateUser(UserAttributes(email: email));
      await _client.auth.updateUser(UserAttributes(password: password));
      await _syncLocalUser();
      return SecureAccountOutcome.linked;
    } on AuthException catch (e) {
      if (!_isAlreadyRegisteredError(e)) rethrow;
      await signInWithPassword(email: email, password: password);
      return SecureAccountOutcome.fellBackToExistingAccount;
    }
  }

  Future<SecureAccountOutcome> secureWithGoogle() async {
    final tokens = await _googleIdToken();
    if (tokens == null) return SecureAccountOutcome.cancelled;

    try {
      await _client.auth.linkIdentityWithIdToken(
        provider: OAuthProvider.google,
        idToken: tokens.idToken,
        accessToken: tokens.accessToken,
      );
      await _syncLocalUser();
      return SecureAccountOutcome.linked;
    } on AuthException catch (e) {
      if (!_isAlreadyRegisteredError(e)) rethrow;
      // Repli section 4.1 : ce compte Google est déjà lié à un compte
      // permanent existant -> connexion classique dessus, abandon de la
      // session anonyme.
      await _client.auth.signOut();
      final response = await _client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: tokens.idToken,
        accessToken: tokens.accessToken,
      );
      await _syncLocalUser();
      final userId = response.user?.id;
      if (userId != null) {
        await Purchases.logIn(userId);
      }
      return SecureAccountOutcome.fellBackToExistingAccount;
    }
  }

  /// Isolé pour pouvoir ajuster facilement une fois le comportement réel de
  /// `linkIdentityWithIdToken`/`updateUser` observé en test — le spec
  /// signale explicitement que ce n'est pas encore vérifié empiriquement.
  bool _isAlreadyRegisteredError(AuthException e) =>
      e.code != null && _kAlreadyRegisteredCodes.contains(e.code);

  /// `null` si l'utilisateur annule le sélecteur de compte natif.
  Future<({String idToken, String? accessToken})?> _googleIdToken() async {
    await _ensureGoogleInitialized();

    GoogleSignInAccount account;
    try {
      account = await GoogleSignIn.instance.authenticate();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }

    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw const AuthException('Google Sign-In: idToken manquant.');
    }

    // Piège documenté (spec section 9) : Supabase valide un nonce sur les
    // flux ID token si le fournisseur en émet un. `google_sign_in` v7
    // n'expose pas de nonce par appel — activer "Skip Nonce Check" côté
    // dashboard Supabase (Auth > Providers > Google), pas un choix de code.
    final authClient = account.authorizationClient;
    final authorization =
        await authClient.authorizationForScopes(['email']) ??
            await authClient.authorizeScopes(['email']);

    return (idToken: idToken, accessToken: authorization.accessToken);
  }
}
