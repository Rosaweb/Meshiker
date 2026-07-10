import 'package:isar_community/isar.dart';

import 'enums.dart';
import 'gps_point.dart';

part 'recording_draft.g.dart';

/// Métadonnées d'une session d'enregistrement GPS EN COURS ou interrompue.
///
/// Ces trois collections (RecordingDraft, RecordingPointBatch,
/// RecordingModeOverride) ne font PAS partie du modèle définitif de la
/// toile d'araignée (Segment/Trace/PointOfInterest) : ce sont des données
/// provisoires, écrites au fil de l'eau pendant la randonnée, puis
/// entièrement supprimées une fois `RecordingService.stop()` les a
/// converties en Trace + Segments définitifs via `SegmentationEngine`.
///
/// Leur existence répond à une exigence précise du brief : un
/// "Foreground Service ROBUSTE". Sans persistance incrémentale, un
/// enregistrement de plusieurs heures perdrait TOUT son contenu si l'OS
/// tuait le processus (bascule mémoire agressive de certains
/// constructeurs, redémarrage inopiné...), malgré la notification de
/// premier plan. Avec ce staging, on peut détecter au relancement de
/// l'app qu'un `RecordingDraft` existe sans `Trace` correspondante, et
/// proposer de le finaliser (voir `RecordingService.findAbandonedDraft`).
@collection
class RecordingDraft {
  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String sessionUuid;

  late String ownerUuid;

  @Enumerated(EnumType.ordinal)
  ActivityType activityType = ActivityType.hiking;

  DateTime startedAt = DateTime.now();
  bool isPaused = false;
  DateTime updatedAt = DateTime.now();
}

/// Un lot de points GPS bruts appartenant à une session d'enregistrement.
///
/// Volontairement stocké en petits lots successifs (append-only) plutôt
/// que comme une unique liste géante qu'il faudrait ré-écrire en entier à
/// chaque flush : sur un enregistrement de plusieurs heures (plusieurs
/// milliers de points), ré-écrire une liste croissante à chaque lot
/// coûterait de plus en plus cher (et de batterie) au fil de la
/// randonnée. Ajouter un nouveau petit objet reste, lui, à coût constant.
@collection
class RecordingPointBatch {
  Id id = Isar.autoIncrement;

  @Index()
  late String sessionUuid;

  /// Ordre d'écriture du lot au sein de la session (0, 1, 2...), utilisé
  /// pour reconstituer la trace complète dans le bon ordre à l'arrêt.
  int batchIndex = 0;

  List<PointGPS> points = [];

  /// `true` si le PREMIER point de ce lot marque une reprise après une
  /// pause (`RecordingService.pause()` puis `resume()`). Joue exactement
  /// le même rôle que `GpxTrackPoint.startsNewSegment` pour un GPX importé
  /// : un point de coupure légitime, la mesure ayant été réellement
  /// interrompue entre-temps.
  bool startsNewSegment = false;
}

/// Une bascule manuelle du mode routé/hors-piste ("aimant") décidée par
/// l'utilisateur pendant l'enregistrement. Voir `ModeOverride` (dans
/// `segmentation_engine.dart`) pour la version en mémoire consommée par
/// `SegmentationEngine` ; cette collection n'est que sa persistance.
@collection
class RecordingModeOverride {
  Id id = Isar.autoIncrement;

  @Index()
  late String sessionUuid;

  DateTime at = DateTime.now();

  @Enumerated(EnumType.ordinal)
  SegmentMode mode = SegmentMode.routed;
}
