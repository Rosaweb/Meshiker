import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:provider/provider.dart';

import '../../gpx/gpx_scanner_service.dart';
import '../../models/trace.dart';
import '../../sharing/trace_share_models.dart';
import '../../sharing/trace_share_service.dart';
import 'qr_scan_screen.dart';

/// Écran de réception d'un partage GPX : coller un lien/token, ou scanner
/// le QR code correspondant, pour importer la trace localement.
class ImportShareScreen extends StatefulWidget {
  const ImportShareScreen({super.key});

  @override
  State<ImportShareScreen> createState() => _ImportShareScreenState();
}

class _ImportShareScreenState extends State<ImportShareScreen> {
  final _controller = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _import(String input) async {
    if (input.trim().isEmpty) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final shareService = context.read<TraceShareService>();
    final ownerUuid = context.read<GpxScannerService>().ownerUuid;

    Trace trace;
    try {
      trace = await shareService.importFromShare(input, ownerUuid: ownerUuid);
    } catch (e, stack) {
      debugPrint('ImportShareScreen: import error: $e\n$stack');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e is TraceShareException ? e.message : 'Une erreur inattendue est survenue.';
      });
      return;
    }

    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Trace importée : ${trace.name}')),
    );
  }

  Future<void> _scanQrCode() async {
    final status = await ph.Permission.camera.request();
    if (!mounted) return;

    if (status.isPermanentlyDenied) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Accès à la caméra refusé : autorisez-le pour Meshiker dans les paramètres Android.'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(label: 'PARAMÈTRES', onPressed: () => ph.openAppSettings()),
        ),
      );
      return;
    }
    if (!status.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Permission caméra refusée.')),
      );
      return;
    }

    final scanned = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (scanned == null || !mounted) return;
    _controller.text = scanned;
    await _import(scanned);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        title: const Text('Importer un partage'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Colle le lien ou le code de partage reçu, ou scanne le QR code.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              enabled: !_isLoading,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'https://meshiker.com/share/gpx/...',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(_errorMessage!, style: const TextStyle(color: Colors.redAccent)),
            ],
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _isLoading ? null : () => _import(_controller.text),
              icon: _isLoading
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download),
              label: const Text('Importer'),
            ),
            const SizedBox(height: 24),
            const Row(children: [
              Expanded(child: Divider(color: Colors.white24)),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('ou', style: TextStyle(color: Colors.white38)),
              ),
              Expanded(child: Divider(color: Colors.white24)),
            ]),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _isLoading ? null : _scanQrCode,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scanner un QR code'),
            ),
          ],
        ),
      ),
    );
  }
}
