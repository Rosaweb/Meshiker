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
import 'utils/subscription_service.dart';
import 'utils/tile_cache_service.dart';
import 'gpx/gpx_import_service.dart';
import 'gpx/gpx_scanner_service.dart';

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
      
      // Initialisation des services
      final isarService = await IsarService.open();
      final settingsService = SettingsService();
      await settingsService.init();

      final subscriptionService = SubscriptionService();
      try {
        await subscriptionService.init();
      } catch (e) {
        debugPrint('RevenueCat init error: $e');
      }

      final tileCacheService = TileCacheService(settingsService: settingsService);
      await tileCacheService.init();
      
      final searchEngine = LocalSearchEngine();
      await searchEngine.rebuildFromDatabase(isarService);

      final importService = GpxImportService(isarService: isarService, searchEngine: searchEngine);
      
      final mapViewModel = MapViewModel(isarService: isarService);
      final pedometerService = PedometerService();
      final recordingService = RecordingService(
        isarService: isarService, 
        pedometerService: pedometerService,
        settingsService: settingsService,
      );
      await recordingService.init();

      const ownerUuid = 'user-local-123';

      final gpxScanner = GpxScannerService(
        isarService: isarService,
        importService: importService,
        ownerUuid: ownerUuid,
      );

      // Initial scan if path is set
      if (settingsService.gpxStoragePath != null) {
        unawaited(gpxScanner.scanFolder(settingsService.gpxStoragePath!));
      }

      runApp(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: settingsService),
            ChangeNotifierProvider.value(value: pedometerService),
            ChangeNotifierProvider.value(value: subscriptionService),
            ChangeNotifierProvider.value(value: tileCacheService),
            Provider.value(value: isarService),
            Provider.value(value: searchEngine),
            Provider.value(value: mapViewModel),
            Provider.value(value: recordingService),
            Provider.value(value: importService),
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
        ownerUuid: ownerUuid,
      ),
    );
  }
}
