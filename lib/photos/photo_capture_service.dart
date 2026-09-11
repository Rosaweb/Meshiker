import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart' as ph;
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
  // Préfixe des copies écrites par [_resolveStoredPath] dans
  // Pictures/Meshiker — sert aussi de marqueur pour reconnaître et ignorer
  // ces copies quand l'observateur de pellicule les redétecte (voir
  // _ingestAsset).
  static const _artifactPrefix = 'meshiker_';
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
    debugPrint('[PhotoCapture] photo_manager permission: ${permission.isAuth}/${permission.hasAccess}');
    if (!permission.hasAccess) {
      message.value =
          "Accès aux photos refusé : la détection des clichés est impossible.";
      return;
    }

    if (!await _ensureStoragePermission()) {
      debugPrint('[PhotoCapture] storage permission denied — aborting session');
      message.value =
          "Accès au stockage refusé : impossible d'enregistrer les photos.";
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
      debugPrint('[PhotoCapture] launchCamera failed: $e');
    }
    debugPrint('[PhotoCapture] session started, camera launched=$launched');
    if (!launched) {
      message.value = "Aucune application appareil photo n'a pu être lancée.";
      await _endSession(silent: true);
    }
  }

  /// Permission "Tous les fichiers" nécessaire pour écrire dans le dossier
  /// public partagé Pictures/Meshiker via un chemin brut `dart:io` (hors
  /// sandbox de l'app) — même gotcha déjà géré pour le dossier GPX custom
  /// dans `GpxScannerService.scanFolder`. Sans cette demande explicite,
  /// `_resolveStoredPath` échoue silencieusement sur chaque photo et aucun
  /// waypoint n'est jamais créé (cause du bug initial : la photo est bien
  /// prise par l'appli caméra système, mais Meshiker ne peut pas la copier
  /// ni donc la savoir).
  Future<bool> _ensureStoragePermission() async {
    if (!Platform.isAndroid) return true;
    var granted = (await ph.Permission.manageExternalStorage.status).isGranted;
    if (!granted) {
      granted = (await ph.Permission.manageExternalStorage.request()).isGranted;
    }
    if (!granted) {
      // Repli pour les appareils/versions où la permission spéciale n'est
      // pas proposée (ignorée par l'OS au-delà de l'API 32).
      granted = (await ph.Permission.storage.request()).isGranted;
    }
    return granted;
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
    final path = await _resolveStoredPath(File(shot.path), ts);
    await _ingestPhoto(path, pos, ts);
    _maybeOpenPopup();
  }

  // ---------------------------------------------------------------------------
  // Android : observateur de pellicule + cycle de vie
  // ---------------------------------------------------------------------------
  void _onGalleryChange(MethodCall _) {
    if (!sessionActive.value) return;
    debugPrint('[PhotoCapture] gallery change notification received');
    unawaited(_drainNewAssets());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!sessionActive.value) return;
    debugPrint('[PhotoCapture] lifecycle state: $state (sawBackground=$_sawBackground)');
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
      // Sans cet ordre explicite, le plugin n'ajoute AUCUN "ORDER BY" à la
      // requête MediaStore native (voir CommonFilterOption.orderByCondString,
      // qui renvoie null si `orders` est vide) : sur un appareil dont la
      // pellicule contient plus de 40 photos, `getAssetListRange(0, 40)`
      // renvoyait alors un lot arbitraire (souvent les plus ANCIENNES,
      // ordre d'insertion) au lieu des plus récentes — la photo qu'on vient
      // de prendre n'était donc jamais dans la fenêtre observée. Cause du
      // bug "permission accordée mais toujours aucune photo détectée".
      filterOption: FilterOptionGroup(orders: [const OrderOption()]),
    );
    if (albums.isEmpty) return const [];
    final recent = await albums.first.getAssetListRange(start: 0, end: 40);
    // Marge de 5 s : tolérance sur l'écart d'horloge entre la création de
    // l'asset (rapportée par le MediaStore) et notre `_sessionStart`.
    final floor = _sessionStart.subtract(const Duration(seconds: 5));
    final fresh = recent
        .where((a) =>
            !_processedAssetIds.contains(a.id) &&
            !a.createDateTime.isBefore(floor))
        .toList();
    debugPrint('[PhotoCapture] fetchNewAssets: ${recent.length} scanned, ${fresh.length} new');
    return fresh;
  }

  Future<void> _ingestAsset(AssetEntity a) async {
    final src = await a.originFile ?? await a.file;
    if (src == null) {
      debugPrint('[PhotoCapture] asset ${a.id} has no accessible file, skipped');
      return;
    }
    if (p.basename(src.path).startsWith(_artifactPrefix)) {
      // Notre propre copie dans Pictures/Meshiker : `_resolveStoredPath`
      // appelle `scanFileForGallery` (MediaScannerConnection) dessus pour
      // qu'elle apparaisse tout de suite dans la galerie système, ce qui la
      // fait ré-indexer par le MediaStore comme un NOUVEL asset — et donc
      // remonter ici à son tour via l'observateur de pellicule. Sans ce
      // garde-fou, chaque photo déclenchait une boucle de rétroaction
      // (copie de la copie -> nouveau scan -> nouvelle détection -> ...)
      // tant que la session restait ouverte : la première photo se
      // retrouvait dupliquée un nombre variable de fois (constaté : 8 puis
      // 3 exemplaires selon le temps resté dans l'appli caméra avant de
      // revenir à Meshiker).
      debugPrint('[PhotoCapture] skipping our own artifact ${src.path}');
      return;
    }
    final ts = a.createDateTime;
    final pos = await recordingService.acquireFixNow();
    final path = await _resolveStoredPath(src, ts);
    debugPrint('[PhotoCapture] ingesting $path (fix=${pos != null})');
    await _ingestPhoto(path, pos, ts);
  }

  Future<void> _endSession({bool silent = false}) async {
    if (!sessionActive.value) return;
    debugPrint('[PhotoCapture] ending session (silent=$silent)');
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
      debugPrint('[PhotoCapture] session ended: $n photo(s) ingested, ${_sessionWaypoints.length} waypoint(s)');
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
    debugPrint('[PhotoCapture] reconcile: ${files.length} file(s) in Pictures/Meshiker window');
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
  /// Copie [src] dans Pictures/Meshiker pour cohérence avec le stockage
  /// photo déjà en place (spec §3.2). Ne renvoie JAMAIS `null` : si la copie
  /// échoue (permission stockage refusée, disque plein, chemin OEM
  /// inattendu...), on retombe sur le fichier ORIGINAL plutôt que
  /// d'abandonner la photo — mieux vaut un waypoint pointant vers son
  /// emplacement d'origine (DCIM) qu'un waypoint jamais créé.
  Future<String> _resolveStoredPath(File src, DateTime ts) async {
    try {
      final dir = Directory(await _scanner.getPublicMeshikerPath());
      if (!await dir.exists()) await dir.create(recursive: true);
      final name =
          '$_artifactPrefix${ts.millisecondsSinceEpoch}_${p.basename(src.path)}';
      final dest = File(p.join(dir.path, name));
      if (!await dest.exists()) {
        await src.copy(dest.path);
        await _scanner.scanFileForGallery(dest.path);
      }
      _copiedBasenames.add(p.basename(dest.path));
      return dest.path;
    } catch (e) {
      debugPrint('[PhotoCapture] copy into Pictures/Meshiker failed ($e), '
          'keeping original path ${src.path}');
      return src.path;
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
    debugPrint('[PhotoCapture] created waypoint ${wp.localUuid} for $path');
    mapViewModel.refreshNow();
  }

  Future<void> _appendPhoto(Waypoint wp, String path) async {
    if (wp.photoPaths.contains(path)) return;
    wp.photoPaths = [...wp.photoPaths, path];
    await isarService.saveWaypoint(wp);
    if (!_sessionWaypoints.contains(wp)) _sessionWaypoints.add(wp);
    debugPrint('[PhotoCapture] appended $path to waypoint ${wp.localUuid}');
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
