import 'package:isar_community/isar.dart';

import 'enums.dart';
import 'syncable.dart';
import 'trace_segment_entry.dart';

part 'trace.g.dart';

/// Une trace est l'itinéraire tel que vécu par un utilisateur : une
/// séquence ORDONNÉE de [Segment] (chacun potentiellement partagé avec
/// d'autres traces). Elle ne duplique jamais la géométrie : elle ne
/// stocke que des références légères ([TraceSegmentEntry]) vers des
/// segments qui vivent dans leur propre collection.
@collection
class Trace implements Syncable {
  Trace();

  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String localUuid;

  @override
  String? remoteId;

  /// UUID de l'utilisateur propriétaire de la trace (voir [Utilisateur]).
  @Index()
  late String ownerUuid;

  String name = '';
  String? description;

  /// Séquence ordonnée de segments composant l'itinéraire. C'est ici, et
  /// uniquement ici, que vit la notion d'ordre et de sens de parcours —
  /// jamais dans [Segment], qui reste neutre et partageable entre traces.
  List<TraceSegmentEntry> segments = [];

  double totalDistanceMeters = 0;
  double totalElevationGainMeters = 0;
  double totalElevationLossMeters = 0;

  @Enumerated(EnumType.ordinal)
  ActivityType activityType = ActivityType.hiking;

  @Enumerated(EnumType.ordinal)
  TraceVisibility visibility = TraceVisibility.private;

  DateTime startedAt = DateTime.now();
  DateTime? endedAt;

  @override
  @Index()
  @Enumerated(EnumType.ordinal)
  SyncStatus syncStatus = SyncStatus.pending;

  DateTime createdAt = DateTime.now();

  @override
  DateTime updatedAt = DateTime.now();

  @override
  Map<String, dynamic> toSupabaseMap() => {
        'id': remoteId ?? localUuid,
        'local_uuid': localUuid,
        'owner_id': ownerUuid,
        'name': name,
        'description': description,
        'total_distance_meters': totalDistanceMeters,
        'total_elevation_gain_meters': totalElevationGainMeters,
        'total_elevation_loss_meters': totalElevationLossMeters,
        'activity_type': activityType.name,
        'visibility': visibility.name,
        'started_at': startedAt.toIso8601String(),
        'ended_at': endedAt?.toIso8601String(),
        // La table de jointure `trace_segments` est alimentée séparément,
        // une ligne par entrée de `segments` (voir schema.sql) : on
        // l'expose ici sous forme de liste pour que le futur moteur de
        // sync sache quoi upserter côté serveur.
        'segments': segments
            .map((s) => {
                  'segment_uuid': s.segmentUuid,
                  'order_index': s.orderIndex,
                  'traveled_forward': s.traveledForward,
                })
            .toList(),
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };
}
