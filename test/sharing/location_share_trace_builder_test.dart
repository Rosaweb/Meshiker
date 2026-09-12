import 'package:flutter_test/flutter_test.dart';
import 'package:meshiker/models/enums.dart';
import 'package:meshiker/sharing/location_share_models.dart';
import 'package:meshiker/sharing/location_share_trace_builder.dart';

LocationPing _ping({
  required int id,
  required double lat,
  required double lng,
  double? altitude,
  required DateTime recordedAt,
}) =>
    LocationPing(
      id: id,
      shareId: 'share-1',
      userId: 'user-1',
      lat: lat,
      lng: lng,
      altitude: altitude,
      recordedAt: recordedAt,
    );

void main() {
  group('LocationShareTraceBuilder.buildLocalOnly', () {
    test('lève une erreur avec moins de 2 points', () {
      final pings = [_ping(id: 1, lat: 45.0, lng: 6.0, recordedAt: DateTime(2026, 1, 1))];
      expect(
        () => LocationShareTraceBuilder.buildLocalOnly(
          pings: pings,
          ownerUuid: 'owner-1',
          traceName: 'Test',
        ),
        throwsArgumentError,
      );
    });

    test('exclut systématiquement la trace et le segment du sync (spec §8.4)', () {
      final pings = [
        _ping(id: 1, lat: 45.0, lng: 6.0, altitude: 1000, recordedAt: DateTime(2026, 1, 1, 8, 0)),
        _ping(id: 2, lat: 45.001, lng: 6.001, altitude: 1010, recordedAt: DateTime(2026, 1, 1, 8, 1)),
      ];

      final result = LocationShareTraceBuilder.buildLocalOnly(
        pings: pings,
        ownerUuid: 'owner-1',
        traceName: 'Battue du 12 septembre',
      );

      expect(result.trace.syncStatus, SyncStatus.excluded);
      expect(result.trace.visibility, TraceVisibility.private);
      expect(result.segmentsToUpsert, hasLength(1));
      expect(result.segmentsToUpsert.first.syncStatus, SyncStatus.excluded);
    });

    test('calcule bbox, distance et lie le segment à la trace dans l\'ordre', () {
      final start = DateTime(2026, 1, 1, 8, 0);
      final end = DateTime(2026, 1, 1, 8, 10);
      final pings = [
        _ping(id: 1, lat: 45.0, lng: 6.0, recordedAt: start),
        _ping(id: 2, lat: 45.01, lng: 6.01, recordedAt: end),
      ];

      final result = LocationShareTraceBuilder.buildLocalOnly(
        pings: pings,
        ownerUuid: 'owner-1',
        traceName: 'Test',
      );

      final segment = result.segmentsToUpsert.first;
      expect(segment.minLat, 45.0);
      expect(segment.maxLat, 45.01);
      expect(segment.minLon, 6.0);
      expect(segment.maxLon, 6.01);
      // ~1.3 km entre les deux points (45.0,6.0) et (45.01,6.01).
      expect(segment.distanceMeters, greaterThan(1000));
      expect(segment.distanceMeters, lessThan(1600));
      expect(segment.geohashPrefix, isNotEmpty);

      expect(result.trace.segments, hasLength(1));
      expect(result.trace.segments.first.segmentUuid, segment.localUuid);
      expect(result.trace.segments.first.orderIndex, 0);
      expect(result.trace.startedAt, start);
      expect(result.trace.endedAt, end);
      expect(result.trace.ownerUuid, 'owner-1');
      expect(result.trace.name, 'Test');
    });

    test('gère une altitude entièrement absente sans lever d\'exception', () {
      final pings = [
        _ping(id: 1, lat: 45.0, lng: 6.0, recordedAt: DateTime(2026, 1, 1, 8, 0)),
        _ping(id: 2, lat: 45.001, lng: 6.001, recordedAt: DateTime(2026, 1, 1, 8, 1)),
      ];

      final result = LocationShareTraceBuilder.buildLocalOnly(
        pings: pings,
        ownerUuid: 'owner-1',
        traceName: 'Sans altitude',
      );

      expect(result.segmentsToUpsert.first.avgAltitude, 0);
    });
  });
}
