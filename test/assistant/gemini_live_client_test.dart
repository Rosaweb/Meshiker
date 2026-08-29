import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshiker/assistant/gemini_live_client.dart';

void main() {
  group('outgoing messages', () {
    test('setup message carries only the model', () {
      final message = GeminiLiveClient.buildSetupMessage(model: 'models/gemini-3.1-flash-live-preview');

      expect(message, {
        'setup': {'model': 'models/gemini-3.1-flash-live-preview'},
      });
    });

    test('text turn is marked complete', () {
      final message = GeminiLiveClient.buildTextTurn('Comment créer un waypoint ?');

      expect(message['clientContent']['turnComplete'], isTrue);
      expect(message['clientContent']['turns'][0]['role'], 'user');
      expect(message['clientContent']['turns'][0]['parts'][0]['text'], 'Comment créer un waypoint ?');
    });

    test('audio chunk is base64-encoded with the sample rate in mimeType', () {
      final message = GeminiLiveClient.buildAudioChunk([1, 2, 3, 4], sampleRateHz: 16000);

      expect(message['realtimeInput']['audio']['mimeType'], 'audio/pcm;rate=16000');
      expect(message['realtimeInput']['audio']['data'], base64Encode([1, 2, 3, 4]));
    });

    test('encode produces valid JSON', () {
      final encoded = GeminiLiveClient.encode(GeminiLiveClient.buildTextTurn('test'));

      expect(() => jsonDecode(encoded), returnsNormally);
    });
  });

  group('incoming messages', () {
    test('parses setupComplete', () {
      final events = GeminiLiveClient.parseServerMessage({'setupComplete': {}});

      expect(events, [isA<GeminiLiveSetupComplete>()]);
    });

    test('parses a single audio chunk from modelTurn parts', () {
      final audioB64 = base64Encode([10, 20, 30]);
      final events = GeminiLiveClient.parseServerMessage({
        'serverContent': {
          'modelTurn': {
            'parts': [
              {
                'inlineData': {'mimeType': 'audio/pcm;rate=24000', 'data': audioB64},
              },
            ],
          },
        },
      });

      expect(events, hasLength(1));
      final event = events.single as GeminiLiveAudioChunk;
      expect(event.pcmBytes, [10, 20, 30]);
    });

    test('parses an audio chunk and turnComplete from the same message', () {
      final audioB64 = base64Encode([1]);
      final events = GeminiLiveClient.parseServerMessage({
        'serverContent': {
          'modelTurn': {
            'parts': [
              {
                'inlineData': {'data': audioB64},
              },
            ],
          },
          'turnComplete': true,
        },
      });

      expect(events, [isA<GeminiLiveAudioChunk>(), isA<GeminiLiveTurnComplete>()]);
    });

    test('parses interrupted', () {
      final events = GeminiLiveClient.parseServerMessage({
        'serverContent': {'interrupted': true},
      });

      expect(events, [isA<GeminiLiveInterrupted>()]);
    });

    test('parses an error payload', () {
      final events = GeminiLiveClient.parseServerMessage({
        'error': {'code': 401, 'message': 'token expired'},
      });

      final event = events.single as GeminiLiveError;
      expect(event.raw['code'], 401);
    });

    test('falls back to an unknown event for unrecognized payloads', () {
      final events = GeminiLiveClient.parseServerMessage({'toolCall': {}});

      expect(events, [isA<GeminiLiveUnknownEvent>()]);
    });

    test('ignores text parts (no transcript UI in v1) without dropping the audio', () {
      final audioB64 = base64Encode([5, 6]);
      final events = GeminiLiveClient.parseServerMessage({
        'serverContent': {
          'modelTurn': {
            'parts': [
              {'text': 'transcription ignorée en v1'},
              {
                'inlineData': {'data': audioB64},
              },
            ],
          },
        },
      });

      expect(events, [isA<GeminiLiveAudioChunk>()]);
      expect((events.single as GeminiLiveAudioChunk).pcmBytes, [5, 6]);
    });
  });
}
