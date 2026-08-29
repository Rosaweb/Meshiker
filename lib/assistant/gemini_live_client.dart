import 'dart:convert';

/// Encodage/décodage des messages JSON du protocole `BidiGenerateContent`
/// de la Live API Gemini (https://ai.google.dev/api/live), utilisé par
/// l'assistant IA conversationnel (manuel d'aide, v1).
///
/// Volontairement sans dépendance à une connexion WebSocket ni à un package
/// audio : ne fait que construire/interpréter des messages JSON, testable
/// unitairement — même esprit que `SegmentationEngine`. L'ouverture de la
/// connexion et la capture/lecture audio sont la responsabilité
/// d'`AssistantService`.
class GeminiLiveClient {
  const GeminiLiveClient._();

  /// Premier message à envoyer après l'ouverture de la connexion. Les
  /// champs verrouillés côté token éphémère (modèle, system instructions,
  /// tools, cf. `assistant-token`) écrasent de toute façon ce qui est
  /// envoyé ici — seul le modèle est requis pour un message de setup valide.
  static Map<String, dynamic> buildSetupMessage({required String model}) {
    return {
      'setup': {'model': model},
    };
  }

  /// Question posée sous forme de texte tapé (section Aide ou volet
  /// Navigation). `turnComplete: true` car il n'y a qu'un seul tour par
  /// question (session courte ouverte à la demande, pas de conversation
  /// continue en v1).
  static Map<String, dynamic> buildTextTurn(String text) {
    return {
      'clientContent': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': text},
            ],
          },
        ],
        'turnComplete': true,
      },
    };
  }

  /// Un fragment du flux micro. La détection de fin de tour est gérée
  /// nativement par la Live API (VAD serveur) — pas besoin d'un signal de
  /// fin de flux explicite en usage normal, cf.
  /// plan-implementation-assistant-ia-v1.md section 3.
  static Map<String, dynamic> buildAudioChunk(List<int> pcm16Bytes, {int sampleRateHz = 16000}) {
    return {
      'realtimeInput': {
        'audio': {
          'data': base64Encode(pcm16Bytes),
          'mimeType': 'audio/pcm;rate=$sampleRateHz',
        },
      },
    };
  }

  /// Interprète un message serveur déjà décodé en JSON. Un seul message
  /// peut porter plusieurs événements à la fois (ex. un dernier fragment
  /// audio ET la fin de tour dans le même `serverContent`), d'où une liste
  /// en retour plutôt qu'un événement unique.
  static List<GeminiLiveServerEvent> parseServerMessage(Map<String, dynamic> json) {
    final events = <GeminiLiveServerEvent>[];

    if (json.containsKey('setupComplete')) {
      events.add(const GeminiLiveSetupComplete());
    }

    final serverContent = json['serverContent'] as Map<String, dynamic>?;
    if (serverContent != null) {
      final parts = (serverContent['modelTurn'] as Map<String, dynamic>?)?['parts'] as List<dynamic>?;
      if (parts != null) {
        for (final part in parts) {
          final data = ((part as Map<String, dynamic>)['inlineData'] as Map<String, dynamic>?)?['data'] as String?;
          if (data != null) {
            events.add(GeminiLiveAudioChunk(base64Decode(data)));
          }
        }
      }
      if (serverContent['interrupted'] == true) {
        events.add(const GeminiLiveInterrupted());
      }
      if (serverContent['turnComplete'] == true) {
        events.add(const GeminiLiveTurnComplete());
      }
    }

    if (json.containsKey('error')) {
      events.add(GeminiLiveError(json['error'] as Map<String, dynamic>));
    }

    if (events.isEmpty) {
      events.add(GeminiLiveUnknownEvent(json));
    }

    return events;
  }

  /// Encode un message client (setup/clientContent/realtimeInput) prêt à
  /// être envoyé sur le WebSocket.
  static String encode(Map<String, dynamic> message) => jsonEncode(message);
}

/// Événements possibles reçus du serveur Gemini Live, après décodage.
sealed class GeminiLiveServerEvent {
  const GeminiLiveServerEvent();
}

/// La session est prête ; le client peut commencer à envoyer du contenu.
final class GeminiLiveSetupComplete extends GeminiLiveServerEvent {
  const GeminiLiveSetupComplete();
}

/// Un fragment audio PCM de la réponse du modèle (24kHz, cf. doc Gemini).
final class GeminiLiveAudioChunk extends GeminiLiveServerEvent {
  final List<int> pcmBytes;
  const GeminiLiveAudioChunk(this.pcmBytes);
}

/// L'utilisateur a recommencé à parler pendant que le modèle répondait.
final class GeminiLiveInterrupted extends GeminiLiveServerEvent {
  const GeminiLiveInterrupted();
}

/// Le modèle a fini de répondre pour ce tour — la session peut se refermer
/// (question/réponse ponctuelle, cf. décision UX du plan v1).
final class GeminiLiveTurnComplete extends GeminiLiveServerEvent {
  const GeminiLiveTurnComplete();
}

/// Erreur renvoyée par le serveur (ex. token expiré, quota).
final class GeminiLiveError extends GeminiLiveServerEvent {
  final Map<String, dynamic> raw;
  const GeminiLiveError(this.raw);
}

/// Message reçu mais non reconnu par ce client (champ futur non géré en
/// v1, ex. tool calls — différés en v2).
final class GeminiLiveUnknownEvent extends GeminiLiveServerEvent {
  final Map<String, dynamic> raw;
  const GeminiLiveUnknownEvent(this.raw);
}
