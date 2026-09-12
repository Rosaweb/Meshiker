import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Partage de position, mode Auto sur iOS (spec-partage-position-live-
  // tracking.md §6) : canal natif maison plutôt qu'un package tiers — voir
  // le plan d'implémentation, écart Milestone D : `flutter_apns_only` est
  // marqué "discontinued" sur pub.dev (dernier publié en 2022) et aucune
  // alternative APNs-only maintenue sans dépendance Firebase n'a été
  // trouvée. Nom de canal aligné sur le précédent déjà en place côté Dart
  // (`meshiker/system_gestures`, voir MainNavigationScreen).
  //
  // Côté Dart : lib/sharing/push_token_service.dart.
  private static let channelName = "meshiker/apns"
  private var channel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // NOTE (à vérifier côté Mac/Xcode, pas testable depuis cet environnement
    // de développement) : `messenger()` sur `FlutterPluginRegistry` est
    // l'accès documenté au `FlutterBinaryMessenger` du moteur implicite ;
    // si l'API a changé dans la version de Flutter utilisée, Xcode signalera
    // l'erreur de compilation ici précisément.
    let methodChannel = FlutterMethodChannel(
      name: AppDelegate.channelName,
      binaryMessenger: engineBridge.pluginRegistry.messenger()
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "register":
        UIApplication.shared.registerForRemoteNotifications()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = methodChannel
  }

  // Token APNs obtenu après `registerForRemoteNotifications()` — transmis
  // tel quel (hex) à `PushTokenService`, qui l'enregistre dans
  // `public.push_tokens` côté Supabase.
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    channel?.invokeMethod("onToken", arguments: token)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    channel?.invokeMethod("onTokenError", arguments: error.localizedDescription)
  }

  // Push silencieux (payload `content-available: 1`, jamais d'alert/badge/
  // sound) envoyé par supabase/functions/send-auto-checkin-push : réveille
  // l'app pour un check-in de position sans jamais afficher de
  // notification visible à l'utilisateur.
  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    guard let channel = channel else {
      completionHandler(.noData)
      return
    }
    channel.invokeMethod("onSilentPush", arguments: nil) { _ in
      completionHandler(.newData)
    }
  }
}
