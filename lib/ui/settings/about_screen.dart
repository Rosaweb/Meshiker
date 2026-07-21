import 'package:flutter/material.dart';
import 'terms_of_use_screen.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('À propos'),
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
                        const Text(
                          'Meshiker',
                          style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                        const Text(
                          'Version 1.0.0',
                          style: TextStyle(color: Colors.white38, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 48),
                  const Text(
                    'Meshiker est votre compagnon de randonnée ultime, conçu pour fonctionner '
                    'même dans les zones les plus reculées sans aucune connexion réseau.\n\n'
                    'Grâce à notre moteur de mesh unique, transformez vos traces GPS en une '
                    'véritable toile d\'araignée de sentiers partagée avec la communauté.',
                    style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
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
                    child: const Text(
                      'Conditions d\'utilisation',
                      style: TextStyle(color: Colors.greenAccent),
                    ),
                  ),
                  const Text(
                    '© 2026 Meshiker Project',
                    style: TextStyle(color: Colors.white24, fontSize: 12),
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
