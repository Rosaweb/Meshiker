import '../models/enums.dart';
import '../models/gps_point.dart';
import '../models/point_of_interest.dart';
import '../models/segment.dart';
import '../utils/geo_utils.dart';

/// Conversions entre les lignes JSON renvoyees par Supabase et les
/// modeles Dart locaux -- le sens "pull" uniquement. Le sens "push"
/// utilise deja Syncable.toSupabaseMap() (voir etape 1), qui reste
/// suffisant pour construire les payloads envoyes aux fonctions RPC de
/// functions.sql.
class SupabaseMapper {
  const SupabaseMapper._();

  /// Convertit des coordonnees GeoJSON (points_geojson renvoye par
  /// segments_in_viewport) en PointGPS.
  ///
  /// ATTENTION A L'ORDRE : GeoJSON encode chaque point [longitude,
  /// latitude, altitude?] -- L'INVERSE de l'ordre lat/lon utilise partout
  /// ailleurs dans cette app (PointGPS.latitude avant longitude,
  /// GpxTrackPoint, etc.). Une confusion ici inverserait silencieusement
  /// la position de chaque segment importe de la communaute.
  static List<PointGPS> pointsFromGeoJsonCoordinates(List<dynamic> coordinates) {
    return coordinates.map((raw) {
      final coord = (raw as List).cast<num>();
      return PointGPS.create(
        latitude: coord[1].toDouble(),
        longitude: coord[0].toDouble(),
        altitude: coord.length > 2 ? coord[2].toDouble() : null,
        // Un segment tire de la communaute est une geometrie canonique
        // partagee, pas un enregistrement personnel horodate point par
        // point (cette information n'existe d'ailleurs plus une fois la
        // geometrie fusionnee cote serveur) : l'horodatage ici n'a pas de
        // valeur informative, seule la position compte.
        timestamp: DateTime.now(),
      );
    }).toList();
  }

  /// Reconstruit un Segment local a partir d'une ligne renvoyee par
  /// segments_in_viewport (un segment decouvert cote serveur, absent de
  /// la base locale jusqu'ici).
  static Segment segmentFromViewportRow(Map<String, dynamic> row) {
    final points = pointsFromGeoJsonCoordinates(
      (row['points_geojson'] as List).cast<dynamic>(),
    );
    final bbox = GeoUtils.boundingBox(
      points.map((p) => (lat: p.latitude, lon: p.longitude)),
    )!;
    final remoteId = row['id'] as String;

    return Segment()
      ..localUuid = (row['local_uuid'] as String?) ?? remoteId
      ..remoteId = remoteId
      ..authorUuid = row['author_id'] as String?
      ..points = points
      ..mode = SegmentMode.values.byName(row['mode'] as String)
      ..distanceMeters = (row['distance_meters'] as num).toDouble()
      ..elevationGainMeters = (row['elevation_gain_meters'] as num).toDouble()
      ..elevationLossMeters = (row['elevation_loss_meters'] as num).toDouble()
      ..difficulty = DifficultyLevel.values.byName(row['difficulty'] as String)
      ..reliabilityIndex = (row['reliability_index'] as num?)?.toDouble()
      ..passageCount = row['passage_count'] as int? ?? 1
      ..lastPassageAt = row['last_passage_at'] != null
          ? DateTime.parse(row['last_passage_at'] as String)
          : null
      ..minLat = bbox.minLat
      ..maxLat = bbox.maxLat
      ..minLon = bbox.minLon
      ..maxLon = bbox.maxLon
      ..geohashPrefix =
          GeoUtils.geohash(points.first.latitude, points.first.longitude)
      // Deja synchronise par definition : cette entite vient du serveur,
      // il n'y a rien a pousser pour elle.
      ..syncStatus = SyncStatus.synced
      ..createdAt = DateTime.now()
      ..updatedAt = DateTime.now();
  }

  /// Reconstruit un PointOfInterest local a partir d'une ligne renvoyee
  /// par pois_in_viewport.
  static PointOfInterest poiFromViewportRow(Map<String, dynamic> row) {
    final lat = (row['latitude'] as num).toDouble();
    final lon = (row['longitude'] as num).toDouble();
    final remoteId = row['id'] as String;

    return PointOfInterest()
      ..localUuid = (row['local_uuid'] as String?) ?? remoteId
      ..remoteId = remoteId
      ..authorUuid = row['author_id'] as String?
      ..name = row['name'] as String
      ..description = row['description'] as String?
      ..type = POIType.values.byName(row['type'] as String)
      ..location = PointGPS.create(
        latitude: lat,
        longitude: lon,
        timestamp: DateTime.now(),
      )
      ..latitude = lat
      ..longitude = lon
      ..geohashPrefix = GeoUtils.geohash(lat, lon)
      ..timesReferenced = row['times_referenced'] as int? ?? 1
      ..syncStatus = SyncStatus.synced
      ..createdAt = DateTime.now()
      ..updatedAt = DateTime.now();
  }
}
