import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/trace.dart';
import '../../sharing/trace_share_models.dart';
import '../../sharing/trace_share_service.dart';

/// Écran affichant le QR code de partage d'une trace, poussé au-dessus
/// de TrackEditScreen (n'y met pas fin). Le partage est lancé dès
/// l'ouverture de l'écran.
class TraceShareScreen extends StatefulWidget {
  final Trace trace;

  const TraceShareScreen({super.key, required this.trace});

  @override
  State<TraceShareScreen> createState() => _TraceShareScreenState();
}

class _TraceShareScreenState extends State<TraceShareScreen> {
  late Future<TraceShareResult> _shareFuture;

  @override
  void initState() {
    super.initState();
    _startShare();
  }

  void _startShare() {
    _shareFuture = context.read<TraceShareService>().createShare(widget.trace);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        title: const Text('Partager la trace'),
      ),
      body: FutureBuilder<TraceShareResult>(
        future: _shareFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            final message = snapshot.error is TraceShareException
                ? (snapshot.error as TraceShareException).message
                : 'Une erreur inattendue est survenue.';
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
                    const SizedBox(height: 16),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: () => setState(_startShare),
                      child: const Text('Réessayer'),
                    ),
                  ],
                ),
              ),
            );
          }

          final result = snapshot.data!;
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.trace.name,
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(16),
                    color: Colors.white,
                    child: QrImageView(
                      data: result.shareUrl,
                      version: QrVersions.auto,
                      size: 240,
                      backgroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 24),
                  SelectableText(
                    result.shareUrl,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 16),
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: result.shareUrl));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Lien copié')),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('Copier le lien'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
