import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../../utils/auth_service.dart';

/// "Déjà un compte ? Se connecter" (spec section 6.2/6.3) — remplace
/// toujours la session anonyme active, jamais de tentative de liaison.
/// C'est le chemin principal pour un compte déjà créé sur meshhiker.com.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submitPassword() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await context.read<AuthService>().signInWithPassword(
            email: _emailController.text.trim(),
            password: _passwordController.text,
          );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submitGoogle() async {
    setState(() => _loading = true);
    try {
      final signedIn = await context.read<AuthService>().signInWithGoogle();
      if (signedIn && mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _loading = false);
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
          title: const Text('Se connecter'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Retrouvez votre compte, y compris celui créé sur meshhiker.com.',
                  style: TextStyle(color: Colors.white60),
                ),
                const SizedBox(height: 24),
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
                  validator: (v) => (v == null || v.isEmpty) ? 'Requis' : null,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _loading ? null : _submitPassword,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.greenAccent,
                    foregroundColor: Colors.black,
                    minimumSize: const Size(double.infinity, 45),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: _loading
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                      : const Text('SE CONNECTER', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    const Expanded(child: Divider(color: Colors.white12)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text('OU', style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 11)),
                    ),
                    const Expanded(child: Divider(color: Colors.white12)),
                  ],
                ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: _loading ? null : _submitGoogle,
                  icon: const Icon(Icons.login),
                  label: const Text('Continuer avec Google'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white24),
                    minimumSize: const Size(double.infinity, 45),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
