import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/waypoint.dart';
import '../recording/recording_service.dart';
import '../utils/geo_utils.dart';
import '../utils/supabase_bootstrap_service.dart';
import 'gemini_live_client.dart';
import 'places_service.dart';

/// Noms des outils exposés au modèle (v2, navigation) — doivent matcher
/// EXACTEMENT les `functionDeclarations` verrouillées côté serveur dans
/// `supabase/functions/assistant-token/index.ts` (la Live API identifie
/// l'outil par ce nom, pas par position).
abstract final class _ToolNames {
  static const describeRoute = 'decrire_itineraire';
  static const nextDirection = 'obtenir_prochaine_direction';
  static const searchNearbyPlaces = 'rechercher_commerces_proximite';
  static const placeHours = 'horaires_commerce';
}

/// États d'une session assistant, exposés à l'UI (page Aide et volet
/// Navigation, cf. plan-implementation-assistant-ia.md section 3). `idle`
/// couvre aussi bien "aucune conversation ouverte" que "conversation
/// ouverte, en attente de la prochaine question" — cf.
/// [AssistantService.hasActiveConversation] pour distinguer les deux.
enum AssistantSessionState {
  idle,
  connecting,
  listening,
  responding,
  usingTool,
  offline,
  error,
}

/// Orchestrateur d'une session assistant IA (manuel d'aide v1, navigation
/// v2). Récupère un token éphémère via l'Edge Function `assistant-token`,
/// ouvre une connexion WebSocket directe vers Gemini Live (aucun audio ne
/// transite par Supabase), envoie la question de l'utilisateur (texte ou
/// flux micro), exécute les appels de fonction que le modèle demande en
/// cours de route (v2 — lecture d'itinéraire/waypoints via
/// [RecordingService], recherche de commerces via [PlacesService]) et joue
/// la réponse audio.
///
/// Une même session Gemini Live reste ouverte pour plusieurs questions
/// successives (texte et/ou micro, dans n'importe quel ordre) : le modèle
/// garde ainsi le contexte des tours précédents — nécessaire par exemple
/// pour qu'une question de suivi sur les horaires d'un commerce réutilise
/// le `place_id` trouvé par une recherche précédente sans le redemander.
/// Décision révisée le 2026-08-31 (le v1 initial rouvrait une session par
/// question — voir l'historique dans plan-implementation-assistant-ia.md
/// section 3.1 — ce qui perdait tout contexte d'une question à l'autre).
/// La session ne se ferme que sur action explicite ([endConversation]) ou
/// fermeture naturelle par le serveur (durée max d'une session Live,
/// ~15 min en audio) — dans ce dernier cas, la question suivante rouvre
/// silencieusement une nouvelle conversation (cf. [_startSession]).
///
/// Suit le même style que `RecordingService` : classe simple (pas un
/// `ChangeNotifier`), état exposé via des `ValueNotifier` individuels.
class AssistantService {
  AssistantService({
    required this.supabaseBootstrap,
    required this.recordingService,
    required this.placesService,
    Connectivity? connectivity,
  }) : _connectivity = connectivity ?? Connectivity();

  final SupabaseBootstrapService supabaseBootstrap;
  // Source de vérité pour la trace/waypoints chargés dans le Roadmap (v2,
  // function calling) — lecture seule ici, cf. `RecordingService.
  // activeRoadmapTrace`/`activeRoadmapWaypoints`, déjà calculés pour les
  // annonces vocales (§2 du plan) et réutilisés tels quels.
  final RecordingService recordingService;
  final PlacesService placesService;
  final Connectivity _connectivity;

  final ValueNotifier<AssistantSessionState> state = ValueNotifier(AssistantSessionState.idle);
  final ValueNotifier<String?> lastErrorMessage = ValueNotifier(null);

  /// Vrai dès qu'une session Gemini Live est ouverte (conversation en
  /// cours, contexte des tours précédents conservé) — sert à afficher le
  /// bouton "Terminer la conversation" dans l'UI. Notifier séparé de
  /// [state] : `state` repasse à `idle` entre deux tours même quand une
  /// conversation reste ouverte, et `ValueNotifier` ne notifie pas quand
  /// la valeur assignée est égale à la précédente (idle -> idle), ce qui
  /// aurait raté des mises à jour de ce booléen si on l'avait dérivé de
  /// `state` au lieu de le suivre indépendamment.
  final ValueNotifier<bool> hasActiveConversation = ValueNotifier(false);

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

  /// Met fin explicitement à la conversation en cours (bouton dédié dans
  /// l'UI, à côté du champ de saisie) : ferme la session Gemini Live
  /// proprement. La question suivante ouvrira une toute nouvelle
  /// conversation (nouveau token, plus de mémoire des tours précédents) —
  /// un choix de l'utilisateur, pas une erreur.
  Future<void> endConversation() => cancelSession();

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

    if (_channel != null) {
      // Conversation déjà ouverte (question précédente dans le même
      // échange) : on réutilise la même session Gemini Live au lieu d'en
      // ouvrir une nouvelle, pour que le modèle garde le contexte des
      // tours précédents. `connecting` sert ici de repli visuel générique
      // ("en cours") le temps que la réponse arrive, exactement comme
      // pour une nouvelle session entre `setupComplete` et le premier
      // événement de réponse.
      state.value = AssistantSessionState.connecting;
      onReady();
      return;
    }

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
    hasActiveConversation.value = true;

    var setupDone = false;
    _wsSub = channel.stream.listen(
      (raw) => _handleServerMessage(raw, () {
        if (!setupDone) {
          setupDone = true;
          onSetupComplete();
        }
      }),
      onError: (Object e) {
        debugPrint('AssistantService: WebSocket error: $e');
        _fail('Connexion assistant interrompue.');
      },
      onDone: () {
        // `usingTool` manquait ici à l'origine (oubli lors de l'ajout de
        // cet état v2) : une fermeture pendant l'exécution d'un outil
        // passait inaperçue, la session restait bloquée sans message
        // d'erreur.
        final wasMidTurn = state.value == AssistantSessionState.connecting ||
            state.value == AssistantSessionState.listening ||
            state.value == AssistantSessionState.responding ||
            state.value == AssistantSessionState.usingTool;

        // `closeCode`/`closeReason` ne sont renseignés par le WebSocket
        // natif qu'une fois le flux réellement terminé — les lire ici,
        // dans `onDone`, est le seul moment fiable pour ça.
        final code = channel.closeCode;
        final reason = channel.closeReason;

        // Toujours nettoyer la référence au canal ici, que la fermeture
        // soit attendue (conversation terminée par `endConversation()`,
        // ou fermeture naturelle du serveur entre deux tours — durée max
        // d'une session Live, ~15 min en audio) ou non : sans ça,
        // `_startSession` croirait pouvoir réutiliser un canal déjà mort
        // à la question suivante (`hasActiveConversation` resterait aussi
        // bloqué à `true` à tort).
        _channel = null;
        _wsSub = null;
        hasActiveConversation.value = false;

        if (wasMidTurn) {
          // Utile pour distinguer un vrai problème réseau (code 1006, pas
          // de reason) d'un rejet explicite du serveur Gemini (ex. 1008
          // avec une reason qui nomme le champ en cause) — cf.
          // l'historique de debug du nom de modèle, retrouvé de cette
          // façon.
          debugPrint('AssistantService: WebSocket closed unexpectedly (code=$code, reason=$reason)');
          // Affiché tel quel à l'utilisateur (pas seulement en log) : ce
          // détail technique est ce qui a permis de diagnostiquer le
          // précédent faux suspect de nom de modèle sans accès aux logs
          // Android — plus utile ici qu'un message générique tant que
          // cette fonctionnalité n'est pas stabilisée.
          final detail = (code != null || reason != null) ? ' (code=$code, reason=$reason)' : '';
          _fail('Connexion assistant fermée de façon inattendue.$detail');
        } else {
          // Fermeture pendant `idle` (entre deux tours, conversation
          // ouverte en attente de la prochaine question) : traité comme
          // une fin de conversation normale, pas une erreur — la question
          // suivante rouvrira silencieusement une nouvelle conversation
          // (`_startSession` voit `_channel == null`).
          debugPrint('AssistantService: session Live terminée (code=$code, reason=$reason)');
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
        case GeminiLiveToolCall(functionCalls: final calls):
          if (state.value == AssistantSessionState.listening) {
            // Comme pour un premier fragment audio : le modèle a fini
            // d'écouter et passe à l'action, plus la peine de streamer le
            // micro pour ce tour.
            unawaited(_stopMicStreaming());
          }
          state.value = AssistantSessionState.usingTool;
          unawaited(_handleToolCalls(calls));
        case GeminiLiveError(raw: final errorBody):
          _fail('Erreur assistant : ${errorBody['message'] ?? errorBody}');
        case GeminiLiveUnknownEvent():
          break;
      }
    }
  }

  /// Exécute chaque appel de fonction demandé par le modèle puis renvoie
  /// toutes les réponses groupées dans un seul message `toolResponse` — la
  /// Live API accepte un groupe de réponses par message, pas d'obligation de
  /// répondre un par un (cf. `GeminiLiveClient.buildToolResponse`).
  Future<void> _handleToolCalls(List<GeminiFunctionCall> calls) async {
    final responses = <GeminiFunctionResponse>[];
    for (final call in calls) {
      final result = await _executeTool(call.name, call.args);
      responses.add(GeminiFunctionResponse(id: call.id, name: call.name, response: result));
    }
    if (_channel == null) return; // session annulée pendant l'exécution
    _sendClientMessage(GeminiLiveClient.buildToolResponse(responses));
    // La réponse du modèle (audio) va suivre — pas de nouvel état
    // intermédiaire nécessaire, `responding` sera posé par le premier
    // fragment audio reçu comme d'habitude.
  }

  Future<Map<String, dynamic>> _executeTool(String name, Map<String, dynamic> args) async {
    try {
      switch (name) {
        case _ToolNames.describeRoute:
          return _describeRoute();
        case _ToolNames.nextDirection:
          return _nextDirection();
        case _ToolNames.searchNearbyPlaces:
          return await _searchNearbyPlaces(args);
        case _ToolNames.placeHours:
          return await _placeHours(args);
        default:
          return {'erreur': 'outil_inconnu'};
      }
    } catch (e) {
      return {'erreur': 'echec_outil'};
    }
  }

  /// `decrire_itineraire` : lecture seule de la trace/waypoints déjà chargés
  /// dans le Roadmap (aucun appel réseau, mêmes données que les annonces
  /// vocales, §2 du plan).
  Map<String, dynamic> _describeRoute() {
    final trace = recordingService.activeRoadmapTrace;
    if (trace == null) {
      return {
        'itineraire_charge': false,
        'message': "Aucun itinéraire n'est actuellement chargé dans le roadmap.",
      };
    }
    return {
      'itineraire_charge': true,
      'nom': trace.name,
      'description': trace.description,
      'distance_totale_m': trace.totalDistanceMeters.round(),
      'denivele_positif_m': trace.totalElevationGainMeters.round(),
      'denivele_negatif_m': trace.totalElevationLossMeters.round(),
      'distance_parcourue_m': recordingService.trackDistanceDoneMeters.value.round(),
      'distance_restante_m': recordingService.trackDistanceRemainingMeters.value.round(),
      'noms_waypoints': recordingService.activeRoadmapWaypoints.map((w) => w.name).toList(),
    };
  }

  /// `obtenir_prochaine_direction` : même source que ci-dessus, complétée
  /// par la position courante pour donner un cap (point cardinal) vers le
  /// prochain waypoint et vers la destination choisie, si il y en a une.
  Map<String, dynamic> _nextDirection() {
    final next = recordingService.nextWaypoint.value;
    final destination = recordingService.destinationWaypoint.value;
    final position = recordingService.currentPosition.value;

    Map<String, dynamic>? describe(Waypoint? waypoint, double distanceMeters) {
      if (waypoint == null) return null;
      String? cap;
      if (position != null) {
        final bearing = GeoUtils.bearingDegrees(
          position.latitude,
          position.longitude,
          waypoint.latitude,
          waypoint.longitude,
        );
        cap = GeoUtils.compassPoint(bearing);
      }
      return {
        'nom': waypoint.name,
        'distance_m': distanceMeters.round(),
        'direction_cardinale': cap,
      };
    }

    return {
      'prochain_waypoint': describe(next, recordingService.distanceToNextWaypointMeters.value),
      'destination': describe(destination, recordingService.distanceToDestinationMeters.value),
    };
  }

  /// `rechercher_commerces_proximite` : proxy Google Places via l'Edge
  /// Function `assistant-places` (coût/clé serveur, jamais côté client —
  /// même principe que `assistant-token` pour Gemini).
  Future<Map<String, dynamic>> _searchNearbyPlaces(Map<String, dynamic> args) async {
    final query = args['type'] as String?;
    if (query == null || query.trim().isEmpty) {
      return {'erreur': 'parametre_type_manquant'};
    }
    final position = recordingService.currentPosition.value;
    if (position == null) {
      return {'erreur': 'position_inconnue'};
    }
    final radius = (args['rayon_metres'] as num?)?.toInt() ?? 2000;
    return placesService.searchNearby(
      latitude: position.latitude,
      longitude: position.longitude,
      query: query,
      radiusMeters: radius,
    );
  }

  /// `horaires_commerce` : détail d'un commerce déjà renvoyé par
  /// `rechercher_commerces_proximite` (identifié par son `place_id`).
  Future<Map<String, dynamic>> _placeHours(Map<String, dynamic> args) async {
    final placeId = args['place_id'] as String?;
    if (placeId == null || placeId.trim().isEmpty) {
      return {'erreur': 'parametre_place_id_manquant'};
    }
    return placesService.placeHours(placeId: placeId);
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
    // Le canal WebSocket reste OUVERT ici (changement du 2026-08-31) :
    // c'est ce qui permet à la conversation de continuer sur plusieurs
    // questions avec mémoire des tours précédents, cf. le commentaire de
    // classe. Il ne se ferme que sur `endConversation()` explicite ou
    // fermeture naturelle par le serveur (`onDone`).
    //
    // Ne pas couper le lecteur ici non plus : `feedUint8FromStream` met en
    // file d'attente, la lecture réelle peut se terminer après la
    // réception du dernier fragment. Le flux de lecture est
    // réutilisé/arrêté au début de la session suivante
    // (`_startPlayerStream`/`_teardownSession`), pas coupé net à la fin de
    // celle-ci — comportement à valider sur device (cf. plan, fiabilité
    // multiplateforme de flutter_sound).
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
    hasActiveConversation.value = false;
  }

  void _fail(String message) {
    lastErrorMessage.value = message;
    state.value = AssistantSessionState.error;
    unawaited(_teardownSession());
  }
}
