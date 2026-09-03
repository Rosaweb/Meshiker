import 'package:flutter_test/flutter_test.dart';
import 'package:meshiker/utils/crash_reporting_service.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

SentryEvent _eventWithFrames(List<SentryStackFrame> frames, {String type = 'StateError'}) {
  return SentryEvent(
    exceptions: [
      SentryException(
        type: type,
        value: 'boom',
        stackTrace: SentryStackTrace(frames: frames),
      ),
    ],
  );
}

void main() {
  group('computeFingerprint', () {
    test('uses the innermost in-app frame, ignoring framework frames above it', () {
      final event = _eventWithFrames([
        SentryStackFrame(fileName: 'framework.dart', lineNo: 10, inApp: false),
        SentryStackFrame(fileName: 'recording_service.dart', lineNo: 42, inApp: true),
        SentryStackFrame(fileName: 'flutter_binding.dart', lineNo: 99, inApp: false),
      ]);

      expect(CrashReportingService.computeFingerprint(event), 'StateError@recording_service.dart:42');
    });

    test('two occurrences of the same crash produce the same fingerprint', () {
      final frames = [
        SentryStackFrame(fileName: 'segmentation_engine.dart', lineNo: 7, inApp: true),
      ];
      final first = _eventWithFrames(frames);
      final second = _eventWithFrames(frames);

      expect(CrashReportingService.computeFingerprint(first),
          CrashReportingService.computeFingerprint(second));
    });

    test('a different exception type at the same location is a different fingerprint', () {
      final frames = [
        SentryStackFrame(fileName: 'segmentation_engine.dart', lineNo: 7, inApp: true),
      ];

      expect(
        CrashReportingService.computeFingerprint(_eventWithFrames(frames, type: 'StateError')),
        isNot(CrashReportingService.computeFingerprint(_eventWithFrames(frames, type: 'RangeError'))),
      );
    });

    test('falls back to the last frame when none are marked in-app', () {
      final event = _eventWithFrames([
        SentryStackFrame(fileName: 'a.dart', lineNo: 1, inApp: false),
        SentryStackFrame(fileName: 'b.dart', lineNo: 2, inApp: false),
      ]);

      expect(CrashReportingService.computeFingerprint(event), 'StateError@b.dart:2');
    });
  });

  group('scrubPii', () {
    test('drops extra entries whose key looks like a GPS coordinate', () {
      // ignore: deprecated_member_use
      final event = SentryEvent(extra: {'latitude': 45.0, 'note': 'kept'});

      // ignore: deprecated_member_use
      final scrubbed = CrashReportingService.scrubPii(event).extra;

      expect(scrubbed, isNotNull);
      expect(scrubbed!.containsKey('latitude'), isFalse);
      expect(scrubbed['note'], 'kept');
    });

    test('drops tags whose key looks like a position field', () {
      final event = SentryEvent(tags: {'last_known_gps': '1,2', 'screen': 'map'});

      final scrubbed = CrashReportingService.scrubPii(event).tags;

      expect(scrubbed, isNotNull);
      expect(scrubbed!.containsKey('last_known_gps'), isFalse);
      expect(scrubbed['screen'], 'map');
    });

    test('drops breadcrumbs carrying position data, keeps unrelated ones', () {
      final event = SentryEvent(breadcrumbs: [
        Breadcrumb(message: 'user tapped save', data: {'lon': 5.9}),
        Breadcrumb(message: 'opened settings screen'),
      ]);

      final scrubbed = CrashReportingService.scrubPii(event).breadcrumbs;

      expect(scrubbed, hasLength(1));
      expect(scrubbed!.single.message, 'opened settings screen');
    });

    test('leaves the event untouched when nothing looks like PII', () {
      final event = SentryEvent(tags: {'screen': 'map'});

      final scrubbed = CrashReportingService.scrubPii(event);

      expect(scrubbed.tags, event.tags);
    });
  });
}
