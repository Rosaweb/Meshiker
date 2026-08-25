import 'package:flutter/material.dart';
import '../../l10n/generated/app_localizations.dart';

class TermsOfUseScreen extends StatelessWidget {
  const TermsOfUseScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(loc.termsOfUseTitle),
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
        ),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              loc.termsOfUseHeading,
              style: const TextStyle(color: Colors.greenAccent, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            Text(
              loc.termsOfUseBody,
              style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 48),
            Text(
              loc.termsOfUseLastUpdated,
              style: const TextStyle(color: Colors.white38, fontSize: 12, fontStyle: FontStyle.italic),
            ),
          ],
        ),
      ),
    );
  }
}
