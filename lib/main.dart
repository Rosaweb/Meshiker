import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'database/isar_service.dart';
import 'map/map_view_model.dart';
import 'recording/recording_service.dart';
import 'search/local_search_engine.dart';
import 'ui/main_navigation_screen.dart';
import 'utils/settings_service.dart';
import 'utils/pedometer_service.dart';
import 'utils/weather_service.dart';
import 'utils/subscription_service.dart';
import 'utils/tile_cache_service.dart';
import 'utils/supabase_bootstrap_service.dart';
import 'gpx/gpx_import_service.dart';
import 'gpx/gpx_scanner_service.dart';
import 'sharing/trace_share_service.dart';

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
      final settingsService = SettingsService();
      await settingsService.init();

      // Le reste (abonnements RevenueCat, cache de tuiles, index de
      // recherche, service d'enregistrement) est instancié tout de suite
      // mais initialisé APRES runApp(), en arrière-plan : ce sont tous des
      // ChangeNotifier/ValueNotifier déjà écoutés par l'UI, qui se met à
      // jour d'elle-même une fois prêts. Ça évite que l'affichage de
      // l'interface attende des appels réseau (RevenueCat) qui peuvent
      // mettre plusieurs secondes à échouer en zone blanche.
      final subscriptionService = SubscriptionService();
      final tileCacheService = TileCacheService(settingsService: settingsService);
      final supabaseBootstrap = SupabaseBootstrapService();
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
      final weatherService = WeatherService();
      final recordingService = RecordingService(
        isarService: isarService,
        pedometerService: pedometerService,
        settingsService: settingsService,
      );

      const ownerUuid = 'user-local-123';

      final gpxScanner = GpxScannerService(
        isarService: isarService,
        importService: importService,
        ownerUuid: ownerUuid,
      );

      // Tâches subsidiaires : lancées sans attendre, jamais prioritaires
      // sur l'affichage de l'interface.
      unawaited(() async {
        try {
          await subscriptionService.init();
        } catch (e) {
          debugPrint('RevenueCat init error: $e');
        }
        await supabaseBootstrap.init();
        await tileCacheService.init();
        await searchEngine.rebuildFromDatabase(isarService);
        await recordingService.init();

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
            ChangeNotifierProvider.value(value: tileCacheService),
            Provider.value(value: isarService),
            Provider.value(value: searchEngine),
            Provider.value(value: mapViewModel),
            Provider.value(value: recordingService),
            Provider.value(value: importService),
            Provider.value(value: supabaseBootstrap),
            Provider.value(value: traceShareService),
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
    } catch (e, stack) {
      _handleFatalError(e, stack);
    }
  }, (error, stack) => _handleFatalError(error, stack));
}

void _handleFatalError(Object error, StackTrace stack) {
  debugPrint('FATAL ERROR: $error');
  debugPrint(stack.toString());
  
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
