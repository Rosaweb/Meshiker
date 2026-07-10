import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'database/isar_service.dart';
import 'map/map_view_model.dart';
import 'recording/recording_service.dart';
import 'search/local_search_engine.dart';
import 'ui/main_navigation_screen.dart';
import 'utils/settings_service.dart';
import 'utils/pedometer_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialisation des services
  final isarService = await IsarService.open();
  final settingsService = SettingsService();
  await settingsService.init();
  
  final searchEngine = LocalSearchEngine();
  await searchEngine.rebuildFromDatabase(isarService);
  
  final mapViewModel = MapViewModel(isarService: isarService);
  final recordingService = RecordingService(isarService: isarService);
  final pedometerService = PedometerService();
  
  // Dans une vraie app, on récupèrerait l'UUID de l'utilisateur local
  const ownerUuid = 'user-local-123';

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settingsService),
        ChangeNotifierProvider.value(value: pedometerService),
        Provider.value(value: isarService),
        Provider.value(value: searchEngine),
        Provider.value(value: mapViewModel),
        Provider.value(value: recordingService),
      ],
      child: MyApp(
        isarService: isarService,
        settingsService: settingsService,
        searchEngine: searchEngine,
        mapViewModel: mapViewModel,
        recordingService: recordingService,
        pedometerService: pedometerService,
        ownerUuid: ownerUuid,
      ),
    ),
  );
}

class MyApp extends StatelessWidget {
  final IsarService isarService;
  final SettingsService settingsService;
  final LocalSearchEngine searchEngine;
  final MapViewModel mapViewModel;
  final RecordingService recordingService;
  final PedometerService pedometerService;
  final String ownerUuid;

  const MyApp({
    super.key,
    required this.isarService,
    required this.settingsService,
    required this.searchEngine,
    required this.mapViewModel,
    required this.recordingService,
    required this.pedometerService,
    required this.ownerUuid,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rando Offline',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
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
