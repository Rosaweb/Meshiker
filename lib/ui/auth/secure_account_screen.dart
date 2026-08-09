import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../../utils/auth_service.dart';

/// Écran "Sécurise ton compte" affiché juste après un achat réussi (spec
/// section 4) : propose de compléter la session anonyme (Google natif ou
/// email/mot de passe) en conservant le même UUID Supabase, avec repli
/// automatique sur une connexion classique si ce compte existe déjà.
class SecureAccountScreen extends StatefulWidget {
  const SecureAccountScreen({super.key});

  @override
  State<SecureAccountScreen> createState() => _SecureAccountScreenState();
}

class _SecureAccountScreenState extends State<SecureAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  bool _showEmailForm = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleGoogle() async {
    setState(() => _loading = true);
    try {
      final outcome = await context.read<AuthService>().secureWithGoogle();
      if (mounted) _handleOutcome(outcome);
    } catch (e) {
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _handleEmail() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      final outcome = await context.read<AuthService>().secureWithEmail(
            email: _emailController.text.trim(),
            password: _passwordController.text,
          );
      if (mounted) _handleOutcome(outcome);
    } catch (e) {
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _handleOutcome(SecureAccountOutcome outcome) {
    switch (outcome) {
      case SecureAccountOutcome.cancelled:
        return;
      case SecureAccountOutcome.linked:
        Navigator.pop(context);
        return;
      case SecureAccountOutcome.fellBackToExistingAccount:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ce compte existe déjà, connexion en cours.')),
        );
        Navigator.pop(context);
    }
  }

  void _showError(Object e) {
    final message = e is AuthException ? e.message : 'Une erreur est survenue : $e';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
    );
  }

  @override
  Widget build(BuildContext context) {
    const labelStyle = TextStyle(color: Colors.white70, fontSize: 12);

    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Sécurise ton compte'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Plus tard', style: TextStyle(color: Colors.white38)),
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.verified_user, color: Colors.greenAccent, size: 48),
              const SizedBox(height: 16),
              const Text(
                'Achat confirmé ! Reliez un compte permanent pour ne jamais perdre '
                'votre abonnement si vous changez d\'appareil ou réinstallez l\'app.',
                style: TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                onPressed: _loading ? null : _handleGoogle,
                icon: const Icon(Icons.login),
                label: const Text('Continuer avec Google'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.greenAccent,
                  foregroundColor: Colors.black,
                  minimumSize: const Size(double.infinity, 45),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(height: 16),
              if (!_showEmailForm)
                OutlinedButton(
                  onPressed: _loading ? null : () => setState(() => _showEmailForm = true),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white24),
                    minimumSize: const Size(double.infinity, 45),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Utiliser un email / mot de passe'),
                )
              else
                Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 8),
                      const Text('EMAIL', style: labelStyle),
                      const SizedBox(height: 4),
                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'vous@exemple.com',
                          hintStyle: const TextStyle(color: Colors.white24),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.05),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                        ),
                        validator: (v) => (v == null || !v.contains('@')) ? 'Email invalide' : null,
                      ),
                      const SizedBox(height: 16),
                      const Text('MOT DE PASSE', style: labelStyle),
                      const SizedBox(height: 4),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: true,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: '••••••••',
                          hintStyle: const TextStyle(color: Colors.white24),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.05),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                        ),
                        validator: (v) => (v == null || v.length < 6) ? 'Au moins 6 caractères' : null,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loading ? null : _handleEmail,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white10,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 45),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: _loading
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Text('SÉCURISER MON COMPTE', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
