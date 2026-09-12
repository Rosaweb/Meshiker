import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../sharing/location_share_models.dart';
import '../../sharing/location_share_service.dart';
import 'location_share_active_screen.dart';
import 'location_share_history_consent_screen.dart';

/// Écran de réception d'invitation App-to-app (spec §7.2/§9) :
/// *"[Administrateur] vous invite à partager votre position dans
/// [libellé]"*. Aucune émission de position n'est possible avant
/// acceptation — appliqué côté serveur (policy d'insert sur
/// `location_pings` exige `is_accepted_app_member`), pas seulement ici.
class LocationShareInviteScreen extends StatefulWidget {
  const LocationShareInviteScreen({super.key, required this.invite});

  final LocationShareJoinResult invite;

  @override
  State<LocationShareInviteScreen> createState() => _LocationShareInviteScreenState();
}

class _LocationShareInviteScreenState extends State<LocationShareInviteScreen> {
  bool _isBusy = false;
  String? _errorMessage;

  Future<void> _respond(bool accept) async {
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    final service = context.read<LocationShareService>();
    try {
      await service.respondToInvite(widget.invite.memberId, accept);
      if (!mounted) return;

      if (!accept) {
        Navigator.pop(context);
        return;
      }

      // Second consentement, distinct et jamais fusionné avec l'acceptation
      // ci-dessus (spec §2/§8.3/§15) : accepter de partager sa position en
      // direct n'implique jamais d'accepter la conservation durable de
      // l'historique.
      if (widget.invite.historyGlobal) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => LocationShareHistoryConsentScreen(invite: widget.invite)),
        );
        return;
      }

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
    final invite = widget.invite;
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(backgroundColor: Colors.grey[900], title: const Text('Invitation')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.share_location, color: Colors.greenAccent, size: 56),
            const SizedBox(height: 24),
            Text(
              '${invite.ownerPseudo} vous invite à partager votre position'
              '${invite.label != null ? " dans \"${invite.label}\"" : ""}.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 17),
            ),
            const SizedBox(height: 12),
            Text(
              'Votre position ne sera visible qu\'une fois l\'invitation acceptée, jamais avant.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 13),
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
                      backgroundColor: Colors.greenAccent,
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
