import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:purchases_flutter/purchases_flutter.dart' show Purchases;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../database/isar_service.dart';
import '../models/enums.dart';
import '../models/utilisateur.dart';
import 'pseudo.dart';
import 'supabase_bootstrap_service.dart';

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
  AuthService({required this.isarService, required this.supabaseBootstrap});

  final IsarService isarService;
  final SupabaseBootstrapService supabaseBootstrap;

  // `Supabase.instance` lève une exception (pas un simple retour null) tant
  // que `Supabase.initialize()` n'a jamais réussi (ex. pas de réseau/DNS
  // bloqué par un VPN au démarrage) — passer par `clientOrNull`
  // (`SupabaseBootstrapService`, déjà utilisé ailleurs, ex. AssistantService)
  // au lieu d'un accès direct est ce qui évite le crash "You must
  // initialize the supabase instance before calling Supabase.instance"
  // observé sur l'écran "Mon compte" en zone blanche/réseau instable.
  SupabaseClient? get _client => supabaseBootstrap.clientOrNull;

  User? get currentUser => _client?.auth.currentUser;
  bool get isAnonymous => currentUser?.isAnonymous ?? true;

  /// À utiliser dans toute méthode qui a vraiment besoin d'un client (les
  /// actions de connexion ci-dessous) — lève une [AuthException] "propre"
  /// (déjà gérée par l'UI existante, cf. `LoginScreen._showError`) plutôt
  /// que de laisser `Supabase.instance` planter avec un message obscur.
  SupabaseClient _requireClient() {
    final client = _client;
    if (client == null) {
      throw const AuthException(
        'Connexion au serveur indisponible. Vérifiez votre connexion réseau et réessayez.',
      );
    }
    return client;
  }

  StreamSubscription<AuthState>? _authSub;
  bool _googleInitialized = false;

  /// À appeler une fois qu'une session Supabase (anonyme ou non) existe,
  /// typiquement juste après `SupabaseBootstrapService.init()` au démarrage.
  Future<void> init() async {
    final client = _client;
    if (client == null) {
      // Pas de session Supabase disponible au démarrage (pas de réseau,
      // `SupabaseBootstrapService.init()` a déjà échoué en amont sans lever
      // — voir son propre commentaire) : rien à synchroniser pour l'instant,
      // repli "zone blanche" plutôt qu'un crash. `currentUser`/`isAnonymous`
      // restent utilisables (null/true) tant que ça dure.
      debugPrint('AuthService.init(): pas de client Supabase disponible, abandon (non fatal).');
      return;
    }
    await _syncLocalUser();
    _authSub ??= client.auth.onAuthStateChange.listen(
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
          ..pseudo = kDefaultPseudo);

    final accountChanged = local.remoteId != user.id;
    final changed = accountChanged || local.email != user.email;
    if (!changed && existing != null) return;

    // Nouveau compte sur cet appareil (première session, connexion à un
    // compte existant...) : le pseudo du serveur fait foi, sinon on afficherait
    // « Randonneur » à la place du pseudo déjà choisi sur le site ou un autre
    // appareil. En cas d'échec réseau on garde le pseudo local.
    var syncStatus = local.syncStatus;
    if (accountChanged) {
      final remotePseudo = await _fetchRemotePseudo(user.id);
      if (remotePseudo != null) {
        local.pseudo = remotePseudo;
        syncStatus = SyncStatus.synced; // déjà identique au serveur
      } else {
        syncStatus = SyncStatus.pending;
      }
    }
    // Un simple changement d'e-mail ne laisse rien à pousser (`profiles` ne
    // stocke que pseudo/avatar) : ne pas repasser en `pending`, sinon un
    // pseudo périmé écraserait plus tard celui modifié sur le site.

    local
      ..remoteId = user.id
      ..email = user.email
      ..syncStatus = syncStatus;
    await isarService.saveUser(local); // met aussi à jour updatedAt
  }

  /// Pseudo enregistré côté serveur pour [userId] (`profiles` est lisible
  /// publiquement), ou `null` si indisponible. Ne lève jamais : appelé au
  /// démarrage, où la zone blanche ne doit rien bloquer.
  Future<String?> _fetchRemotePseudo(String userId) async {
    final client = _client;
    if (client == null) return null;
    try {
      final row = await client
          .from('profiles')
          .select('pseudo')
          .eq('id', userId)
          .maybeSingle()
          .timeout(const Duration(seconds: 5));
      final pseudo = row?['pseudo'] as String?;
      return (pseudo == null || pseudo.trim().isEmpty) ? null : pseudo;
    } catch (e) {
      debugPrint('AuthService: lecture du pseudo distant impossible (ignoré): $e');
      return null;
    }
  }

  /// Change le pseudo de l'utilisateur : enregistré localement d'abord (source
  /// de vérité, marche hors ligne), puis poussé vers `profiles` si possible.
  ///
  /// Renvoie `true` si le serveur a confirmé, `false` si le pseudo reste en
  /// attente de synchronisation (`SyncEngine._pushProfile` le poussera).
  /// Lève [ArgumentError] avec un message affichable si [raw] est invalide.
  Future<bool> updatePseudo(String raw) async {
    final checked = validatePseudo(raw);
    if (checked.value == null) throw ArgumentError(checked.error);
    final pseudo = checked.value!;

    var local = await isarService.currentDeviceUser();
    if (local == null) {
      await _syncLocalUser();
      local = await isarService.currentDeviceUser();
    }
    if (local == null) {
      throw StateError('Aucun profil local pour enregistrer le pseudo.');
    }

    local
      ..pseudo = pseudo
      ..syncStatus = SyncStatus.pending;
    await isarService.saveUser(local);
    notifyListeners();

    final userId = currentUser?.id;
    final client = _client;
    if (userId == null || client == null) return false;

    try {
      // La ligne `profiles` existe déjà (trigger handle_new_user) : mise à
      // jour seulement, comme `SyncEngine._pushProfile`. `.single()` échoue
      // si le RLS n'a modifié aucune ligne, au lieu de "réussir" à vide.
      await client
          .from('profiles')
          .update({'pseudo': pseudo})
          .eq('id', userId)
          .select('pseudo')
          .single()
          .timeout(const Duration(seconds: 8));
      local
        ..syncStatus = SyncStatus.synced
        ..lastSyncAt = DateTime.now();
      await isarService.saveUser(local);
      return true;
    } catch (e) {
      debugPrint('AuthService: pseudo enregistré localement, envoi différé: $e');
      return false;
    }
  }

  /// Compte Google connecté alors que le pseudo est encore celui par défaut
  /// (compte créé avant que le trigger ne reprenne le prénom Google, ou
  /// compte anonyme qu'on vient de lier) : on adopte le prénom Google.
  Future<void> _adoptGoogleNameIfDefault(String? displayName) async {
    final firstName = firstNameFromDisplayName(displayName);
    if (firstName == null) return;
    final local = await isarService.currentDeviceUser();
    if (local == null || local.pseudo != kDefaultPseudo) return;
    try {
      await updatePseudo(firstName);
    } catch (e) {
      debugPrint('AuthService: prénom Google non adopté (ignoré): $e');
    }
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
    final client = _requireClient();
    await client.auth.signOut();
    final response = await client.auth.signInWithPassword(
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

    final response = await _requireClient().auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: tokens.idToken,
      accessToken: tokens.accessToken,
    );
    await _syncLocalUser();
    await _adoptGoogleNameIfDefault(tokens.displayName);
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
      final client = _requireClient();
      await client.auth.updateUser(UserAttributes(email: email));
      await client.auth.updateUser(UserAttributes(password: password));
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
      final client = _requireClient();
      await client.auth.linkIdentityWithIdToken(
        provider: OAuthProvider.google,
        idToken: tokens.idToken,
        accessToken: tokens.accessToken,
      );
      await _syncLocalUser();
      await _adoptGoogleNameIfDefault(tokens.displayName);
      return SecureAccountOutcome.linked;
    } on AuthException catch (e) {
      if (!_isAlreadyRegisteredError(e)) rethrow;
      // Repli section 4.1 : ce compte Google est déjà lié à un compte
      // permanent existant -> connexion classique dessus, abandon de la
      // session anonyme.
      final client = _requireClient();
      await client.auth.signOut();
      final response = await client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: tokens.idToken,
        accessToken: tokens.accessToken,
      );
      await _syncLocalUser();
      await _adoptGoogleNameIfDefault(tokens.displayName);
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
  Future<({String idToken, String? accessToken, String? displayName})?>
      _googleIdToken() async {
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

    return (
      idToken: idToken,
      accessToken: authorization.accessToken,
      displayName: account.displayName,
    );
  }
}
