import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../utils/pedometer_service.dart';
import '../utils/settings_service.dart';

/// Écran podomètre plein écran, accessible par un double tap sur la carte
/// « Podomètre » du volet Navigation. Reprend la charte des autres écrans de
/// détail (fond noir, cartes translucides, couleur d'accent) et regroupe les
/// 4 métriques : compteur de pas à vie, total calibré avec GPS, pas moyen
/// pour 100 m, et le détail du calibrage par pente.
class PedometerScreen extends StatelessWidget {
  const PedometerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pedometer = context.watch<PedometerService>();
    final settings = context.watch<SettingsService>();
    final accent = settings.accentColor;
    final calibrationOn = settings.pedometerCalibrationEnabled;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Podomètre'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildLifetimeCard(context, pedometer, accent),
          const SizedBox(height: 12),
          _buildHeroCard(pedometer, settings, accent),
          const SizedBox(height: 12),
          _buildToggleButton(context, pedometer, accent),
          if (pedometer.permissionDenied)
            const _Hint(
              icon: Icons.lock_outline,
              color: Colors.orangeAccent,
              text:
                  'Autorisez « Activité physique » dans les paramètres Android pour utiliser le podomètre.',
            ),
          if (pedometer.sensorUnavailable)
            const _Hint(
              icon: Icons.sensors_off,
              color: Colors.orangeAccent,
              text: 'Aucun capteur de pas détecté sur cet appareil.',
            ),
          const SizedBox(height: 28),
          _buildMetricCard(
            icon: Icons.route,
            accent: accent,
            label: 'Calibré avec le GPS',
            value: pedometer.totalCalibratedSteps > 0
                ? '${_thousands(pedometer.totalCalibratedSteps)} pas'
                  ' / ${_formatDistance(pedometer.totalCalibratedDistanceMeters, settings.unitSystem)}'
                : 'Aucune donnée',
          ),
          const SizedBox(height: 10),
          _buildMetricCard(
            icon: Icons.straighten,
            accent: accent,
            label: 'Pas moyen pour 100 m',
            value: pedometer.avgStepsPer100m == null
                ? '—'
                : '${pedometer.avgStepsPer100m!.round()} pas / 100 m',
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: Text(
                  'CALIBRAGE PAR PENTE',
                  style: TextStyle(
                      color: accent,
                      fontSize: 12,
                      fontWeight: FontWeight.bold),
                ),
              ),
              TextButton(
                onPressed: () async {
                  final ok = await _confirm(
                    context,
                    title: 'Réinitialiser tous les profils ?',
                    body:
                        'Les 5 profils reviennent à leurs valeurs par défaut. Cette action est irréversible.',
                    confirmLabel: 'RÉINITIALISER',
                  );
                  if (ok) await pedometer.resetAllProfiles();
                },
                child: const Text('Tout réinitialiser',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeThumbColor: accent,
            value: calibrationOn,
            onChanged: settings.setPedometerCalibrationEnabled,
            title: const Text('Calibrage automatique',
                style: TextStyle(color: Colors.white)),
            subtitle: Text(
              calibrationOn
                  ? 'La longueur de pas s\'affine pendant vos sorties GPS.'
                  : 'Gelé : les stats ci-dessous ne bougent plus.',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Longueur de pas apprise selon la pente du terrain.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 16),
          ...pedometer.profilesSortedBySlope
              .map((p) => _buildProfileCard(context, pedometer, p, settings, accent)),
        ],
      ),
    );
  }

  Widget _buildLifetimeCard(
      BuildContext context, PedometerService pedometer, Color accent) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.emoji_flags, color: accent, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_thousands(pedometer.totalStepsAllTime),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold)),
                const Text('pas au total (toutes activations)',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.restart_alt, color: Colors.white54),
            tooltip: 'Réinitialiser le total',
            onPressed: () async {
              final ok = await _confirm(
                context,
                title: 'Réinitialiser le total de pas ?',
                body: 'Cette action est irréversible.',
                confirmLabel: 'RÉINITIALISER',
              );
              if (ok) await pedometer.resetTotalSteps();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildHeroCard(
      PedometerService pedometer, SettingsService settings, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: pedometer.isActive ? accent : accent.withValues(alpha: 0.2),
            width: pedometer.isActive ? 2.0 : 1.0),
      ),
      child: Column(
        children: [
          Icon(Icons.directions_walk, color: accent, size: 32),
          const SizedBox(height: 12),
          Text(
            '${pedometer.steps}',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 48,
                fontWeight: FontWeight.bold),
          ),
          const Text('pas depuis l\'activation',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _Metric(label: 'État', value: _statusLabel(pedometer.status)),
              _Metric(
                label: 'Distance estimée',
                value: _formatDistance(
                    pedometer.sessionDistanceMeters, settings.unitSystem),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildToggleButton(
      BuildContext context, PedometerService pedometer, Color accent) {
    final active = pedometer.isActive;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () async {
          await pedometer.togglePedometer();
          if (!context.mounted) return;
          if (pedometer.permissionDenied) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text(
                    'Autorisez « Activité physique » dans les paramètres Android pour utiliser le podomètre.')));
          } else if (pedometer.sensorUnavailable) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content:
                    Text('Aucun capteur de pas détecté sur cet appareil.')));
          }
        },
        icon: Icon(active ? Icons.pause : Icons.play_arrow),
        label: Text(active ? 'Désactiver le podomètre' : 'Activer le podomètre'),
        style: ElevatedButton.styleFrom(
          backgroundColor: active ? Colors.white10 : accent,
          foregroundColor: active ? Colors.white : Colors.black,
          minimumSize: const Size(double.infinity, 46),
        ),
      ),
    );
  }

  Widget _buildMetricCard({
    required IconData icon,
    required Color accent,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(icon, color: accent, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15)),
        ],
      ),
    );
  }

  Widget _buildProfileCard(BuildContext context, PedometerService pedometer,
      PedometerProfile profile, SettingsService settings, Color accent) {
    final calibrated = profile.totalSteps > 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(_profileIcon(profile.id), color: accent, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(_profileLabel(profile.id),
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold)),
                    if (profile.frozen) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('stable',
                            style: TextStyle(color: accent, fontSize: 10)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  calibrated
                      ? '${_thousands(profile.totalSteps)} pas de référence'
                      : 'Valeur par défaut (non calibré)',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
          ),
          Text(
            _formatStepLength(profile.metersPerStep, settings.unitSystem),
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white38, size: 20),
            color: const Color(0xFF1E1E1E),
            onSelected: (action) async {
              if (action == 'unfreeze') {
                await pedometer.unfreezeProfile(profile.id);
              } else if (action == 'reset') {
                final ok = await _confirm(
                  context,
                  title: 'Réinitialiser « ${_profileLabel(profile.id)} » ?',
                  body:
                      'Ce profil revient à sa valeur par défaut. Cette action est irréversible.',
                  confirmLabel: 'RÉINITIALISER',
                );
                if (ok) await pedometer.resetProfile(profile.id);
              }
            },
            itemBuilder: (context) => [
              if (profile.frozen)
                const PopupMenuItem(
                  value: 'unfreeze',
                  child: Text('Réactiver'),
                ),
              const PopupMenuItem(
                value: 'reset',
                child: Text('Réinitialiser ce profil'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ANNULER')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(confirmLabel)),
        ],
      ),
    );
    return result == true;
  }

  static String _statusLabel(String status) {
    switch (status) {
      case 'walking':
        return 'En marche';
      case 'stopped':
        return 'Arrêté';
      case 'unknown':
        return 'Inconnu';
      default:
        return status;
    }
  }

  static String _profileLabel(String id) {
    switch (id) {
      case 'steep_uphill':
        return 'Forte montée';
      case 'uphill':
        return 'Montée';
      case 'flat':
        return 'Plat';
      case 'downhill':
        return 'Descente';
      case 'steep_downhill':
        return 'Forte descente';
      default:
        return id;
    }
  }

  static IconData _profileIcon(String id) {
    switch (id) {
      case 'steep_uphill':
      case 'uphill':
        return Icons.trending_up;
      case 'downhill':
      case 'steep_downhill':
        return Icons.trending_down;
      default:
        return Icons.trending_flat;
    }
  }

  /// Sépare les milliers par une espace fine insécable (« 12 430 »).
  static String _thousands(int n) {
    final s = n.abs().toString();
    final buf = StringBuffer(n < 0 ? '-' : '');
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  static String _formatDistance(double meters, UnitSystem unit) {
    if (unit == UnitSystem.metric) {
      return meters >= 1000
          ? '${(meters / 1000).toStringAsFixed(2)} km'
          : '${meters.round()} m';
    }
    final feet = meters * 3.28084;
    return feet >= 5280
        ? '${(feet / 5280).toStringAsFixed(2)} mi'
        : '${feet.round()} ft';
  }

  static String _formatStepLength(double metersPerStep, UnitSystem unit) {
    if (unit == UnitSystem.metric) {
      return '${metersPerStep.toStringAsFixed(2)} m/pas';
    }
    return '${(metersPerStep * 3.28084).toStringAsFixed(2)} ft/pas';
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;

  const _Metric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(color: Colors.white38, fontSize: 12)),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _Hint({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: color, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
