import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/trace.dart';
import '../../sharing/local_gpx_server.dart';
import '../../sharing/trace_share_models.dart';
import '../../sharing/trace_share_service.dart';

enum _ShareMode { network, wifi }

/// Écran de partage d'une trace, poussé au-dessus de TrackEditScreen (n'y
/// met pas fin). Deux modes au choix, sélectionnés manuellement (pas de
/// bascule automatique selon le réseau détecté) : "Réseau mobile" (upload
/// Supabase Storage, nécessite internet) et "Réseau wifi" (serveur HTTP
/// local, même réseau WiFi requis, aucun accès internet nécessaire — voir
/// spec-partage-gpx-hors-reseau-mdns.md). Le QR code/lien du mode choisi
/// s'affiche directement sur cette même page, pas d'écran séparé.
class TraceShareScreen extends StatefulWidget {
  final Trace trace;

  const TraceShareScreen({super.key, required this.trace});

  @override
  State<TraceShareScreen> createState() => _TraceShareScreenState();
}

class _TraceShareScreenState extends State<TraceShareScreen> {
  _ShareMode? _mode;
  Future<TraceShareResult>? _networkFuture;
  Future<Uri>? _wifiFuture;
  final _localServer = LocalGpxServer();

  @override
  void dispose() {
    _localServer.stop();
    super.dispose();
  }

  void _selectNetwork() {
    setState(() {
      _mode = _ShareMode.network;
      _networkFuture ??= context.read<TraceShareService>().createShare(widget.trace);
    });
  }

  void _selectWifi() {
    setState(() {
      _mode = _ShareMode.wifi;
      _wifiFuture ??= _startWifiShare();
    });
  }

  Future<Uri> _startWifiShare() async {
    final shareService = context.read<TraceShareService>();
    final gpxXml = await shareService.buildGpxXml(widget.trace);
    return _localServer.start(gpxXml);
  }

  void _retryNetwork() {
    setState(() {
      _networkFuture = context.read<TraceShareService>().createShare(widget.trace);
    });
  }

  void _retryWifi() {
    setState(() {
      _wifiFuture = _startWifiShare();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        title: const Text('Partager la trace'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(
              widget.trace.name,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: _ModeButton(
                    icon: Icons.signal_cellular_alt,
                    label: 'Réseau mobile',
                    selected: _mode == _ShareMode.network,
                    onTap: _selectNetwork,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ModeButton(
                    icon: Icons.wifi,
                    label: 'Réseau wifi',
                    selected: _mode == _ShareMode.wifi,
                    onTap: _selectWifi,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            Expanded(child: _buildModeContent()),
          ],
        ),
      ),
    );
  }

  Widget _buildModeContent() {
    switch (_mode) {
      case null:
        return const Center(
          child: Text(
            'Choisissez un mode de partage ci-dessus.',
            style: TextStyle(color: Colors.white38),
            textAlign: TextAlign.center,
          ),
        );
      case _ShareMode.network:
        return FutureBuilder<TraceShareResult>(
          future: _networkFuture,
          builder: (context, snapshot) => _buildAsyncContent(
            snapshot: snapshot,
            onRetry: _retryNetwork,
            urlOf: (result) => result.shareUrl,
          ),
        );
      case _ShareMode.wifi:
        return FutureBuilder<Uri>(
          future: _wifiFuture,
          builder: (context, snapshot) => _buildAsyncContent(
            snapshot: snapshot,
            onRetry: _retryWifi,
            urlOf: (uri) => uri.toString(),
            subtitle: 'Le destinataire doit être connecté au même réseau WiFi.',
          ),
        );
    }
  }

  Widget _buildAsyncContent<T>({
    required AsyncSnapshot<T> snapshot,
    required VoidCallback onRetry,
    required String Function(T data) urlOf,
    String? subtitle,
  }) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const Center(child: CircularProgressIndicator());
    }
    if (snapshot.hasError) {
      final message = snapshot.error is TraceShareException
          ? (snapshot.error as TraceShareException).message
          : 'Une erreur inattendue est survenue.';
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 24),
            ElevatedButton(onPressed: onRetry, child: const Text('Réessayer')),
          ],
        ),
      );
    }

    final url = urlOf(snapshot.data as T);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: QrImageView(
              data: url,
              version: QrVersions.auto,
              size: 240,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 24),
          SelectableText(url, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
          ],
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: url));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Lien copié')));
              }
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copier le lien'),
          ),
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModeButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, color: selected ? Colors.black : Colors.white),
      label: Text(label, style: TextStyle(color: selected ? Colors.black : Colors.white)),
      style: OutlinedButton.styleFrom(
        backgroundColor: selected ? Colors.greenAccent : Colors.transparent,
        side: BorderSide(color: selected ? Colors.greenAccent : Colors.white24),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
    );
  }
}
