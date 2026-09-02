import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../utils/pedometer_service.dart';
import '../utils/settings_service.dart';

/// Écran podomètre plein écran, accessible par un double tap sur la carte
/// « Podomètre » du volet Navigation. Reprend la charte graphique des autres
/// écrans de détail (fond noir, cartes translucides, accent) : compteur de
/// pas de la session, état de marche, distance estimée et détail du
/// calibrage par pente.
class PedometerScreen extends StatelessWidget {
  const PedometerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pedometer = context.watch<PedometerService>();
    final settings = context.watch<SettingsService>();
    final accent = settings.accentColor;

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
          _buildHeroCard(context, pedometer, settings, accent),
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
          Text(
            'CALIBRAGE PAR PENTE',
            style: TextStyle(
                color: accent, fontSize: 12, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Longueur de pas apprise pendant vos enregistrements, selon la pente du terrain.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 16),
          ...pedometer.profiles.map((p) => _buildProfileCard(p, settings, accent)),
        ],
      ),
    );
  }

  Widget _buildHeroCard(BuildContext context, PedometerService pedometer,
      SettingsService settings, Color accent) {
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
              _Metric(
                label: 'État',
                value: _statusLabel(pedometer.status),
              ),
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

  Widget _buildProfileCard(
      PedometerProfile profile, SettingsService settings, Color accent) {
    final calibrated = profile.totalSteps > 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
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
                Text(_profileLabel(profile.id),
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(
                  calibrated
                      ? '${profile.totalSteps} pas de référence'
                      : 'Valeur par défaut (non calibré)',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
          ),
          Text(
            _formatStepLength(profile.metersPerStep, settings.unitSystem),
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ],
      ),
    );
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
        return 'Montée raide';
      case 'uphill':
        return 'Montée';
      case 'flat':
        return 'Terrain plat';
      case 'downhill':
        return 'Descente';
      case 'steep_downhill':
        return 'Descente raide';
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
            child: Text(text,
                style: TextStyle(color: color, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
