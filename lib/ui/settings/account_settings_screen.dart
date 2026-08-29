import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../utils/auth_service.dart';
import '../../utils/subscription_service.dart';
import '../../database/isar_service.dart';
import '../../models/utilisateur.dart';
import '../auth/login_screen.dart';
import '../auth/secure_account_screen.dart';
import 'about_screen.dart';
import 'promo_code_bottom_sheet.dart';

import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';

class AccountSettingsScreen extends StatelessWidget {
  const AccountSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Mon compte'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
        ),
        body: Consumer3<SubscriptionService, IsarService, AuthService>(
          builder: (context, subService, isar, authService, child) {
            return FutureBuilder<Utilisateur?>(
              future: isar.currentDeviceUser(),
              builder: (context, snapshot) {
                final user = snapshot.data;

                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildUserHeader(user),
                    const SizedBox(height: 32),
                    _buildSubscriptionSection(context, subService),
                    const SizedBox(height: 16),
                    _buildIgnSubscriptionPlaceholder(),
                    const SizedBox(height: 32),
                    _buildSyncSection(context, authService),
                    const SizedBox(height: 32),
                    const Divider(color: Colors.white12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.info_outline, color: Colors.greenAccent),
                      title: const Text('À propos', style: TextStyle(color: Colors.white)),
                      subtitle: const Text('Version, légal et contact', style: TextStyle(color: Colors.white60)),
                      trailing: const Icon(Icons.chevron_right, color: Colors.white24),
                      onTap: () => Navigator.push(context, PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) => const AboutScreen(),
                        transitionsBuilder: (context, animation, secondaryAnimation, child) {
                          return SlideTransition(
                            position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(animation),
                            child: child,
                          );
                        },
                      )),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildUserHeader(Utilisateur? user) {
    return Column(
      children: [
        CircleAvatar(
          radius: 40,
          backgroundColor: Colors.greenAccent.withValues(alpha: 0.2),
          child: const Icon(Icons.person, size: 40, color: Colors.greenAccent),
        ),
        const SizedBox(height: 16),
        Text(
          user?.pseudo ?? 'Utilisateur local',
          style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
        ),
        if (user?.email != null)
          Text(
            user!.email!,
            style: const TextStyle(color: Colors.white70),
          ),
      ],
    );
  }

  Widget _buildSubscriptionSection(BuildContext context, SubscriptionService subService) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'ABONNEMENT',
          style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(
                    subService.isPremium ? Icons.verified : Icons.stars,
                    color: subService.isPremium ? Colors.greenAccent : Colors.orangeAccent,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          subService.isPremium ? 'Membre Premium' : 'Formule Gratuite',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          subService.isPremium 
                            ? 'Accès illimité à toutes les fonctionnalités'
                            : 'Passez au Premium pour soutenir le projet',
                          style: const TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (!subService.sdkAvailable)
                const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Text(
                    'Le service d\'abonnement est indisponible pour le moment.',
                    style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                )
              else if (!subService.isPremium)
                ElevatedButton(
                  onPressed: () async {
                    // Présente le Paywall RevenueCat (Best practice moderne)
                    final result = await RevenueCatUI.presentPaywall();
                    if (result == PaywallResult.purchased && context.mounted) {
                      // Spec section 4 : proposer immédiatement de sécuriser
                      // le compte anonyme après un achat réussi.
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const SecureAccountScreen()));
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.greenAccent,
                    foregroundColor: Colors.black,
                    minimumSize: const Size(double.infinity, 45),
                  ),
                  child: const Text('Voir les offres Premium'),
                )
              else
                ElevatedButton(
                  onPressed: () async {
                    // Ouvre le centre de gestion des abonnements
                    await subService.presentCustomerCenter();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white10,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 45),
                  ),
                  child: const Text('Gérer mon abonnement'),
                ),
              TextButton(
                onPressed: () => subService.restorePurchases(),
                child: const Text('Restaurer mes achats', style: TextStyle(color: Colors.white70)),
              ),
              if (!subService.isPremium)
                TextButton(
                  onPressed: () => PromoCodeBottomSheet.show(context),
                  child: const Text("J'ai un code", style: TextStyle(color: Colors.white70)),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildIgnSubscriptionPlaceholder() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blueAccent.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.2)),
      ),
      child: const Column(
        children: [
          Row(
            children: [
              Icon(Icons.map, color: Colors.blueAccent),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Cartes IGN (France)',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      'Bientôt disponible : abonnement annuel pour les fonds de carte IGN SCAN25 et Plan IGN.',
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSyncSection(BuildContext context, AuthService authService) {
    final isAnonymous = authService.isAnonymous;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'SYNCHRONISATION',
          style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.cloud_queue, color: Colors.white70),
          title: const Text('Statut du compte', style: TextStyle(color: Colors.white)),
          subtitle: Text(
            isAnonymous ? 'Mode anonyme (non récupérable)' : 'Connecté (${authService.currentUser?.email ?? "compte permanent"})',
            style: const TextStyle(color: Colors.white38),
          ),
          trailing: isAnonymous
            ? const Icon(Icons.warning_amber, color: Colors.orangeAccent)
            : const Icon(Icons.check_circle, color: Colors.greenAccent),
        ),
        if (isAnonymous)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: OutlinedButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginScreen())),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white24),
                minimumSize: const Size(double.infinity, 40),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Déjà un compte ? Se connecter'),
            ),
          ),
      ],
    );
  }
}
