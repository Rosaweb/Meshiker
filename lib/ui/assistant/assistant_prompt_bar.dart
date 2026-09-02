import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../assistant/assistant_service.dart';
import '../../utils/settings_service.dart';
import '../../utils/subscription_service.dart';

/// Barre "Demander à Meshiker" — champ de saisie texte + bouton d'envoi, et
/// optionnellement un bouton micro. Réutilisée par la page Aide et le volet
/// Navigation : un seul point d'orchestration (`AssistantService`), cf.
/// plan-implementation-assistant-ia-v1.md section 3.
///
/// Se masque entièrement si l'assistant est désactivé dans les paramètres
/// ou si l'utilisateur n'est pas premium (amélioration UX seulement — le
/// vrai contrôle est côté serveur, `assistant-token`) ; affiche un message
/// hors-ligne à la place du champ de saisie plutôt que de disparaître
/// (spec-assistant-vocal-ia.md section 3.5).
class AssistantPromptBar extends StatefulWidget {
  final bool showMicButton;

  /// Titre optionnel affiché *à l'intérieur* du cadre, au-dessus du contenu,
  /// pour rester homogène avec les autres blocs d'outils du volet Navigation
  /// (cf. `_buildToolBlock` dans main_navigation_screen.dart). Null = pas de
  /// titre (cas de la page Aide).
  final String? title;

  const AssistantPromptBar(
      {super.key, this.showMicButton = true, this.title});

  @override
  State<AssistantPromptBar> createState() => _AssistantPromptBarState();
}

class _AssistantPromptBarState extends State<AssistantPromptBar> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send(AssistantService assistant) {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    assistant.askText(text);
    _controller.clear();
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final isPremium = context.watch<SubscriptionService>().isPremium;
    if (settings.aiAssistantDisabled || !isPremium) {
      return const SizedBox.shrink();
    }

    final offline = context.watch<ConnectivityResult>() == ConnectivityResult.none;
    final assistant = context.read<AssistantService>();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.title != null) ...[
            Text(widget.title!,
                style: TextStyle(
                    color: settings.accentColor,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
          ],
          offline ? _buildOfflineMessage() : _buildPrompt(assistant),
        ],
      ),
    );
  }

  Widget _buildOfflineMessage() {
    return const Row(
      children: [
        Icon(Icons.cloud_off, color: Colors.white38, size: 18),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            'Assistant indisponible sans connexion.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildPrompt(AssistantService assistant) {
    return ValueListenableBuilder<AssistantSessionState>(
      valueListenable: assistant.state,
      builder: (context, state, _) {
        final idle = state == AssistantSessionState.idle;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildStatusLine(assistant, state),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    enabled: idle,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: 'Demander à Meshiker...',
                      hintStyle: TextStyle(color: Colors.white38),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onSubmitted: (_) => _send(assistant),
                  ),
                ),
                if (widget.showMicButton)
                  IconButton(
                    icon: const Icon(Icons.mic, color: Colors.white70),
                    tooltip: 'Poser la question à voix haute',
                    onPressed: idle ? assistant.askVoice : null,
                  ),
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.greenAccent),
                  tooltip: 'Envoyer',
                  onPressed: idle ? () => _send(assistant) : null,
                ),
                // Une conversation reste ouverte sur plusieurs questions
                // (mémoire des tours précédents, cf. AssistantService) :
                // ce bouton ne sert qu'à la clôturer explicitement pour en
                // démarrer une toute nouvelle — masqué tant qu'aucune
                // conversation n'est en cours.
                ValueListenableBuilder<bool>(
                  valueListenable: assistant.hasActiveConversation,
                  builder: (context, hasActiveConversation, _) {
                    if (!hasActiveConversation) return const SizedBox.shrink();
                    return IconButton(
                      icon: const Icon(Icons.stop_circle_outlined, color: Colors.white38),
                      tooltip: 'Terminer la conversation',
                      onPressed: assistant.endConversation,
                    );
                  },
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildStatusLine(AssistantService assistant, AssistantSessionState state) {
    final (label, color) = switch (state) {
      AssistantSessionState.idle => (null, Colors.white38),
      AssistantSessionState.connecting => ('Connexion à l\'assistant...', Colors.white38),
      AssistantSessionState.listening => ('Je vous écoute...', Colors.greenAccent),
      AssistantSessionState.responding => ('L\'assistant répond...', Colors.greenAccent),
      AssistantSessionState.usingTool => ('Recherche en cours...', Colors.greenAccent),
      AssistantSessionState.offline => ('Assistant indisponible sans connexion.', Colors.white38),
      AssistantSessionState.error => (null, Colors.redAccent),
    };

    if (state == AssistantSessionState.error) {
      return ValueListenableBuilder<String?>(
        valueListenable: assistant.lastErrorMessage,
        builder: (context, message, _) => Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                message ?? 'Une erreur est survenue.',
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white38, size: 16),
              onPressed: assistant.cancelSession,
              tooltip: 'Fermer',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
      );
    }

    if (label == null) return const SizedBox.shrink();
    return Text(label, style: TextStyle(color: color, fontSize: 12));
  }
}
