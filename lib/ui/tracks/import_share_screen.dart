import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:provider/provider.dart';

import '../../gpx/gpx_scanner_service.dart';
import '../../l10n/generated/app_localizations.dart';
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
    final loc = AppLocalizations.of(context)!;

    Trace trace;
    try {
      trace = await shareService.importFromShare(input, ownerUuid: ownerUuid);
    } catch (e, stack) {
      debugPrint('ImportShareScreen: import error: $e\n$stack');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e is TraceShareException ? e.message : loc.unexpectedErrorMessage;
      });
      return;
    }

    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(loc.traceImportedMessage(trace.name))),
    );
  }

  Future<void> _scanQrCode() async {
    final status = await ph.Permission.camera.request();
    if (!mounted) return;
    final loc = AppLocalizations.of(context)!;

    if (status.isPermanentlyDenied) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(loc.cameraAccessDeniedMessage),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(label: loc.settingsSnackbarAction, onPressed: () => ph.openAppSettings()),
        ),
      );
      return;
    }
    if (!status.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.cameraPermissionDeniedMessage)),
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
    final loc = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        title: Text(loc.importShareLabel),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              loc.pasteShareLinkInstructionText,
              style: const TextStyle(color: Colors.white70),
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
              label: Text(loc.importButton),
            ),
            const SizedBox(height: 24),
            Row(children: [
              const Expanded(child: Divider(color: Colors.white24)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(loc.orDividerLabel, style: const TextStyle(color: Colors.white38)),
              ),
              const Expanded(child: Divider(color: Colors.white24)),
            ]),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _isLoading ? null : _scanQrCode,
              icon: const Icon(Icons.qr_code_scanner),
              label: Text(loc.scanQrCodeLabel),
            ),
          ],
        ),
      ),
    );
  }
}
