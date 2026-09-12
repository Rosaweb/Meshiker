import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:provider/provider.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';

import '../../sharing/location_share_models.dart';
import '../../sharing/location_share_service.dart';
import '../../utils/subscription_service.dart';
import '../tracks/qr_scan_screen.dart';
import 'location_share_active_screen.dart';
import 'location_share_create_screen.dart';
import 'location_share_invite_screen.dart';

/// Point d'entrée du partage de position (spec §1, §9). Fonctionnalité
/// intégralement premium (§1, principe 1) : le gating se fait ICI, pas sur
/// l'entrée de menu qui reste visible pour que l'utilisateur découvre la
/// fonctionnalité, sur le modèle exact de `AccountSettingsScreen`
/// (`RevenueCatUI.presentPaywall()`) — jamais une simple vérification
/// côté client pour l'accès réel : le serveur revérifie systématiquement
/// dans `create_location_share`.
class LocationShareHomeScreen extends StatefulWidget {
  const LocationShareHomeScreen({super.key});

  @override
  State<LocationShareHomeScreen> createState() => _LocationShareHomeScreenState();
}

class _LocationShareHomeScreenState extends State<LocationShareHomeScreen> {
  bool _showJoinForm = false;
  final _joinController = TextEditingController();
  bool _isJoining = false;
  String? _joinError;

  @override
  void dispose() {
    _joinController.dispose();
    super.dispose();
  }

  Future<void> _join(String input) async {
    if (input.trim().isEmpty) return;
    setState(() {
      _isJoining = true;
      _joinError = null;
    });
    final service = context.read<LocationShareService>();
    try {
      final result = await service.joinShare(input);
      if (!mounted) return;
      setState(() {
        _isJoining = false;
        _showJoinForm = false;
        _joinController.clear();
      });
      Navigator.push(context, MaterialPageRoute(builder: (_) => LocationShareInviteScreen(invite: result)));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isJoining = false;
        _joinError = e is LocationShareException ? e.message : 'Une erreur inattendue est survenue.';
      });
    }
  }

  Future<void> _scanQrCode() async {
    final status = await ph.Permission.camera.request();
    if (!mounted) return;
    if (status.isPermanentlyDenied) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Accès à la caméra refusé : autorisez-le pour Meshiker dans les paramètres.'),
          action: SnackBarAction(label: 'PARAMÈTRES', onPressed: () => ph.openAppSettings()),
        ),
      );
      return;
    }
    if (!status.isGranted) return;

    final scanned = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (scanned == null || !mounted) return;
    await _join(scanned);
  }

  @override
  Widget build(BuildContext context) {
    final isPremium = context.watch<SubscriptionService>().isPremium;
    if (!isPremium) return _buildUpsell(context);

    final service = context.read<LocationShareService>();
    return AnimatedBuilder(
      animation: Listenable.merge([service.activeShare, service.pendingInvites]),
      builder: (context, _) {
        if (service.activeShare.value != null) {
          return const LocationShareActiveScreen();
        }
        return _buildHome(context, service);
      },
    );
  }

  Widget _buildUpsell(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(backgroundColor: Colors.grey[900], title: const Text('Partage de position')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.share_location, color: Colors.greenAccent, size: 56),
            const SizedBox(height: 16),
            const Text(
              'Partagez votre position en direct avec vos proches, ou programmez des points de passage '
              'automatiques — une fonctionnalité réservée aux comptes Premium.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => RevenueCatUI.presentPaywall(),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.greenAccent,
                foregroundColor: Colors.black,
                minimumSize: const Size(double.infinity, 45),
              ),
              child: const Text('Voir les offres Premium'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHome(BuildContext context, LocationShareService service) {
    final invites = service.pendingInvites.value;
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(backgroundColor: Colors.grey[900], title: const Text('Partage de position')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (invites.isNotEmpty) ...[
            const Text('Invitations en attente', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...invites.map((invite) => Card(
                  color: Colors.white10,
                  child: ListTile(
                    leading: const Icon(Icons.mail_outline, color: Colors.greenAccent),
                    title: Text(invite.ownerPseudo, style: const TextStyle(color: Colors.white)),
                    subtitle: invite.label != null
                        ? Text(invite.label!, style: const TextStyle(color: Colors.white54))
                        : null,
                    onTap: () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => LocationShareInviteScreen(invite: invite))),
                  ),
                )),
            const SizedBox(height: 24),
          ],
          ElevatedButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LocationShareCreateScreen())),
            icon: const Icon(Icons.add_location_alt_outlined),
            label: const Text('Créer un partage'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.greenAccent,
              foregroundColor: Colors.black,
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => setState(() => _showJoinForm = !_showJoinForm),
            icon: const Icon(Icons.group_add_outlined, color: Colors.white70),
            label: const Text('Rejoindre un partage', style: TextStyle(color: Colors.white70)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.white24),
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
          if (_showJoinForm) _buildJoinForm(),
        ],
      ),
    );
  }

  Widget _buildJoinForm() {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _joinController,
            enabled: !_isJoining,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Lien ou code reçu',
              hintStyle: const TextStyle(color: Colors.white38),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          if (_joinError != null) ...[
            const SizedBox(height: 8),
            Text(_joinError!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _isJoining ? null : () => _join(_joinController.text),
            child: _isJoining
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Rejoindre'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _isJoining ? null : _scanQrCode,
            icon: const Icon(Icons.qr_code_scanner, color: Colors.white70),
            label: const Text('Scanner un QR code', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }
}
