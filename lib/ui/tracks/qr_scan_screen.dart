import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../l10n/generated/app_localizations.dart';

/// Écran plein écran de scan de QR code : se contente de rendre le flux
/// caméra et de renvoyer (via `Navigator.pop`) la première valeur détectée.
/// La permission caméra est gérée par l'appelant, avant la navigation
/// (voir `ImportShareScreen`), pas ici.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final value = capture.barcodes
        .firstWhere((b) => b.rawValue != null && b.rawValue!.isNotEmpty, orElse: () => const Barcode())
        .rawValue;
    if (value == null) return;
    _handled = true;
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(AppLocalizations.of(context)!.scanQrCodeLabel),
      ),
      body: MobileScanner(onDetect: _onDetect),
    );
  }
}
