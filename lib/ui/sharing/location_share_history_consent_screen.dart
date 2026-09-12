import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../sharing/location_share_models.dart';
import '../../sharing/location_share_service.dart';
import 'location_share_active_screen.dart';

/// Second écran de consentement, VISUELLEMENT DISTINCT de
/// `LocationShareInviteScreen` et jamais fusionné avec lui (spec
/// §8.3/§15) : accepter de partager sa position en direct (écran
/// précédent) et accepter que cet historique soit conservé durablement
/// au-delà de la session sont deux permissions séparées, jamais l'une
/// déduite de l'autre. Thème ambre "conservation durable" plutôt que le
/// vert "partage en direct" de l'écran d'invitation.
///
/// Répondre ici ne bloque jamais la participation au partage : que
/// l'utilisateur accepte ou refuse, il rejoint le suivi en direct de la
/// même façon ensuite (seul le sort de son historique en fin de session en
/// dépend, voir `LocationShareActiveScreen._offerArchiveGroup`).
class LocationShareHistoryConsentScreen extends StatefulWidget {
  const LocationShareHistoryConsentScreen({super.key, required this.invite});

  final LocationShareJoinResult invite;

  @override
  State<LocationShareHistoryConsentScreen> createState() => _LocationShareHistoryConsentScreenState();
}

class _LocationShareHistoryConsentScreenState extends State<LocationShareHistoryConsentScreen> {
  bool _isBusy = false;
  String? _errorMessage;

  Future<void> _respond(bool consent) async {
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    final service = context.read<LocationShareService>();
    try {
      await service.setHistoryConsent(widget.invite.memberId, consent);
      await service.activateJoinedShare(widget.invite.shareId);
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LocationShareActiveScreen()));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _errorMessage = e is LocationShareException ? e.message : 'Une erreur inattendue est survenue.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(backgroundColor: Colors.grey[900], title: const Text('Conservation de l\'historique')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.history_edu, color: Colors.amberAccent, size: 56),
            const SizedBox(height: 24),
            Text(
              '${widget.invite.ownerPseudo} souhaite conserver l\'historique de position de tout le groupe, '
              'y compris le vôtre, en cas de besoin de revenir sur ce qui a été fait sur le terrain.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            const SizedBox(height: 12),
            const Text(
              'Distinct de l\'acceptation précédente : accepter ou refuser ici ne change rien à votre '
              'participation au suivi en direct, seule la conservation de votre historique en dépend.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 13),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              Text(_errorMessage!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
            ],
            const SizedBox(height: 32),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isBusy ? null : () => _respond(false),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white24),
                      minimumSize: const Size(double.infinity, 46),
                    ),
                    child: const Text('Refuser', style: TextStyle(color: Colors.white70)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isBusy ? null : () => _respond(true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.amberAccent,
                      foregroundColor: Colors.black,
                      minimumSize: const Size(double.infinity, 46),
                    ),
                    child: _isBusy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Accepter'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
