import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../utils/subscription_service.dart';
import '../../database/isar_service.dart';
import '../../models/utilisateur.dart';
import 'about_screen.dart';

import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';

class AccountSettingsScreen extends StatelessWidget {
  const AccountSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(loc.accountSettingsTitle),
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
        ),
        body: Consumer2<SubscriptionService, IsarService>(
          builder: (context, subService, isar, child) {
            return FutureBuilder<Utilisateur?>(
              future: isar.currentDeviceUser(),
              builder: (context, snapshot) {
                final user = snapshot.data;

                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildUserHeader(context, user),
                    const SizedBox(height: 32),
                    _buildSubscriptionSection(context, subService),
                    const SizedBox(height: 16),
                    _buildIgnSubscriptionPlaceholder(context),
                    const SizedBox(height: 32),
                    _buildSyncSection(context, user),
                    const SizedBox(height: 32),
                    const Divider(color: Colors.white12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.info_outline, color: Colors.greenAccent),
                      title: Text(loc.aboutMenuTitle, style: const TextStyle(color: Colors.white)),
                      subtitle: Text(loc.aboutMenuSubtitle, style: const TextStyle(color: Colors.white60)),
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

  Widget _buildUserHeader(BuildContext context, Utilisateur? user) {
    final loc = AppLocalizations.of(context)!;
    return Column(
      children: [
        CircleAvatar(
          radius: 40,
          backgroundColor: Colors.greenAccent.withValues(alpha: 0.2),
          child: const Icon(Icons.person, size: 40, color: Colors.greenAccent),
        ),
        const SizedBox(height: 16),
        Text(
          user?.pseudo ?? loc.localUserFallback,
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
    final loc = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          loc.subscriptionSectionTitle,
          style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold),
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
                          subService.isPremium ? loc.premiumMemberLabel : loc.freeTierLabel,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          subService.isPremium
                            ? loc.premiumUnlimitedAccessLabel
                            : loc.premiumUpsellLabel,
                          style: const TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (!subService.sdkAvailable)
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text(
                    loc.subscriptionServiceUnavailableMessage,
                    style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                )
              else if (!subService.isPremium)
                ElevatedButton(
                  onPressed: () async {
                    // Présente le Paywall RevenueCat (Best practice moderne)
                    await RevenueCatUI.presentPaywall();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.greenAccent,
                    foregroundColor: Colors.black,
                    minimumSize: const Size(double.infinity, 45),
                  ),
                  child: Text(loc.viewPremiumOffersButton),
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
                  child: Text(loc.manageSubscriptionButton),
                ),
              TextButton(
                onPressed: () => subService.restorePurchases(),
                child: Text(loc.restorePurchasesButton, style: const TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildIgnSubscriptionPlaceholder(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blueAccent.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.map, color: Colors.blueAccent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loc.ignMapsTitle,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      loc.ignMapsComingSoon,
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
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

  Widget _buildSyncSection(BuildContext context, Utilisateur? user) {
    final loc = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          loc.syncSectionTitle,
          style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.cloud_queue, color: Colors.white70),
          title: Text(loc.syncStatusLabel, style: const TextStyle(color: Colors.white)),
          subtitle: Text(
            user?.remoteId != null ? loc.syncConnectedLabel : loc.syncLocalOnlyLabel,
            style: const TextStyle(color: Colors.white38),
          ),
          trailing: user?.remoteId != null
            ? const Icon(Icons.check_circle, color: Colors.greenAccent)
            : const Icon(Icons.warning_amber, color: Colors.orangeAccent),
        ),
      ],
    );
  }
}
