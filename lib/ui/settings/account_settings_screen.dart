import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../utils/auth_service.dart';
import '../../utils/settings_service.dart';
import '../../utils/subscription_service.dart';
import '../../database/isar_service.dart';
import '../../models/utilisateur.dart';
import '../auth/login_screen.dart';
import '../auth/secure_account_screen.dart';
import 'about_screen.dart';
import 'bug_report_list_screen.dart';
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
                final settings = context.watch<SettingsService>();
                final crashReportingEnabled = settings.crashReportingEnabled;
                // La section « Cartes IGN » suit la présence du fond IGN dans
                // les cartes visibles (« Mes cartes ») : par défaut seuls les
                // utilisateurs de locale FR l'ont (semence par pays), mais
                // tout utilisateur qui active la carte IGN via « Gérer les
                // fonds de carte » voit alors aussi cette section.
                final showIgnSection =
                    settings.visibleMapIds.contains('ign_france');

                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildUserHeader(context, user, authService),
                    const SizedBox(height: 32),
                    _buildSubscriptionSection(context, subService),
                    if (showIgnSection) ...[
                      const SizedBox(height: 16),
                      _buildIgnSubscriptionPlaceholder(),
                    ],
                    const SizedBox(height: 32),
                    const Divider(color: Colors.white12),
                    // Visibilité liée uniquement au toggle système (spec
                    // §9), pas à l'état de la file : reste affichée, état
                    // vide inclus, pour apprendre passivement à
                    // l'utilisateur où regarder en cas de souci.
                    if (crashReportingEnabled) ...[
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.bug_report_outlined, color: Colors.greenAccent),
                        title: const Text('Rapport de bug', style: TextStyle(color: Colors.white)),
                        subtitle: const Text('Rapports de plantage en attente d\'envoi', style: TextStyle(color: Colors.white60)),
                        trailing: const Icon(Icons.chevron_right, color: Colors.white24),
                        onTap: () => Navigator.push(context, PageRouteBuilder(
                          pageBuilder: (context, animation, secondaryAnimation) => const BugReportListScreen(),
                          transitionsBuilder: (context, animation, secondaryAnimation, child) {
                            return SlideTransition(
                              position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(animation),
                              child: child,
                            );
                          },
                        )),
                      ),
                      const Divider(color: Colors.white12),
                    ],
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

  Widget _buildUserHeader(
      BuildContext context, Utilisateur? user, AuthService authService) {
    final isAnonymous = authService.isAnonymous;
    // L'e-mail affiché : celui de l'utilisateur local, sinon celui de la
    // session Supabase (compte permanent sans profil Isar encore synchronisé).
    final email = user?.email ?? authService.currentUser?.email;

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
        if (email != null)
          Text(
            email,
            style: const TextStyle(color: Colors.white70),
          ),
        const SizedBox(height: 12),
        // Statut du compte, autrefois dans la section « SYNCHRONISATION » :
        // fusionné ici pour éviter la redondance avec l'e-mail de l'entête.
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isAnonymous ? Icons.warning_amber : Icons.check_circle,
              size: 16,
              color: isAnonymous ? Colors.orangeAccent : Colors.greenAccent,
            ),
            const SizedBox(width: 6),
            Text(
              isAnonymous ? 'Mode anonyme (non récupérable)' : 'Compte permanent synchronisé',
              style: TextStyle(
                color: isAnonymous ? Colors.orangeAccent : Colors.white60,
                fontSize: 12,
              ),
            ),
          ],
        ),
        if (isAnonymous)
          Padding(
            padding: const EdgeInsets.only(top: 12),
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
                      'Plan IGN disponible dans « Mes cartes ». Abonnement annuel SCAN25 '
                      '(cartes de randonnée au 1:25 000) : bientôt disponible.',
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

}
