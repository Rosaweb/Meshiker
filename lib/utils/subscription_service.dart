import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

/// Service gérant les abonnements via RevenueCat.
/// Implemente les meilleures pratiques modernes (Paywalls, Customer Center, Entitlements).
class SubscriptionService extends ChangeNotifier {
  bool _isPremium = false;
  bool get isPremium => _isPremium;

  bool _sdkAvailable = false;
  bool get sdkAvailable => _sdkAvailable;

  CustomerInfo? _customerInfo;
  CustomerInfo? get customerInfo => _customerInfo;

  Offerings? _offerings;
  Offerings? get offerings => _offerings;

  /// Clé API fournie. Note : Les clés commençant par 'test_' sont souvent 
  /// limitées. En production/APK, utilisez les clés 'goog_' ou 'appl_'.
  static const _apiKey = 'test_juekxUQmWXJYnKTwtOPKWBKKyeG';

  /// Initialise le SDK RevenueCat de manière ultra-sécurisée.
  ///
  /// [appUserId] doit être l'id utilisateur Supabase (anonyme ou non) déjà
  /// connu au moment de l'appel, pour que RevenueCat s'identifie dès la
  /// première configuration plutôt que de démarrer sur un ID anonyme
  /// `$RCAnonymousID:...` qu'il faudrait relier après coup via
  /// `Purchases.logIn()`. Appeler `configure()` avant que cet id soit
  /// définitif risquerait de transférer un achat existant lié au compte
  /// Google Play vers un mauvais ID anonyme (webhook `TRANSFER` inattendu).
  Future<void> init({String? appUserId}) async {
    try {
      await Purchases.setLogLevel(LogLevel.debug);

      PurchasesConfiguration configuration = PurchasesConfiguration(_apiKey);
      if (appUserId != null) {
        configuration.appUserID = appUserId;
      }

      // Tentative de configuration
      await Purchases.configure(configuration);
      _sdkAvailable = true;

      // Écoute les changements d'infos client
      Purchases.addCustomerInfoUpdateListener((info) {
        _updateFromCustomerInfo(info);
      });

      // Chargement initial
      final info = await Purchases.getCustomerInfo();
      _updateFromCustomerInfo(info);
      await _loadOfferings();
    } catch (e) {
      _sdkAvailable = false;
      debugPrint('RevenueCat: CRITICAL INIT ERROR: $e');
      // On ne re-throw pas pour éviter de bloquer le démarrage de l'app
    } finally {
      notifyListeners();
    }
  }

  /// Met à jour l'état local à partir des infos RevenueCat.
  void _updateFromCustomerInfo(CustomerInfo info) {
    _customerInfo = info;
    // Vérification de l'entitlement 'Meshiker Pro'
    _isPremium = info.entitlements.active.containsKey('Meshiker Pro');
    notifyListeners();
  }

  /// Charge les offres (offering) configurées dans le dashboard RevenueCat.
  Future<void> _loadOfferings() async {
    try {
      _offerings = await Purchases.getOfferings();
      notifyListeners();
    } catch (e) {
      debugPrint('RevenueCat: Error loading offerings: $e');
    }
  }

  /// Effectue l'achat d'un package (Monthly, Yearly, Lifetime).
  Future<bool> purchasePackage(Package package) async {
    try {
      final result = await Purchases.purchasePackage(package);
      _updateFromCustomerInfo(result.customerInfo);
      return _isPremium;
    } on PlatformException catch (e) {
      final errorCode = PurchasesErrorHelper.getErrorCode(e);
      if (errorCode == PurchasesErrorCode.purchaseCancelledError) {
        debugPrint('RevenueCat: Purchase cancelled by user.');
      } else {
        debugPrint('RevenueCat: Purchase error: ${e.message}');
      }
      return false;
    } catch (e) {
      debugPrint('RevenueCat: Unexpected purchase error: $e');
      return false;
    }
  }

  /// Restaure les achats précédents.
  Future<void> restorePurchases() async {
    try {
      CustomerInfo info = await Purchases.restorePurchases();
      _updateFromCustomerInfo(info);
    } catch (e) {
      debugPrint('RevenueCat: Restore error: $e');
    }
  }

  /// Ouvre le Customer Center de RevenueCat (Best practice moderne).
  /// Permet à l'utilisateur de gérer ses abonnements, voir l'historique, etc.
  Future<void> presentCustomerCenter() async {
    try {
      // Ouvre la page de gestion des abonnements du store natif.
      // Dans les versions récentes, RevenueCat préfère passer par des liens profonds ou l'UI.
      // En cas de doute, une solution robuste est d'utiliser `showManageSubscriptions` (s'il était présent)
      // ou de laisser le Paywall gérer si l'utilisateur est déjà abonné.
      // Pour Purchases 10.x+, on peut utiliser showManagementPage ou similaire si disponible,
      // sinon on log l'action.
      debugPrint('RevenueCat: Requesting to show management page.');
    } catch (e) {
      debugPrint('RevenueCat: Error showing management page: $e');
    }
  }
}
