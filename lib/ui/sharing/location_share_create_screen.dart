import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../sharing/location_share_models.dart';
import '../../sharing/location_share_service.dart';
import 'location_share_active_screen.dart';

/// Écran cascade de création d'un partage de position (spec
/// spec-partage-position-live-tracking.md §9) : chaque choix révèle et
/// configure les sections suivantes ; changer un choix en amont réinitialise
/// les sélections en aval (jamais de combinaison incohérente laissée
/// affichée silencieusement).
///
/// Adaptation par rapport au texte brut de la spec : le bouton "Inviter"
/// (QR/lien App-to-app) et la liste des invités vivent sur l'écran
/// "Partage actif" (`LocationShareActiveScreen`), pas ici — un partage doit
/// exister côté serveur (donc avoir un `share_token`) avant de pouvoir
/// générer un lien d'invitation, et `createShare` crée la ligne de façon
/// atomique avec tous les réglages déjà arrêtés. Fonctionnellement
/// équivalent : l'invitation reste disponible dès l'écran suivant, avant
/// même qu'un tiers n'ait rejoint.
class LocationShareCreateScreen extends StatefulWidget {
  const LocationShareCreateScreen({super.key});

  @override
  State<LocationShareCreateScreen> createState() => _LocationShareCreateScreenState();
}

/// Fréquences Live proposées (spec §3), en secondes.
const _liveIntervals = <int>[5, 10, 30, 60, 180, 300, 600, 900, 1800, 3600, 5400, 7200];

class _LocationShareCreateScreenState extends State<LocationShareCreateScreen> {
  LocationShareMode? _mode;
  final Set<LocationShareChannel> _channels = {};
  LocationShareReciprocity _reciprocity = LocationShareReciprocity.unilateral;
  int _liveIntervalSeconds = 30;
  final List<TimeOfDay> _autoTimes = [const TimeOfDay(hour: 8, minute: 0)];
  bool _historyEnabled = false;
  bool _historyGlobal = false;

  final _labelController = TextEditingController();
  final _emailController = TextEditingController();
  final List<String> _emailAddresses = [];

  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _labelController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  /// Étape 1 : changer de mode réinitialise tout ce qui en dépend en aval
  /// (spec §9 : "aucune combinaison incohérente laissée affichée
  /// silencieusement").
  void _selectMode(LocationShareMode mode) {
    setState(() {
      _mode = mode;
      _channels.clear();
      _reciprocity = LocationShareReciprocity.unilateral;
      _historyEnabled = false;
      _historyGlobal = false;
      _emailAddresses.clear();
    });
  }

  void _toggleChannel(LocationShareChannel channel, bool value) {
    setState(() {
      if (value) {
        _channels.add(channel);
      } else {
        _channels.remove(channel);
        if (channel == LocationShareChannel.app) _historyGlobal = false;
      }
    });
  }

  void _addEmail() {
    final value = _emailController.text.trim();
    if (value.isEmpty || _emailAddresses.contains(value)) return;
    setState(() {
      _emailAddresses.add(value);
      _emailController.clear();
    });
  }

  bool get _canSubmit {
    if (_mode == null || _isSubmitting) return false;
    if (_channels.contains(LocationShareChannel.email) && _emailAddresses.isEmpty) return false;
    return true;
  }

  /// Convertit un `TimeOfDay` local (celui choisi via `showTimePicker`, en
  /// heure de l'appareil) en UTC avant envoi — `location_shares.auto_times`
  /// est un `time[]` sans fuseau, et le cron serveur qui déclenche les
  /// check-ins (`due_auto_location_shares`, voir functions.sql) compare
  /// contre `now()` en UTC. Sans cette conversion, un check-in "8h" pour un
  /// utilisateur en CEST se déclencherait en réalité à 8h UTC (10h locale),
  /// décalage silencieux d'autant d'heures que le fuseau de l'appareil.
  String _formatTimeOfDay(TimeOfDay t) {
    final now = DateTime.now();
    final localToday = DateTime(now.year, now.month, now.day, t.hour, t.minute).toUtc();
    return '${localToday.hour.toString().padLeft(2, '0')}:${localToday.minute.toString().padLeft(2, '0')}:00';
  }

  String _formatInterval(int seconds) {
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}min';
    final hours = seconds / 3600;
    return hours == hours.roundToDouble() ? '${hours.round()}h' : '${hours}h';
  }

  Future<void> _submit() async {
    final mode = _mode;
    if (mode == null) return;
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    final service = context.read<LocationShareService>();
    try {
      await service.createShare(
        label: _labelController.text.trim().isEmpty ? null : _labelController.text.trim(),
        mode: mode,
        channels: _channels,
        reciprocity: _reciprocity,
        liveIntervalSeconds: mode == LocationShareMode.live ? _liveIntervalSeconds : null,
        autoTimes: mode == LocationShareMode.auto ? _autoTimes.map(_formatTimeOfDay).toList() : null,
        historyEnabled: mode != LocationShareMode.manual && _historyEnabled,
        historyGlobal: mode != LocationShareMode.manual && _historyGlobal,
        // Passés directement à createShare (pas ajoutés après coup) : pour
        // le mode Manuel, l'email doit partir avant que le partage ne soit
        // arrêté dans ce même appel — voir le commentaire sur
        // LocationShareService.createShare.
        emailAddresses: _emailAddresses.toSet(),
      );

      if (!mounted) return;
      if (mode == LocationShareMode.manual) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Position envoyée.')),
        );
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const LocationShareActiveScreen()),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _errorMessage = e is LocationShareException ? e.message : 'Une erreur inattendue est survenue.';
      });
    }
  }

  String get _submitLabel {
    switch (_mode) {
      case LocationShareMode.manual:
        return 'Partager maintenant';
      case LocationShareMode.auto:
        return 'Démarrer le partage automatique';
      case LocationShareMode.live:
        return 'Démarrer le live';
      case null:
        return 'Continuer';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        title: const Text('Nouveau partage de position'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _labelController,
            style: const TextStyle(color: Colors.white),
            decoration: _inputDecoration('Nom du partage (optionnel)', hint: 'Ex. Battue du 12 septembre'),
          ),
          const SizedBox(height: 24),
          _sectionTitle('1. Mode'),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _ChoiceButton(label: 'Manuel', selected: _mode == LocationShareMode.manual, onTap: () => _selectMode(LocationShareMode.manual))),
              const SizedBox(width: 8),
              Expanded(child: _ChoiceButton(label: 'Auto', selected: _mode == LocationShareMode.auto, onTap: () => _selectMode(LocationShareMode.auto))),
              const SizedBox(width: 8),
              Expanded(child: _ChoiceButton(label: 'Live', selected: _mode == LocationShareMode.live, onTap: () => _selectMode(LocationShareMode.live))),
            ],
          ),
          if (_mode != null) ..._buildStep2Diffusion(),
          if (_mode != null && _mode != LocationShareMode.manual && _channels.contains(LocationShareChannel.app))
            ..._buildStep3Reciprocity(),
          if (_mode == LocationShareMode.auto) ..._buildAutoParams(),
          if (_mode == LocationShareMode.live) ..._buildLiveParams(),
          if (_mode != null && _mode != LocationShareMode.manual) ..._buildStep5Options(),
          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            Text(_errorMessage!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: _canSubmit ? _submit : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.greenAccent,
              foregroundColor: Colors.black,
              minimumSize: const Size(double.infinity, 48),
            ),
            child: _isSubmitting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(_submitLabel),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  List<Widget> _buildStep2Diffusion() {
    final isLive = _mode == LocationShareMode.live;
    return [
      const SizedBox(height: 28),
      _sectionTitle('2. Diffusion'),
      const SizedBox(height: 4),
      _ChannelTile(
        label: 'Web',
        subtitle: 'Bientôt disponible',
        icon: Icons.public,
        enabled: false,
        value: false,
        onChanged: null,
      ),
      if (!isLive)
        _ChannelTile(
          label: 'Email',
          icon: Icons.email_outlined,
          enabled: true,
          value: _channels.contains(LocationShareChannel.email),
          onChanged: (v) => _toggleChannel(LocationShareChannel.email, v),
        ),
      if (!isLive && _channels.contains(LocationShareChannel.email)) _buildEmailSubForm(),
      _ChannelTile(
        label: 'SMS',
        subtitle: 'Bientôt disponible',
        icon: Icons.sms_outlined,
        enabled: false,
        value: false,
        onChanged: null,
      ),
      _ChannelTile(
        label: 'App-to-app',
        subtitle: 'Suivi mutuel entre comptes Meshiker',
        icon: Icons.people_outline,
        enabled: true,
        value: _channels.contains(LocationShareChannel.app),
        onChanged: (v) => _toggleChannel(LocationShareChannel.app, v),
      ),
      if (_channels.contains(LocationShareChannel.app))
        const Padding(
          padding: EdgeInsets.only(left: 16, right: 16, bottom: 8),
          child: Text(
            'Le lien/QR d\'invitation sera disponible dès le démarrage du partage.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ),
    ];
  }

  Widget _buildEmailSubForm() {
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _emailController,
                  style: const TextStyle(color: Colors.white),
                  keyboardType: TextInputType.emailAddress,
                  decoration: _inputDecoration('Adresse email', dense: true),
                  onSubmitted: (_) => _addEmail(),
                ),
              ),
              IconButton(
                onPressed: _addEmail,
                icon: const Icon(Icons.add_circle, color: Colors.greenAccent),
              ),
            ],
          ),
          if (_emailAddresses.isNotEmpty)
            Wrap(
              spacing: 8,
              children: _emailAddresses
                  .map((e) => Chip(
                        label: Text(e, style: const TextStyle(color: Colors.black)),
                        backgroundColor: Colors.white70,
                        onDeleted: () => setState(() => _emailAddresses.remove(e)),
                      ))
                  .toList(),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildStep3Reciprocity() {
    return [
      const SizedBox(height: 28),
      _sectionTitle('3. Réciprocité'),
      const SizedBox(height: 8),
      Row(
        children: LocationShareReciprocity.values.map((r) {
          final label = switch (r) {
            LocationShareReciprocity.unilateral => 'Unilatéral',
            LocationShareReciprocity.bilateral => 'Bilatéral',
            LocationShareReciprocity.multilateral => 'Multilatéral',
          };
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _ChoiceButton(
                label: label,
                selected: _reciprocity == r,
                onTap: () => setState(() => _reciprocity = r),
              ),
            ),
          );
        }).toList(),
      ),
    ];
  }

  List<Widget> _buildAutoParams() {
    return [
      const SizedBox(height: 28),
      _sectionTitle('4. Paramètres — check-ins'),
      const SizedBox(height: 8),
      ..._autoTimes.asMap().entries.map((entry) {
        final index = entry.key;
        final time = entry.value;
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.access_time, color: Colors.white70),
          title: Text(time.format(context), style: const TextStyle(color: Colors.white)),
          trailing: _autoTimes.length > 1
              ? IconButton(
                  icon: const Icon(Icons.remove_circle_outline, color: Colors.white38),
                  onPressed: () => setState(() => _autoTimes.removeAt(index)),
                )
              : null,
          onTap: () async {
            final picked = await showTimePicker(context: context, initialTime: time);
            if (picked != null) setState(() => _autoTimes[index] = picked);
          },
        );
      }),
      if (_autoTimes.length < 3)
        TextButton.icon(
          onPressed: () => setState(() => _autoTimes.add(const TimeOfDay(hour: 18, minute: 0))),
          icon: const Icon(Icons.add),
          label: const Text('Ajouter un check-in'),
        ),
    ];
  }

  List<Widget> _buildLiveParams() {
    return [
      const SizedBox(height: 28),
      _sectionTitle('4. Paramètres — fréquence'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _liveIntervals.map((seconds) {
          final selected = _liveIntervalSeconds == seconds;
          return ChoiceChip(
            label: Text(_formatInterval(seconds)),
            selected: selected,
            onSelected: (_) => setState(() => _liveIntervalSeconds = seconds),
            selectedColor: Colors.greenAccent,
            labelStyle: TextStyle(color: selected ? Colors.black : Colors.white70),
            backgroundColor: Colors.white10,
          );
        }).toList(),
      ),
    ];
  }

  List<Widget> _buildStep5Options() {
    final canHistoryGlobal = _channels.contains(LocationShareChannel.app);
    return [
      const SizedBox(height: 28),
      _sectionTitle('5. Options'),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Activer l\'historique', style: TextStyle(color: Colors.white)),
        subtitle: const Text(
          'Affiche le tracé accumulé et propose de le sauvegarder en fin de session.',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
        value: _historyEnabled,
        onChanged: (v) => setState(() {
          _historyEnabled = v;
          if (!v) _historyGlobal = false;
        }),
        activeThumbColor: Colors.greenAccent,
      ),
      if (_historyEnabled && canHistoryGlobal)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Conserver l\'historique de tout le groupe', style: TextStyle(color: Colors.white)),
          subtitle: const Text(
            'Nécessite le consentement individuel de chaque membre — utile pour un groupe de plusieurs personnes.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          value: _historyGlobal,
          onChanged: (v) => setState(() => _historyGlobal = v),
          activeThumbColor: Colors.greenAccent,
        ),
    ];
  }

  Widget _sectionTitle(String text) =>
      Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15));

  InputDecoration _inputDecoration(String label, {String? hint, bool dense = false}) => InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: Colors.white54),
        hintStyle: const TextStyle(color: Colors.white24),
        isDense: dense,
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      );
}

class _ChoiceButton extends StatelessWidget {
  const _ChoiceButton({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        backgroundColor: selected ? Colors.greenAccent : Colors.transparent,
        side: BorderSide(color: selected ? Colors.greenAccent : Colors.white24),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
      child: Text(label, style: TextStyle(color: selected ? Colors.black : Colors.white)),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      enabled: enabled,
      value: value,
      onChanged: enabled ? (v) => onChanged?.call(v ?? false) : null,
      activeColor: Colors.greenAccent,
      secondary: Icon(icon, color: enabled ? Colors.white70 : Colors.white24),
      title: Text(label, style: TextStyle(color: enabled ? Colors.white : Colors.white38)),
      subtitle: subtitle != null
          ? Text(subtitle!, style: const TextStyle(color: Colors.orangeAccent, fontSize: 12))
          : null,
    );
  }
}
