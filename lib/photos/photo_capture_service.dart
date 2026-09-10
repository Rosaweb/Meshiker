import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:uuid/uuid.dart';

import '../database/isar_service.dart';
import '../map/map_view_model.dart';
import '../models/waypoint.dart';
import '../recording/recording_service.dart';
import '../utils/geo_utils.dart';
import '../utils/photo_scanner_service.dart';
import '../utils/settings_service.dart';

/// Point d'entrée "photo géolocalisée" du bandeau de menu principal
/// (spec-photos-geolocalisees.md). N'introduit AUCUNE nouvelle entité : chaque
/// photo devient un [Waypoint] ordinaire avec `isPhotoWaypoint == true`,
/// regroupé spatialement avec les waypoints photo voisins.
///
/// Android : lance l'appli caméra système (interface complète) et observe la
/// pellicule (`photo_manager`) pour capter chaque cliché d'une rafale avec sa
/// propre position, sans attendre le retour dans Meshiker. La session se
/// termine au retour au premier plan ou sur timeout de sécurité.
///
/// iOS : `UIImagePickerController(.camera)` est le seul point d'entrée
/// autorisé — une seule photo par appui, exactement comme le bouton de la
/// fiche waypoint. Limitation de plateforme, pas un choix produit.
class PhotoCaptureService with WidgetsBindingObserver {
  PhotoCaptureService({
    required this.isarService,
    required this.recordingService,
    required this.settingsService,
    required this.mapViewModel,
  });

  final IsarService isarService;
  final RecordingService recordingService;
  final SettingsService settingsService;
  final MapViewModel mapViewModel;

  static const _channel = MethodChannel('meshiker/photo_capture');
  static const _uuid = Uuid();
  final PhotoScannerService _scanner = PhotoScannerService();
  final ImagePicker _picker = ImagePicker();

  /// Timeout de sécurité si l'app ne revient jamais au premier plan pendant
  /// une session multi-photos (spec §3.3, point ouvert mineur — ajustable).
  static const Duration sessionTimeout = Duration(minutes: 30);

  /// Waypoint photo dont la fiche d'édition doit être ouverte (uniquement si
  /// le réglage "Afficher la fenêtre d'édition après une photo" est actif,
  /// spec §7). MapScreen l'écoute puis le remet à `null`.
  final ValueNotifier<Waypoint?> pendingEditWaypoint = ValueNotifier(null);

  /// Message ponctuel à présenter à l'utilisateur (SnackBar) — permission
  /// refusée, aucune appli caméra, bilan de session. MapScreen l'écoute puis
  /// le remet à `null`.
  final ValueNotifier<String?> message = ValueNotifier(null);

  /// Vrai pendant qu'une session multi-photos Android est ouverte.
  final ValueNotifier<bool> sessionActive = ValueNotifier(false);

  // --- État de session ---
  DateTime _sessionStart = DateTime.fromMillisecondsSinceEpoch(0);
  final Set<String> _processedAssetIds = {};
  final Set<String> _copiedBasenames = {};
  final List<({DateTime time, geo.Position pos})> _sessionFixes = [];
  final List<Waypoint> _sessionWaypoints = [];
  Timer? _timeoutTimer;
  bool _draining = false;
  bool _drainAgain = false;
  bool _changeCallbackRegistered = false;
  // La session ne se termine qu'au PREMIER `resumed` qui suit un passage en
  // arrière-plan effectif : certains appareils émettent un `resumed`
  // parasite juste après le lancement d'une Activity (l'appli caméra), ce
  // qui clôturerait la session avant la moindre photo.
  bool _sawBackground = false;

  /// Déclenché par le bouton photo du bandeau. Android : ouvre une session
  /// multi-photos. iOS : capture unique.
  Future<void> startCaptureSession() async {
    if (Platform.isIOS) {
      await _captureSingleIOS();
      return;
    }
    if (sessionActive.value) return; // session déjà en cours

    _sessionStart = DateTime.now();
    _processedAssetIds.clear();
    _copiedBasenames.clear();
    _sessionFixes.clear();
    _sessionWaypoints.clear();
    _sawBackground = false;

    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.hasAccess) {
      message.value =
          "Accès aux photos refusé : la détection des clichés est impossible.";
      return;
    }

    await PhotoManager.startChangeNotify();
    if (!_changeCallbackRegistered) {
      PhotoManager.addChangeCallback(_onGalleryChange);
      _changeCallbackRegistered = true;
    }
    WidgetsBinding.instance.addObserver(this);
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(sessionTimeout, () => unawaited(_endSession()));
    sessionActive.value = true;

    bool launched = false;
    try {
      launched = await _channel.invokeMethod<bool>('launchCamera') ?? false;
    } catch (e) {
      debugPrint('launchCamera failed: $e');
    }
    if (!launched) {
      message.value = "Aucune application appareil photo n'a pu être lancée.";
      await _endSession(silent: true);
    }
  }

  // ---------------------------------------------------------------------------
  // iOS : capture unique
  // ---------------------------------------------------------------------------
  Future<void> _captureSingleIOS() async {
    final XFile? shot = await _picker.pickImage(source: ImageSource.camera);
    if (shot == null) return;
    _sessionStart = DateTime.now();
    _sessionWaypoints.clear();
    final ts = DateTime.now();
    final pos = await recordingService.acquireFixNow();
    final dest = await _copyIntoMeshiker(File(shot.path), ts);
    if (dest == null) return;
    await _ingestPhoto(dest.path, pos, ts);
    _maybeOpenPopup();
  }

  // ---------------------------------------------------------------------------
  // Android : observateur de pellicule + cycle de vie
  // ---------------------------------------------------------------------------
  void _onGalleryChange(MethodCall _) {
    if (!sessionActive.value) return;
    unawaited(_drainNewAssets());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!sessionActive.value) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _sawBackground = true;
      return;
    }
    // Retour au premier plan de Meshiker après un passage effectif en
    // arrière-plan => fin de la session multi-photos (spec §3.3).
    if (state == AppLifecycleState.resumed && _sawBackground) {
      unawaited(_endSession());
    }
  }

  Future<void> _drainNewAssets() async {
    if (_draining) {
      _drainAgain = true;
      return;
    }
    _draining = true;
    try {
      do {
        _drainAgain = false;
        final assets = await _fetchNewAssets();
        for (final a in assets) {
          _processedAssetIds.add(a.id);
          await _ingestAsset(a);
        }
      } while (_drainAgain);
    } catch (e) {
      debugPrint('PhotoCaptureService._drainNewAssets: $e');
    } finally {
      _draining = false;
    }
  }

  Future<List<AssetEntity>> _fetchNewAssets() async {
    final albums = await PhotoManager.getAssetPathList(
      onlyAll: true,
      type: RequestType.image,
    );
    if (albums.isEmpty) return const [];
    final recent = await albums.first.getAssetListRange(start: 0, end: 40);
    // Marge de 5 s : tolérance sur l'écart d'horloge entre la création de
    // l'asset (rapportée par le MediaStore) et notre `_sessionStart`.
    final floor = _sessionStart.subtract(const Duration(seconds: 5));
    return recent
        .where((a) =>
            !_processedAssetIds.contains(a.id) &&
            !a.createDateTime.isBefore(floor))
        .toList();
  }

  Future<void> _ingestAsset(AssetEntity a) async {
    final src = await a.originFile ?? await a.file;
    if (src == null) return;
    final ts = a.createDateTime;
    final pos = await recordingService.acquireFixNow();
    final dest = await _copyIntoMeshiker(src, ts);
    if (dest == null) return;
    await _ingestPhoto(dest.path, pos, ts);
  }

  Future<void> _endSession({bool silent = false}) async {
    if (!sessionActive.value) return;
    sessionActive.value = false;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    WidgetsBinding.instance.removeObserver(this);
    if (_changeCallbackRegistered) {
      PhotoManager.removeChangeCallback(_onGalleryChange);
      _changeCallbackRegistered = false;
    }
    await PhotoManager.stopChangeNotify();

    // Dernier passage temps réel, puis filet de rattrapage : toute photo
    // présente sur disque dans la fenêtre de session mais non captée
    // (process tué par l'OS) se voit assigner la position connue la plus
    // proche dans le temps (spec §3.3).
    await _drainNewAssets();
    await _reconcileMissedPhotos();

    if (!silent) {
      final n = _sessionWaypoints.fold<int>(0, (s, w) => s + w.photoPaths.length);
      if (n > 0) {
        message.value = n == 1
            ? '1 photo ajoutée à la carte.'
            : '$n photos ajoutées à la carte.';
      }
      _maybeOpenPopup();
    }
  }

  Future<void> _reconcileMissedPhotos() async {
    final files =
        await _scanner.scanPhotosBetween(_sessionStart, DateTime.now());
    for (final f in files) {
      if (_copiedBasenames.contains(p.basename(f.path))) continue;
      final ts = f.lastModifiedSync();
      final pos = _nearestFixInTime(ts) ??
          await recordingService.acquireFixNow();
      await _ingestPhoto(f.path, pos, ts);
    }
  }

  geo.Position? _nearestFixInTime(DateTime t) {
    if (_sessionFixes.isEmpty) return null;
    _sessionFixes.sort((a, b) => (a.time.difference(t)).abs().compareTo(
        (b.time.difference(t)).abs()));
    return _sessionFixes.first.pos;
  }

  // ---------------------------------------------------------------------------
  // Stockage + clustering + rattachement trace
  // ---------------------------------------------------------------------------
  Future<File?> _copyIntoMeshiker(File src, DateTime ts) async {
    try {
      final dir = Directory(await _scanner.getPublicMeshikerPath());
      if (!await dir.exists()) await dir.create(recursive: true);
      final name =
          'meshiker_${ts.millisecondsSinceEpoch}_${p.basename(src.path)}';
      final dest = File(p.join(dir.path, name));
      if (!await dest.exists()) {
        await src.copy(dest.path);
        await _scanner.scanFileForGallery(dest.path);
      }
      _copiedBasenames.add(p.basename(dest.path));
      return dest;
    } catch (e) {
      debugPrint('PhotoCaptureService._copyIntoMeshiker: $e');
      return null;
    }
  }

  Future<void> _ingestPhoto(
      String path, geo.Position? pos, DateTime ts) async {
    // Pas de fix exploitable : on rattache la photo au dernier waypoint photo
    // de la session s'il existe, sinon on renonce à la géolocaliser (elle
    // reste dans la galerie, récupérable manuellement).
    if (pos == null) {
      if (_sessionWaypoints.isNotEmpty) {
        await _appendPhoto(_sessionWaypoints.last, path);
      }
      return;
    }

    _sessionFixes.add((time: ts, pos: pos));

    final radius = settingsService.photoClusterRadiusMeters;
    final nearby = await isarService.nearbyPhotoWaypoints(
      latitude: pos.latitude,
      longitude: pos.longitude,
      radiusMeters: radius,
    );
    if (nearby.isNotEmpty) {
      nearby.sort((a, b) => GeoUtils.haversineMeters(
              pos.latitude, pos.longitude, a.latitude, a.longitude)
          .compareTo(GeoUtils.haversineMeters(
              pos.latitude, pos.longitude, b.latitude, b.longitude)));
      await _appendPhoto(nearby.first, path);
      return;
    }

    final cat = await isarService.ensurePhotoCategory();
    final wp = Waypoint()
      ..localUuid = _uuid.v4()
      ..name = _defaultName(ts)
      ..latitude = pos.latitude
      ..longitude = pos.longitude
      ..isPhotoWaypoint = true
      ..photoPaths = [path]
      ..headerPhotoIndex = 0
      // Rattachement trace : réutilisation intégrale de la logique de l'appui
      // long sur la carte (spec §6) — même source, `roadmapTraceName`.
      ..associatedGpxName = settingsService.roadmapTraceName;
    wp.category.value = cat;
    await isarService.saveWaypoint(wp);
    _sessionWaypoints.add(wp);
    mapViewModel.refreshNow();
  }

  Future<void> _appendPhoto(Waypoint wp, String path) async {
    if (wp.photoPaths.contains(path)) return;
    wp.photoPaths = [...wp.photoPaths, path];
    await isarService.saveWaypoint(wp);
    if (!_sessionWaypoints.contains(wp)) _sessionWaypoints.add(wp);
    mapViewModel.refreshNow();
  }

  void _maybeOpenPopup() {
    if (settingsService.showPhotoEditPopup && _sessionWaypoints.isNotEmpty) {
      pendingEditWaypoint.value = _sessionWaypoints.last;
    }
  }

  String _defaultName(DateTime ts) {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'Photo ${two(ts.day)}/${two(ts.month)} ${two(ts.hour)}:${two(ts.minute)}';
  }

  void dispose() {
    _timeoutTimer?.cancel();
    if (_changeCallbackRegistered) {
      PhotoManager.removeChangeCallback(_onGalleryChange);
    }
    WidgetsBinding.instance.removeObserver(this);
    pendingEditWaypoint.dispose();
    message.dispose();
    sessionActive.dispose();
  }
}
