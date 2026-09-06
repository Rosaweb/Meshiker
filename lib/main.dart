
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'database/isar_service.dart';
import 'map/map_view_model.dart';
import 'recording/recording_service.dart';
import 'search/local_search_engine.dart';
import 'ui/main_navigation_screen.dart';
import 'utils/settings_service.dart';
import 'utils/pedometer_service.dart';
import 'weather/weather_service.dart';
import 'utils/auth_service.dart';
import 'utils/crash_reporting_service.dart';
import 'utils/subscription_service.dart';
import 'utils/tile_cache_service.dart';
import 'utils/supabase_bootstrap_service.dart';
import 'gpx/gpx_import_service.dart';
import 'gpx/gpx_scanner_service.dart';
import 'navigation/waypoint_announcement_service.dart';
import 'sharing/trace_share_service.dart';
import 'assistant/assistant_service.dart';
import 'assistant/places_service.dart';
import 'assistant/terrain_analysis_service.dart';

// `runZonedGuarded`'s onError capte toute erreur async non interceptée
// pendant TOUTE la durée de vie de l'app, pas seulement au démarrage —
// alors que `_handleFatalError` ne doit remplacer l'UI que pour un échec
// survenu AVANT le premier `runApp()` réussi (son fallback est un écran de
// secours "l'app n'a jamais pu démarrer", pas un gestionnaire d'erreurs
// générique). Sans ce garde-fou, une erreur asynchrone anodine survenant en
// cours d'usage (bien après le démarrage) rappellerait `runApp()` sur un
// binding Flutter déjà actif et déclencherait une seconde exception ("Zone
// mismatch") par-dessus la première, remplaçant l'app entière par l'écran
// d'erreur au lieu de laisser Flutter gérer l'erreur normalement.
bool _appStarted = false;

void main() async {
  // Capture les erreurs Flutter (UI, etc.)
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('FLUTTER ERROR: ${details.exception}');
  };

  // Capture les erreurs asynchrones hors Flutter
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('PLATFORM ERROR: $error');
    debugPrint(stack.toString());
    return true;
  };

  runZonedGuarded(() async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      
      // Initialisation des services strictement nécessaires à la première
      // frame (local, rapide, requis pour construire l'arbre de providers).
      final isarService = await IsarService.open();
      // Débloque les cartes hors-ligne dont le téléchargement a été
      // interrompu par un kill de l'app lors d'une session précédente (cf.
      // IsarService.resetStuckOfflineMapDownloads) avant que l'UI ne
      // s'affiche, pour qu'elles soient reprenables dès la première frame.
      await isarService.resetStuckOfflineMapDownloads();
      // Relie les catégories de waypoints par défaut historiques
      // ("Point d'eau/Source", "Cabane/Refuge") à leur équivalent OSM, pour
      // que l'import de POI OSM les réutilise au lieu d'en créer des doublons.
      await isarService.backfillDefaultCategoryOsmIds();
      final settingsService = SettingsService();
      await settingsService.init();

      // Doit être initialisé APRES le toggle système (spec-crash-reporting.md
      // §3.1 : le toggle est lu avant l'appel à SentryFlutter.init(), sinon
      // désactiver le réglage n'empêcherait pas la génération du rapport en
      // cours de session) mais AVANT tout le reste, pour capter un maximum
      // d'erreurs de démarrage. `FlutterError.onError`/`PlatformDispatcher
      // .onError` étant déjà positionnés plus haut, Sentry vient s'y
      // chaîner (capture puis appelle le handler existant) sans les
      // remplacer : le fallback `_handleFatalError` reste inchangé.
      await CrashReportingService.init(
        settings: settingsService,
        isarService: isarService,
      );

      // Le reste (abonnements RevenueCat, cache de tuiles, index de
      // recherche, service d'enregistrement) est instancié tout de suite
      // mais initialisé APRES runApp(), en arrière-plan : ce sont tous des
      // ChangeNotifier/ValueNotifier déjà écoutés par l'UI, qui se met à
      // jour d'elle-même une fois prêts. Ça évite que l'affichage de
      // l'interface attende des appels réseau (RevenueCat) qui peuvent
      // mettre plusieurs secondes à échouer en zone blanche.
      final subscriptionService = SubscriptionService();
      // Persiste le statut premium résolu dans SettingsService (lu de façon
      // synchrone par CrashReportingService.beforeSend, cf. son propre
      // commentaire) et déclenche le flush immédiat des rapports de crash en
      // attente lors d'un downgrade premium → non-premium (spec §8) — câblé
      // AVANT `subscriptionService.init()` pour ne rater aucune résolution.
      subscriptionService.onPremiumStatusChanged = (wasPremium, isPremiumNow) {
        unawaited(settingsService.setLastKnownPremiumStatus(isPremiumNow));
        if (wasPremium && !isPremiumNow) {
          unawaited(CrashReportingService.flushAllOnDowngrade(isarService));
        }
      };
      final tileCacheService = TileCacheService(settingsService: settingsService);
      final supabaseBootstrap = SupabaseBootstrapService();
      final authService = AuthService(isarService: isarService, supabaseBootstrap: supabaseBootstrap);
      final searchEngine = LocalSearchEngine();
      final importService = GpxImportService(isarService: isarService, searchEngine: searchEngine);
      final traceShareService = TraceShareService(
        isarService: isarService,
        supabaseBootstrap: supabaseBootstrap,
        gpxImportService: importService,
        settingsService: settingsService,
      );
      final mapViewModel = MapViewModel(isarService: isarService);
      final pedometerService = PedometerService();
      final weatherService = WeatherService(settings: settingsService);
      final recordingService = RecordingService(
        isarService: isarService,
        pedometerService: pedometerService,
        settingsService: settingsService,
      );
      // Doit être construit après `recordingService` : l'assistant IA de
      // navigation (v2, function calling) lit l'itinéraire/waypoints
      // chargés dans le Roadmap directement depuis ce service (lecture
      // seule, cf. RecordingService.activeRoadmapTrace).
      final placesService = PlacesService(supabaseBootstrap: supabaseBootstrap);
      final terrainAnalysisService = TerrainAnalysisService(isarService: isarService);
      final assistantService = AssistantService(
        supabaseBootstrap: supabaseBootstrap,
        recordingService: recordingService,
        placesService: placesService,
        terrainAnalysisService: terrainAnalysisService,
      );
      final waypointAnnouncementService = WaypointAnnouncementService(
        mapViewModel: mapViewModel,
        recordingService: recordingService,
        settingsService: settingsService,
      );

      const ownerUuid = 'user-local-123';

      final gpxScanner = GpxScannerService(
        isarService: isarService,
        importService: importService,
        ownerUuid: ownerUuid,
      );

      // Une fois par cold start réel : décrémente le compte à rebours des
      // rapports de crash premium en attente et renvoie automatiquement
      // ceux qui viennent d'atteindre zéro (spec-crash-reporting.md §5.2).
      // Indépendant du statut premium résolu ou non cette session : la file
      // n'est de toute façon jamais peuplée pour un compte non-premium.
      unawaited(CrashReportingService.processColdStart(isarService));

      // Tâches subsidiaires : lancées sans attendre, jamais prioritaires
      // sur l'affichage de l'interface.
      unawaited(() async {
        // Supabase (auth anonyme incluse) DOIT être prêt avant de
        // configurer RevenueCat, pour lui passer directement le bon
        // app_user_id dès la première configuration plutôt que de
        // démarrer sur un ID anonyme RevenueCat déconnecté (cf.
        // AuthService/SubscriptionService.init, piège documenté dans
        // spec-authentification-paywall.md section 9).
        await supabaseBootstrap.init();
        try {
          // supabaseBootstrap.init() est déjà non-fatal par conception (cf.
          // son propre commentaire), mais AuthService.init() accède
          // directement à Supabase.instance : si l'initialisation du SDK
          // lui-même n'a jamais abouti (ex. SUPABASE_URL/ANON_KEY absents),
          // cet accès lève une exception non catchée qui bloquerait tout le
          // démarrage de l'app — contraire au principe "zone blanche".
          await authService.init();
        } catch (e) {
          debugPrint('AuthService init error: $e');
        }
        try {
          await subscriptionService.init(appUserId: authService.currentUser?.id);
        } catch (e) {
          debugPrint('RevenueCat init error: $e');
        }
        await tileCacheService.init();
        await searchEngine.rebuildFromDatabase(isarService);
        await recordingService.init();
        await waypointAnnouncementService.init();

        if (settingsService.gpxStoragePath != null) {
          unawaited(gpxScanner.scanFolder(settingsService.gpxStoragePath!));
        }
      }());

      runApp(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: settingsService),
            ChangeNotifierProvider.value(value: pedometerService),
            ChangeNotifierProvider.value(value: weatherService),
            ChangeNotifierProvider.value(value: subscriptionService),
            ChangeNotifierProvider.value(value: authService),
            ChangeNotifierProvider.value(value: tileCacheService),
            Provider.value(value: isarService),
            Provider.value(value: searchEngine),
            Provider.value(value: mapViewModel),
            Provider.value(value: recordingService),
            Provider.value(value: waypointAnnouncementService),
            Provider.value(value: importService),
            Provider.value(value: supabaseBootstrap),
            Provider.value(value: traceShareService),
            Provider.value(value: assistantService),
            ChangeNotifierProvider.value(value: gpxScanner),
            StreamProvider<ConnectivityResult>(
              create: (_) => Connectivity().onConnectivityChanged.map((results) => results.first),
              initialData: ConnectivityResult.wifi,
            ),
            StreamProvider<List<ConnectivityResult>>(
              create: (_) => Connectivity().onConnectivityChanged,
              initialData: const [ConnectivityResult.wifi],
            ),
          ],
          child: MyApp(
            isarService: isarService,
            settingsService: settingsService,
            subscriptionService: subscriptionService,
            searchEngine: searchEngine,
            mapViewModel: mapViewModel,
            recordingService: recordingService,
            pedometerService: pedometerService,
            weatherService: weatherService,
            ownerUuid: ownerUuid,
          ),
        ),
      );
      _appStarted = true;
    } catch (e, stack) {
      _handleFatalError(e, stack);
    }
  }, (error, stack) => _handleFatalError(error, stack));
}

void _handleFatalError(Object error, StackTrace stack) {
  debugPrint('FATAL ERROR: $error');
  debugPrint(stack.toString());
  // Filet de sécurité : les erreurs Flutter/PlatformDispatcher sont déjà
  // captées par les intégrations Sentry qui se chaînent sur les handlers
  // définis plus haut dans ce fichier, mais une erreur qui remonte jusqu'à
  // ce point (hors de ces deux canaux) ne le serait pas sans cet appel
  // explicite. No-op si Sentry n'a jamais été initialisé (toggle désactivé).
  Sentry.captureException(error, stackTrace: stack);

  // L'app tourne déjà (ce n'est pas un échec de démarrage) : ne PAS
  // remplacer son UI par l'écran de secours, ni rappeler `runApp()` sur un
  // binding déjà actif (cf. commentaire sur `_appStarted`). L'erreur reste
  // néanmoins loguée et remontée à Sentry ci-dessus.
  if (_appStarted) return;

  runApp(MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: SelectableText(
            'Erreur fatale au démarrage :\n$error\n\n$stack',
            style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    ),
  ));
}

class MyApp extends StatelessWidget {
  final IsarService isarService;
  final SettingsService settingsService;
  final SubscriptionService subscriptionService;
  final LocalSearchEngine searchEngine;
  final MapViewModel mapViewModel;
  final RecordingService recordingService;
  final PedometerService pedometerService;
  final WeatherService weatherService;
  final String ownerUuid;

  const MyApp({
    super.key,
    required this.isarService,
    required this.settingsService,
    required this.subscriptionService,
    required this.searchEngine,
    required this.mapViewModel,
    required this.recordingService,
    required this.pedometerService,
    required this.weatherService,
    required this.ownerUuid,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Meshiker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green, brightness: Brightness.dark),
        scaffoldBackgroundColor: Colors.black,
        useMaterial3: true,
      ),
      builder: (context, child) {
        // Grossissement du texte pour l'accessibilité (cf. SettingsService.fontScale),
        // appliqué globalement via MediaQuery plutôt qu'écran par écran.
        final fontScale = context.watch<SettingsService>().fontScale;
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(fontScale),
          ),
          child: child!,
        );
      },
      home: MainNavigationScreen(
        isarService: isarService,
        settingsService: settingsService,
        searchEngine: searchEngine,
        mapViewModel: mapViewModel,
        recordingService: recordingService,
        pedometerService: pedometerService,
        weatherService: weatherService,
        ownerUuid: ownerUuid,
      ),
    );
  }
}
