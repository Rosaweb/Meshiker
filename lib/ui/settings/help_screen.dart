import 'package:flutter/material.dart';
import '../../l10n/generated/app_localizations.dart';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(loc.helpMenuTitle),
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Text(
              loc.helpScreenPlaceholder,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38),
            ),
          ),
        ),
      ),
    );
  }
}
