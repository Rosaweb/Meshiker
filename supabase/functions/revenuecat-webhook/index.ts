// Webhook RevenueCat -> synchronise profiles.is_premium (schema.sql).
//
// Voir spec-authentification-paywall.md section 7. app_user_id est garanti
// être l'UUID Supabase (auth.users.id) grâce à Purchases.logIn() côté
// client (lib/utils/auth_service.dart) — jamais un ID anonyme RevenueCat
// ($RCAnonymousID:...) une fois l'app bootstrappée.
//
// Simplification assumée : on dérive is_premium directement du type
// d'événement plutôt que de rappeler l'API REST RevenueCat pour l'état
// définitif de l'abonnement. Suffisant pour ce chantier, mais moins robuste
// aux cas limites (grace period, relance de facturation) qu'un
// GET /subscribers/{app_user_id} — à envisager si des incohérences
// apparaissent en usage réel.
//
// Déploiement (une fois le projet lié, cf. plan M5) :
//   npx supabase functions deploy revenuecat-webhook
//   npx supabase secrets set REVENUECAT_WEBHOOK_SECRET=<secret choisi>
// Puis configurer l'URL de la fonction + ce même secret (en en-tête
// "Authorization: Bearer <secret>") dans RevenueCat > Project > Integrations
// > Webhooks.

import { createClient } from 'npm:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const WEBHOOK_SECRET = Deno.env.get('REVENUECAT_WEBHOOK_SECRET');

// Événements qui accordent l'entitlement (l'utilisateur redevient/reste
// premium).
const GRANTING_EVENTS = new Set([
  'INITIAL_PURCHASE',
  'RENEWAL',
  'PRODUCT_CHANGE',
  'UNCANCELLATION',
  'NON_RENEWING_PURCHASE',
]);

// Événements qui retirent l'entitlement. `CANCELLATION` et `BILLING_ISSUE`
// sont volontairement exclus : ils signalent un problème à venir, pas une
// perte d'accès immédiate (recommandation RevenueCat) — seul `EXPIRATION`
// confirme que l'entitlement n'est effectivement plus actif.
const REVOKING_EVENTS = new Set(['EXPIRATION']);

interface RevenueCatEvent {
  type: string;
  app_user_id: string;
  transferred_from?: string[];
  transferred_to?: string[];
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }

  if (WEBHOOK_SECRET) {
    const auth = req.headers.get('Authorization');
    if (auth !== `Bearer ${WEBHOOK_SECRET}`) {
      return new Response('Unauthorized', { status: 401 });
    }
  }

  const body = await req.json();
  const event = body.event as RevenueCatEvent | undefined;
  if (!event?.app_user_id || !event.type) {
    return new Response('Malformed payload', { status: 400 });
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  async function setPremium(appUserId: string, isPremium: boolean) {
    // `app_user_id` peut être un ID anonyme RevenueCat orphelin (device
    // jamais rattaché à Supabase, ou webhook rejoué après désinstall) —
    // ce n'est pas une erreur, juste rien à mettre à jour.
    await supabase.from('profiles').update({ is_premium: isPremium }).eq('id', appUserId);
  }

  if (event.type === 'TRANSFER') {
    // Piège documenté (spec section 9) : l'entitlement change de titulaire.
    for (const from of event.transferred_from ?? []) await setPremium(from, false);
    for (const to of event.transferred_to ?? []) await setPremium(to, true);
  } else if (GRANTING_EVENTS.has(event.type)) {
    await setPremium(event.app_user_id, true);
  } else if (REVOKING_EVENTS.has(event.type)) {
    await setPremium(event.app_user_id, false);
  }
  // Autres types (BILLING_ISSUE, CANCELLATION, SUBSCRIPTION_PAUSED,
  // INVOICE_ISSUANCE, TEST...) : accusé de réception sans changement d'état.

  return new Response('ok', { status: 200 });
});
