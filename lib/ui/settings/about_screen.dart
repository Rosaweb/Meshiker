import 'package:flutter/material.dart';
import '../../l10n/generated/app_localizations.dart';
import 'terms_of_use_screen.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(loc.aboutMenuTitle),
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
        ),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Center(
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.greenAccent.withValues(alpha: 0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.terrain, color: Colors.greenAccent, size: 64),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          loc.appTitle,
                          style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          loc.aboutAppVersion,
                          style: const TextStyle(color: Colors.white38, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 48),
                  Text(
                    loc.aboutDescription,
                    style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                children: [
                  TextButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const TermsOfUseScreen()),
                      );
                    },
                    child: Text(
                      loc.termsOfUseTitle,
                      style: const TextStyle(color: Colors.greenAccent),
                    ),
                  ),
                  Text(
                    loc.aboutCopyright,
                    style: const TextStyle(color: Colors.white24, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
