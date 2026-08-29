import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../utils/supabase_bootstrap_service.dart';
import 'gemini_live_client.dart';

/// États d'une session assistant, exposés à l'UI (page Aide et volet
/// Navigation, cf. plan-implementation-assistant-ia-v1.md section 3) :
/// question/réponse ponctuelle, pas de conversation continue en v1.
enum AssistantSessionState {
  idle,
  connecting,
  listening,
  responding,
  offline,
  error,
}

/// Orchestrateur d'une session assistant IA (manuel d'aide, v1). Récupère un
/// token éphémère via l'Edge Function `assistant-token`, ouvre une connexion
/// WebSocket directe vers Gemini Live (aucun audio ne transite par
/// Supabase), envoie la question de l'utilisateur (texte ou flux micro) et
/// joue la réponse audio. La session se referme une fois la réponse reçue —
/// pas de session longue façon appel (décision actée avec l'utilisateur,
/// voir le plan).
///
/// Suit le même style que `RecordingService` : classe simple (pas un
/// `ChangeNotifier`), état exposé via des `ValueNotifier` individuels.
class AssistantService {
  AssistantService({
    required this.supabaseBootstrap,
    Connectivity? connectivity,
  }) : _connectivity = connectivity ?? Connectivity();

  final SupabaseBootstrapService supabaseBootstrap;
  final Connectivity _connectivity;

  final ValueNotifier<AssistantSessionState> state = ValueNotifier(AssistantSessionState.idle);
  final ValueNotifier<String?> lastErrorMessage = ValueNotifier(null);

  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  final FlutterSoundPlayer _player = FlutterSoundPlayer();
  bool _audioSessionOpen = false;
  bool _playerStreamStarted = false;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _wsSub;
  StreamController<Uint8List>? _micController;
  StreamSubscription<Uint8List>? _micSub;

  // `FlutterSoundPlayer.feedUint8FromStream` (donc `_feed` en interne) gère
  // son flow-control avec un unique `Completer` d'instance, pas une file —
  // un deuxième appel avant la fin du premier écrase le `Completer` en
  // cours plutôt que de s'y ajouter. Gemini envoie ses chunks audio par
  // rafales (plusieurs par seconde), donc appeler `feedUint8FromStream` en
  // fire-and-forget à chaque chunk (comme avant) provoque des appels
  // concurrents à `_feed` — cause du son haché et des plantages observés
  // le 2026-08-29. Cette file interne sérialise les appels : un seul
  // `feedUint8FromStream` à la fois, les autres chunks attendent leur tour.
  final Queue<Uint8List> _audioQueue = Queue<Uint8List>();
  bool _isFeedingAudio = false;

  static const _micSampleRateHz = 16000;
  static const _playbackSampleRateHz = 24000;

  // wss://.../v1alpha.GenerativeService.BidiGenerateContentConstrained est
  // le point d'entrée réservé aux tokens éphémères (vérifié empiriquement
  // le 2026-08-20, cf. plan-implementation-assistant-ia-v1.md — la variante
  // v1beta.GenerativeService.BidiGenerateContent rejette la connexion avec
  // "unregistered callers", même token, même query param).
  static Uri _liveUri(String token) => Uri.parse(
    'wss://generativelanguage.googleapis.com/ws/'
    'google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained'
    '?access_token=$token',
  );

  /// Pose une question tapée au clavier (section Aide, ou champ texte du
  /// volet Navigation).
  Future<void> askText(String text) async {
    if (text.trim().isEmpty) return;
    await _startSession(onReady: () => _sendClientMessage(GeminiLiveClient.buildTextTurn(text)));
  }

  /// Pose une question à voix haute (bouton micro). La détection de fin de
  /// tour est gérée nativement par la Live API (VAD serveur) : on arrête
  /// simplement d'envoyer le flux micro dès que le modèle commence à
  /// répondre (premier fragment audio reçu).
  Future<void> askVoice() async {
    final micStatus = await ph.Permission.microphone.request();
    if (!micStatus.isGranted) {
      _fail('Autorisation micro refusée. Activez-la dans les paramètres du téléphone pour utiliser l\'assistant à voix haute.');
      return;
    }
    await _startSession(onReady: _startMicStreaming);
  }

  /// Interrompt la session en cours (l'utilisateur quitte l'écran, ou
  /// annule explicitement) — coupe le micro, la connexion et la lecture
  /// audio immédiatement.
  Future<void> cancelSession() async {
    await _teardownSession();
    state.value = AssistantSessionState.idle;
    lastErrorMessage.value = null;
  }

  /// À appeler quand l'app n'a plus besoin de l'assistant (ex. fermeture
  /// définitive), pas entre deux questions — `cancelSession` suffit pour ça.
  Future<void> dispose() async {
    await _teardownSession();
    if (_audioSessionOpen) {
      await _recorder.closeRecorder();
      await _player.closePlayer();
      _audioSessionOpen = false;
    }
  }

  Future<void> _startSession({required void Function() onReady}) async {
    if (state.value != AssistantSessionState.idle) return;

    lastErrorMessage.value = null;

    final connectivityResults = await _connectivity.checkConnectivity();
    if (connectivityResults.every((r) => r == ConnectivityResult.none)) {
      state.value = AssistantSessionState.offline;
      return;
    }

    state.value = AssistantSessionState.connecting;

    final client = await _readySupabaseClient();
    if (client == null) {
      _fail('Impossible de contacter l\'assistant IA (compte non prêt).');
      return;
    }

    final Map<String, dynamic> tokenPayload;
    try {
      final response = await client.functions.invoke('assistant-token');
      if (response.status != 200) {
        throw Exception('assistant-token HTTP ${response.status}');
      }
      tokenPayload = response.data as Map<String, dynamic>;
    } catch (e) {
      _fail('Assistant indisponible pour le moment. Réessayez plus tard.');
      return;
    }

    final token = tokenPayload['token'] as String?;
    final model = tokenPayload['model'] as String?;
    if (token == null || model == null) {
      _fail('Réponse inattendue du serveur assistant.');
      return;
    }

    try {
      await _ensureAudioSessionOpen();
      await _startPlayerStream();
    } catch (e) {
      _fail('Impossible d\'initialiser l\'audio de l\'assistant.');
      return;
    }

    _openChannel(model: model, token: token, onSetupComplete: onReady);
  }

  Future<SupabaseClient?> _readySupabaseClient() async {
    final ready = await supabaseBootstrap.ensureReady();
    return ready ? supabaseBootstrap.clientOrNull : null;
  }

  void _openChannel({
    required String model,
    required String token,
    required void Function() onSetupComplete,
  }) {
    final channel = WebSocketChannel.connect(_liveUri(token));
    _channel = channel;

    var setupDone = false;
    _wsSub = channel.stream.listen(
      (raw) => _handleServerMessage(raw, () {
        if (!setupDone) {
          setupDone = true;
          onSetupComplete();
        }
      }),
      onError: (Object e) => _fail('Connexion assistant interrompue.'),
      onDone: () {
        if (state.value == AssistantSessionState.connecting ||
            state.value == AssistantSessionState.listening ||
            state.value == AssistantSessionState.responding) {
          _fail('Connexion assistant fermée de façon inattendue.');
        }
      },
      cancelOnError: true,
    );

    _sendClientMessage(GeminiLiveClient.buildSetupMessage(model: model));
  }

  void _sendClientMessage(Map<String, dynamic> message) {
    _channel?.sink.add(GeminiLiveClient.encode(message));
  }

  void _handleServerMessage(dynamic raw, void Function() onSetupComplete) {
    // La Live API envoie certains messages serveur (dont `setupComplete`,
    // vérifié empiriquement le 2026-08-29) sous forme de frame WebSocket
    // *binaire* plutôt que texte, même s'il ne s'agit que de JSON encodé en
    // UTF-8 — `dart:io`'s WebSocket (utilisé par `web_socket_channel`)
    // délivre alors `raw` comme `List<int>`, pas `String`. Sans ce
    // décodage, `raw as String` levait une exception silencieusement
    // avalée par le catch ci-dessous : `onSetupComplete` n'était jamais
    // appelé, la session restait ouverte et inerte jusqu'au timeout
    // serveur (~3 min) — cause du "Connexion assistant fermée de façon
    // inattendue" observé (texte ET vocal, les deux dépendent de
    // `setupComplete` pour progresser).
    final String text;
    if (raw is String) {
      text = raw;
    } else if (raw is List<int>) {
      text = utf8.decode(raw);
    } else {
      return;
    }

    final Map<String, dynamic> json;
    try {
      json = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    for (final event in GeminiLiveClient.parseServerMessage(json)) {
      switch (event) {
        case GeminiLiveSetupComplete():
          onSetupComplete();
        case GeminiLiveAudioChunk(pcmBytes: final bytes):
          if (state.value == AssistantSessionState.listening) {
            // Le modèle a commencé à répondre : on arrête d'envoyer le
            // flux micro, cette question n'a qu'un seul tour (v1).
            unawaited(_stopMicStreaming());
          }
          state.value = AssistantSessionState.responding;
          _enqueueAudio(Uint8List.fromList(bytes));
        case GeminiLiveInterrupted():
          break;
        case GeminiLiveTurnComplete():
          unawaited(_finishSession());
        case GeminiLiveError(raw: final errorBody):
          _fail('Erreur assistant : ${errorBody['message'] ?? errorBody}');
        case GeminiLiveUnknownEvent():
          break;
      }
    }
  }

  Future<void> _startMicStreaming() async {
    state.value = AssistantSessionState.listening;

    final controller = StreamController<Uint8List>();
    _micController = controller;
    _micSub = controller.stream.listen((chunk) {
      _sendClientMessage(GeminiLiveClient.buildAudioChunk(chunk, sampleRateHz: _micSampleRateHz));
    });

    // Appelé fire-and-forget depuis le handler de message WebSocket
    // (`onSetupComplete` n'est pas awaited) — sans ce try/catch, un échec ici
    // (ex. `flutter_sound` incapable de démarrer l'enregistreur) ne remonte
    // nulle part : le micro ne streame jamais rien, la session Gemini reste
    // ouverte et inerte jusqu'au timeout serveur (plusieurs minutes), puis se
    // ferme via `onDone` avec un message générique qui ne dit rien du vrai
    // problème. Repéré le 2026-08-29 : l'utilisateur voyait "Connexion à
    // l'assistant..." bloqué plusieurs minutes avant "Connexion fermée de
    // façon inattendue", alors que le handshake `setup`/`setupComplete`
    // avec Gemini fonctionne (vérifié empiriquement en dehors de l'app).
    try {
      await _recorder.startRecorder(
        codec: Codec.pcm16,
        sampleRate: _micSampleRateHz,
        numChannels: 1,
        audioSource: AudioSource.defaultSource,
        toStream: controller.sink,
      );
    } catch (e) {
      _fail('Impossible de démarrer le micro : $e');
    }
  }

  Future<void> _stopMicStreaming() async {
    if (_micController == null) return;
    try {
      await _recorder.stopRecorder();
    } catch (_) {}
    await _micSub?.cancel();
    await _micController?.close();
    _micSub = null;
    _micController = null;
  }

  Future<void> _ensureAudioSessionOpen() async {
    if (_audioSessionOpen) return;
    await _recorder.openRecorder();
    await _player.openPlayer();
    _audioSessionOpen = true;
  }

  Future<void> _startPlayerStream() async {
    if (_playerStreamStarted) return;
    await _player.startPlayerFromStream(
      codec: Codec.pcm16,
      numChannels: 1,
      sampleRate: _playbackSampleRateHz,
      interleaved: true,
      // `bufferSize` est `required` dans flutter_sound 9.30 malgré la doc
      // (commentaires du package) qui le présente comme optionnel — 8192
      // est la valeur par défaut utilisée ailleurs dans le package
      // (`startPlayerFromMic`, champ interne `_bufferSize`).
      bufferSize: 8192,
    );
    _playerStreamStarted = true;
  }

  void _enqueueAudio(Uint8List bytes) {
    _audioQueue.add(bytes);
    unawaited(_pumpAudioQueue());
  }

  Future<void> _pumpAudioQueue() async {
    if (_isFeedingAudio) return;
    _isFeedingAudio = true;
    try {
      while (_audioQueue.isNotEmpty) {
        final chunk = _audioQueue.removeFirst();
        await _player.feedUint8FromStream(chunk);
      }
    } catch (_) {
      // Le lecteur a probablement été arrêté pendant qu'on vidait la file
      // (fin/annulation de session) — rien à faire, `_teardownSession`
      // vide `_audioQueue` de son côté.
    } finally {
      _isFeedingAudio = false;
    }
  }

  Future<void> _finishSession() async {
    await _stopMicStreaming();
    await _closeChannel();
    // Ne pas couper le lecteur ici : `feedUint8FromStream` met en file
    // d'attente, la lecture réelle peut se terminer après la réception du
    // dernier fragment. Le flux de lecture est réutilisé/arrêté au début
    // de la session suivante (`_startPlayerStream`/`_teardownSession`),
    // pas coupé net à la fin de celle-ci — comportement à valider sur
    // device (cf. plan, fiabilité multiplateforme de flutter_sound).
    state.value = AssistantSessionState.idle;
  }

  Future<void> _teardownSession() async {
    await _stopMicStreaming();
    await _closeChannel();
    _audioQueue.clear();
    if (_playerStreamStarted) {
      try {
        await _player.stopPlayer();
      } catch (_) {}
      _playerStreamStarted = false;
    }
  }

  Future<void> _closeChannel() async {
    await _wsSub?.cancel();
    _wsSub = null;
    await _channel?.sink.close();
    _channel = null;
  }

  void _fail(String message) {
    lastErrorMessage.value = message;
    state.value = AssistantSessionState.error;
    unawaited(_teardownSession());
  }
}
