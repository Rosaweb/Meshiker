import 'package:flutter/material.dart';

class TermsOfUseScreen extends StatelessWidget {
  const TermsOfUseScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Conditions d\'utilisation'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
        ),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: const [
            Text(
              'Conditions Générales d\'Utilisation de Meshiker',
              style: TextStyle(color: Colors.greenAccent, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 24),
            Text(
              '1. Acceptation des conditions\n'
              'En utilisant l\'application Meshiker, vous acceptez d\'être lié par les présentes conditions générales d\'utilisation.\n\n'
              '2. Services fournis\n'
              'Meshiker fournit des outils de navigation GPS, de cartographie et de suivi d\'activité pour la randonnée.\n\n'
              '3. Responsabilité\n'
              'L\'utilisation du GPS et de la cartographie en montagne comporte des risques. L\'utilisateur reste seul responsable de sa sécurité. Meshiker ne peut être tenu responsable en cas d\'accident ou d\'erreur de navigation.\n\n'
              '4. Données personnelles\n'
              'Meshiker respecte votre vie privée. Vos traces et waypoints sont stockés localement sur votre appareil, sauf si vous choisissez de les synchroniser avec votre compte Supabase.\n\n'
              '5. Abonnements Pro\n'
              'Les fonctionnalités Premium sont soumises à un abonnement géré via RevenueCat. Les conditions de remboursement sont celles des boutiques d\'applications respectives (Apple App Store / Google Play Store).\n\n'
              '6. Propriété intellectuelle\n'
              'Le code source de l\'application et les designs sont la propriété exclusive de Meshiker.\n\n'
              '7. Modification des conditions\n'
              'Nous nous réservons le droit de modifier ces conditions à tout moment.',
              style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
            ),
            SizedBox(height: 48),
            Text(
              'Dernière mise à jour : Juillet 2026',
              style: TextStyle(color: Colors.white38, fontSize: 12, fontStyle: FontStyle.italic),
            ),
          ],
        ),
      ),
    );
  }
}
