import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../gpx/gpx_scanner_service.dart';
import '../../sharing/location_share_models.dart';
import '../../sharing/location_share_service.dart';

/// Écran "Partage actif" (spec §9) : bandeau d'état, lien/QR d'invitation
/// App-to-app (voir note d'adaptation dans `LocationShareCreateScreen`),
/// liste des participants avec fraîcheur, "Étendre la durée", "Arrêter le
/// partage" — avec proposition immédiate de sauvegarde à l'arrêt, tant que
/// les pings sont encore disponibles côté serveur (voir plan
/// d'implémentation : le cron de nettoyage peut purger dès 15 min/1h après
/// expiration selon l'historique).
class LocationShareActiveScreen extends StatefulWidget {
  const LocationShareActiveScreen({super.key});

  @override
  State<LocationShareActiveScreen> createState() => _LocationShareActiveScreenState();
}

class _LocationShareActiveScreenState extends State<LocationShareActiveScreen> {
  static const _shareUrlBase = 'https://meshiker.com/track';

  bool _isBusy = false;

  @override
  Widget build(BuildContext context) {
    final service = context.read<LocationShareService>();
    return AnimatedBuilder(
      animation: Listenable.merge([service.activeShare, service.members, service.lastSeenByUser]),
      builder: (context, _) {
        final share = service.activeShare.value;
        if (share == null) {
          // Le partage a été arrêté entre-temps (ex. purgé côté serveur) —
          // ne jamais laisser cet écran affiché sans partage actif.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && Navigator.canPop(context)) Navigator.pop(context);
          });
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        return _buildScaffold(context, service, share);
      },
    );
  }

  Widget _buildScaffold(BuildContext context, LocationShareService service, LocationShare share) {
    final isAdmin = share.ownerId == service.currentUserId;
    final showInvite = share.channels.contains(LocationShareChannel.app);
    final remaining = share.expiresAt.difference(DateTime.now());

    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        title: Text(share.label ?? _modeLabel(share.mode)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _statusBanner(share, remaining),
          if (showInvite) ...[
            const SizedBox(height: 24),
            _inviteSection(context, share),
          ],
          const SizedBox(height: 24),
          _membersSection(service, share),
          const SizedBox(height: 32),
          OutlinedButton.icon(
            onPressed: _isBusy ? null : () => _extend(context, service),
            icon: const Icon(Icons.more_time, color: Colors.white70),
            label: const Text('Étendre la durée', style: TextStyle(color: Colors.white70)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.white24),
              minimumSize: const Size(double.infinity, 44),
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _isBusy ? null : () => _confirmStop(context, service, share, isAdmin: isAdmin),
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('Arrêter le partage'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent.withValues(alpha: 0.15),
              foregroundColor: Colors.redAccent,
              minimumSize: const Size(double.infinity, 44),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBanner(LocationShare share, Duration remaining) {
    final remainingLabel = remaining.isNegative
        ? 'Expiré'
        : remaining.inHours >= 1
            ? '${remaining.inHours} h restantes'
            : '${remaining.inMinutes} min restantes';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_modeIcon(share.mode), color: Colors.greenAccent),
              const SizedBox(width: 8),
              Text(_modeLabel(share.mode), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              const Spacer(),
              Text(remainingLabel, style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
          if (share.mode == LocationShareMode.live && share.liveIntervalSeconds != null) ...[
            const SizedBox(height: 6),
            Text('Fréquence : toutes les ${share.liveIntervalSeconds}s',
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ],
          if (share.historyEnabled) ...[
            const SizedBox(height: 6),
            const Text('Historique activé', style: TextStyle(color: Colors.white38, fontSize: 12)),
          ],
        ],
      ),
    );
  }

  Widget _inviteSection(BuildContext context, LocationShare share) {
    final url = '$_shareUrlBase/${share.shareToken}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Inviter', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 12),
        Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            color: Colors.white,
            child: QrImageView(data: url, version: QrVersions.auto, size: 180, backgroundColor: Colors.white),
          ),
        ),
        const SizedBox(height: 12),
        SelectableText(url, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 8),
        Center(
          child: TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: url));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Lien copié')));
              }
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copier le lien'),
          ),
        ),
      ],
    );
  }

  Widget _membersSection(LocationShareService service, LocationShare share) {
    if (!share.channels.contains(LocationShareChannel.app) && !share.channels.contains(LocationShareChannel.email)) {
      return const SizedBox.shrink();
    }
    final members = service.members.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Participants', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.white38, size: 20),
              onPressed: () => service.refreshMembers(),
            ),
          ],
        ),
        if (members.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Aucun participant pour le moment.', style: TextStyle(color: Colors.white38)),
          )
        else
          ...members.map((m) => _memberTile(service, share, m)),
      ],
    );
  }

  Widget _memberTile(LocationShareService service, LocationShare share, LocationShareMember m) {
    final isAppMember = m.channel == LocationShareChannel.app || m.channel == LocationShareChannel.accountsOnly;
    final lastSeen = m.userId == null ? null : service.lastSeenByUser.value[m.userId];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        isAppMember ? Icons.person_outline : Icons.email_outlined,
        color: Colors.white70,
      ),
      title: Text(m.pseudo ?? m.contact ?? 'Participant', style: const TextStyle(color: Colors.white)),
      subtitle: isAppMember
          ? Text(_inviteStatusLabel(m.inviteStatus, lastSeen, share),
              style: const TextStyle(color: Colors.white38, fontSize: 12))
          : null,
    );
  }

  String _inviteStatusLabel(LocationShareInviteStatus status, DateTime? lastSeen, LocationShare share) {
    switch (status) {
      case LocationShareInviteStatus.pending:
        return 'En attente';
      case LocationShareInviteStatus.declined:
        return 'Refusée';
      case LocationShareInviteStatus.accepted:
        return _freshnessLabel(lastSeen, share);
    }
  }

  /// Fraîcheur dérivée de la récence de `recorded_at` (voir plan
  /// d'implémentation, écart §2 : pas de Presence Realtime, première
  /// utilisation de Realtime dans ce repo déjà bien assez pour les pings).
  String _freshnessLabel(DateTime? lastSeen, LocationShare share) {
    if (lastSeen == null) return 'Aucune position reçue';
    final age = DateTime.now().difference(lastSeen);
    final liveThreshold = Duration(seconds: (share.liveIntervalSeconds ?? 60) * 2);
    final freshThreshold = share.mode == LocationShareMode.live ? liveThreshold : const Duration(hours: 2);
    if (age <= freshThreshold) return 'En direct';
    if (age <= const Duration(hours: 6)) return 'Vu il y a ${age.inMinutes} min';
    return 'Hors ligne';
  }

  IconData _modeIcon(LocationShareMode mode) {
    switch (mode) {
      case LocationShareMode.manual:
        return Icons.touch_app_outlined;
      case LocationShareMode.auto:
        return Icons.schedule;
      case LocationShareMode.live:
        return Icons.podcasts;
    }
  }

  String _modeLabel(LocationShareMode mode) {
    switch (mode) {
      case LocationShareMode.manual:
        return 'Partage manuel';
      case LocationShareMode.auto:
        return 'Partage automatique';
      case LocationShareMode.live:
        return 'Live';
    }
  }

  Future<void> _extend(BuildContext context, LocationShareService service) async {
    final hours = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: Colors.grey[850],
        title: const Text('Étendre la durée', style: TextStyle(color: Colors.white)),
        children: [6, 12, 24, 72]
            .map((h) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, h),
                  child: Text('+ $h h', style: const TextStyle(color: Colors.white70)),
                ))
            .toList(),
      ),
    );
    if (hours == null) return;
    setState(() => _isBusy = true);
    try {
      await service.extendDuration(Duration(hours: hours));
    } catch (e) {
      if (context.mounted) _showError(context, e);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _confirmStop(
    BuildContext context,
    LocationShareService service,
    LocationShare share, {
    required bool isAdmin,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[850],
        title: const Text('Arrêter le partage ?', style: TextStyle(color: Colors.white)),
        content: const Text('Votre position ne sera plus transmise.', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Arrêter')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final shareId = share.id;
    final historyEnabled = share.historyEnabled;
    final historyGlobal = share.historyGlobal;
    final label = share.label;

    setState(() => _isBusy = true);
    try {
      await service.stopShare();
    } catch (e) {
      if (context.mounted) _showError(context, e);
      setState(() => _isBusy = false);
      return;
    }
    if (!context.mounted) return;

    // Immédiatement, pendant que les pings sont encore disponibles côté
    // serveur (voir plan d'implémentation) : proposition individuelle,
    // puis archive de groupe pour l'administrateur si applicable.
    if (historyEnabled) {
      await _offerSaveAsTrace(context, service, shareId, label);
    }
    if (isAdmin && historyGlobal && context.mounted) {
      await _offerArchiveGroup(context, service, shareId);
    }
    if (mounted) setState(() => _isBusy = false);
    if (context.mounted) Navigator.pop(context);
  }

  Future<void> _offerSaveAsTrace(
    BuildContext context,
    LocationShareService service,
    String shareId,
    String? label,
  ) async {
    final controller = TextEditingController(
      text: label ?? 'Partage du ${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year}',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[850],
        title: const Text('Enregistrer comme trace ?', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(labelText: 'Nom de la trace', labelStyle: TextStyle(color: Colors.white54)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Non')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Enregistrer')),
        ],
      ),
    );
    if (name == null || name.isEmpty || !context.mounted) return;

    try {
      final ownerUuid = context.read<GpxScannerService>().ownerUuid;
      await service.saveMyHistoryAsTrace(shareId: shareId, ownerUuid: ownerUuid, traceName: name);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Trace "$name" enregistrée localement.')),
        );
      }
    } catch (e) {
      if (context.mounted) _showError(context, e);
    }
  }

  Future<void> _offerArchiveGroup(
    BuildContext context,
    LocationShareService service,
    String shareId,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[850],
        title: const Text('Sauvegarder l\'historique du groupe ?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Archive côté serveur les positions des membres ayant consenti à la conservation de leur '
          'historique, pour une future consultation (non disponible dans l\'application pour le moment).',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Non')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sauvegarder')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      final count = await service.archiveGroupHistory(shareId);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$count points archivés côté serveur.')),
        );
      }
    } catch (e) {
      if (context.mounted) _showError(context, e);
    }
  }

  void _showError(BuildContext context, Object e) {
    final message = e is LocationShareException ? e.message : 'Une erreur inattendue est survenue.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}
