import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/subscription_service.dart';

/// Messages d'erreur affichés pour chaque `error` renvoyé par l'Edge
/// Function `redeem-promo-code` (voir spec-codes-promo.md section 3.3).
const Map<String, String> _kErrorMessages = {
  'invalid_code': "Ce code n'existe pas.",
  'code_inactive': "Ce code n'est plus valide.",
  'code_expired': 'Ce code a expiré.',
  'quota_reached': "Ce code a atteint sa limite d'utilisation.",
  'already_redeemed': 'Vous avez déjà utilisé ce code.',
  'revenuecat_grant_failed': 'Une erreur est survenue, réessayez dans un instant.',
  'unauthenticated': 'Une erreur est survenue, réessayez dans un instant.',
  'server_error': 'Une erreur est survenue, réessayez dans un instant.',
};

const _kDefaultErrorMessage = 'Une erreur est survenue, réessayez dans un instant.';

/// Bottom sheet "J'ai un code" (spec-codes-promo.md section 4.1) : champ de
/// saisie + bouton Valider, appelle `redeem-promo-code` puis rafraîchit
/// immédiatement l'état premium local en cas de succès.
class PromoCodeBottomSheet extends StatefulWidget {
  const PromoCodeBottomSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const PromoCodeBottomSheet(),
    );
  }

  @override
  State<PromoCodeBottomSheet> createState() => _PromoCodeBottomSheetState();
}

enum _RedeemState { idle, loading, success, error }

class _PromoCodeBottomSheetState extends State<PromoCodeBottomSheet> {
  final _controller = TextEditingController();
  _RedeemState _state = _RedeemState.idle;
  String? _errorMessage;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _controller.text.trim();
    if (code.isEmpty) return;

    setState(() {
      _state = _RedeemState.loading;
      _errorMessage = null;
    });

    try {
      final response = await Supabase.instance.client.functions.invoke(
        'redeem-promo-code',
        body: {'code': code},
      );
      final data = response.data;
      final success = data is Map && data['success'] == true;
      if (!success) {
        final errorCode = data is Map ? data['error'] as String? : null;
        setState(() {
          _state = _RedeemState.error;
          _errorMessage = _kErrorMessages[errorCode] ?? _kDefaultErrorMessage;
        });
        return;
      }

      if (!mounted) return;
      await context.read<SubscriptionService>().refreshAfterPromoCodeRedeem();

      setState(() => _state = _RedeemState.success);
      await Future.delayed(const Duration(milliseconds: 900));
      if (mounted) Navigator.of(context).pop();
    } on FunctionException catch (e) {
      final details = e.details;
      final errorCode = details is Map ? details['error'] as String? : null;
      setState(() {
        _state = _RedeemState.error;
        _errorMessage = _kErrorMessages[errorCode] ?? _kDefaultErrorMessage;
      });
    } catch (_) {
      setState(() {
        _state = _RedeemState.error;
        _errorMessage = _kDefaultErrorMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loading = _state == _RedeemState.loading;
    final success = _state == _RedeemState.success;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "J'ai un code",
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            "Un code cadeau ou promotionnel vous donne accès à Premium.",
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 16),
          if (success)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.greenAccent),
                  SizedBox(width: 8),
                  Text('Premium activé !', style: TextStyle(color: Colors.white)),
                ],
              ),
            )
          else ...[
            TextField(
              controller: _controller,
              enabled: !loading,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Code',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                errorText: _errorMessage,
                errorStyle: const TextStyle(color: Colors.orangeAccent),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: loading ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.greenAccent,
                foregroundColor: Colors.black,
                minimumSize: const Size(double.infinity, 45),
              ),
              child: loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                    )
                  : const Text('Valider'),
            ),
          ],
        ],
      ),
    );
  }
}
