// Rédemption d'un code promo -> octroi d'un entitlement RevenueCat
// promotionnel (voir spec-codes-promo.md). Le user_id vient TOUJOURS du
// JWT de la requête (jamais d'un paramètre client), sinon n'importe qui
// pourrait cibler le compte de son choix.
//
// verify_jwt reste à sa valeur par défaut (true) dans config.toml : la
// passerelle Supabase rejette déjà les requêtes sans JWT valide avant
// d'atteindre ce code, mais on a quand même besoin de résoudre l'objet
// user via un client construit sur la clé anonyme + l'en-tête
// Authorization reçu (même pattern que assistant-token).
//
// Déploiement :
//   npx supabase functions deploy redeem-promo-code
//   npx supabase secrets set REVENUECAT_SECRET_KEY=<clé secrète RevenueCat>
// (SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY sont déjà
// fournies automatiquement à toute Edge Function par la plateforme.)
//
// PIÈGE RÉSOLU (2026-08-21, vérifié empiriquement contre l'API réelle) : le
// spec d'origine visait l'endpoint v1
// (POST /v1/subscribers/{id}/entitlements/{entitlement}/promotional), qui
// accepte { duration }. Mais les clés secrètes RevenueCat émises
// aujourd'hui sont des clés v2, rejetées sur v1 avec
// `403 { code: 7723, message: "...incompatible with RevenueCat API V1" }`
// même avec les bonnes permissions. Migré vers l'endpoint v2 :
//   POST /v2/projects/{project_id}/customers/{customer_id}/actions/grant_entitlement
// dont le corps attend { entitlement_id, expires_at } — entitlement_id est
// l'ID interne RevenueCat (entlXXXXXXXXXX), PAS le lookup_key ("Meshiker
// Pro") ; expires_at est une date d'expiration ABSOLUE en epoch
// millisecondes, obligatoire et non nullable (pas de duration relative, pas
// de "sans expiration" — un octroi "lifetime" est donc approximé par une
// date très lointaine, voir durationToExpiresAtMs). project_id et
// l'entitlement_id ont été récupérés via GET /v2/projects et
// GET /v2/projects/{project_id}/entitlements avec la clé secrète
// (customer_information:customers:read_write) ; à revérifier si
// l'entitlement RevenueCat est un jour recréé (l'ID changerait).

import { createClient } from 'npm:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const REVENUECAT_SECRET_KEY = Deno.env.get('REVENUECAT_SECRET_KEY')!;

// Projet RevenueCat "Meshiker" (pas un secret, juste un identifiant
// d'infrastructure) et unique entitlement de l'app. Si un second
// entitlement apparaît un jour, remplacer par une vraie table de
// correspondance lookup_key -> id plutôt que ce mapping figé.
const REVENUECAT_PROJECT_ID = 'proja7678114';
const ENTITLEMENT_LOOKUP_TO_ID: Record<string, string> = {
  'Meshiker Pro': 'entl65261a80f9',
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

// Convertit les valeurs de promo_codes.duration (contrainte check du
// schema.sql) en date d'expiration absolue pour l'API v2. "lifetime" n'a
// pas d'équivalent "sans expiration" côté v2 (expires_at est obligatoire et
// non nullable, vérifié empiriquement) : approximé par +100 ans.
function durationToExpiresAtMs(duration: string): number {
  const d = new Date();
  switch (duration) {
    case 'daily':
      d.setUTCDate(d.getUTCDate() + 1);
      break;
    case 'weekly':
      d.setUTCDate(d.getUTCDate() + 7);
      break;
    case 'monthly':
      d.setUTCMonth(d.getUTCMonth() + 1);
      break;
    case 'two_month':
      d.setUTCMonth(d.getUTCMonth() + 2);
      break;
    case 'three_month':
      d.setUTCMonth(d.getUTCMonth() + 3);
      break;
    case 'six_month':
      d.setUTCMonth(d.getUTCMonth() + 6);
      break;
    case 'yearly':
      d.setUTCFullYear(d.getUTCFullYear() + 1);
      break;
    case 'lifetime':
      d.setUTCFullYear(d.getUTCFullYear() + 100);
      break;
    default:
      throw new Error(`unknown promo_codes.duration: ${duration}`);
  }
  return d.getTime();
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return jsonResponse({ success: false, error: 'unauthenticated' }, 401);
  }

  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) {
    return jsonResponse({ success: false, error: 'unauthenticated' }, 401);
  }
  const userId = userData.user.id;

  let code: unknown;
  try {
    const body = await req.json();
    code = body?.code;
  } catch {
    return jsonResponse({ success: false, error: 'invalid_code' }, 400);
  }
  if (typeof code !== 'string' || code.trim().length === 0) {
    return jsonResponse({ success: false, error: 'invalid_code' }, 400);
  }

  const serviceClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const { data: redeemResult, error: rpcError } = await serviceClient.rpc('redeem_promo_code', {
    p_code: code.trim(),
    p_user_id: userId,
  });

  if (rpcError) {
    console.error('redeem_promo_code RPC error:', rpcError);
    return jsonResponse({ success: false, error: 'server_error' }, 500);
  }
  if (!redeemResult?.success) {
    return jsonResponse(redeemResult, 200);
  }

  // Étape Postgres confirmée : on tente maintenant l'octroi RevenueCat. Un
  // échec ICI ne remet pas la transaction Postgres en cause (voir spec
  // section 3.1 point 5) — le code reste consommé, l'erreur est renvoyée
  // explicitement pour ne jamais faire croire à un succès côté client.
  const lookupKey = redeemResult.entitlement_id as string;
  const entitlementId = ENTITLEMENT_LOOKUP_TO_ID[lookupKey];
  if (!entitlementId) {
    console.error('Unknown entitlement lookup_key:', lookupKey);
    return jsonResponse({ success: false, error: 'revenuecat_grant_failed' }, 502);
  }
  const expiresAtMs = durationToExpiresAtMs(redeemResult.duration as string);

  const grantResponse = await fetch(
    `https://api.revenuecat.com/v2/projects/${REVENUECAT_PROJECT_ID}/customers/${encodeURIComponent(userId)}/actions/grant_entitlement`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${REVENUECAT_SECRET_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ entitlement_id: entitlementId, expires_at: expiresAtMs }),
    },
  );

  if (!grantResponse.ok) {
    const errorBody = await grantResponse.text();
    console.error('RevenueCat grant failed:', grantResponse.status, errorBody);
    return jsonResponse({ success: false, error: 'revenuecat_grant_failed' }, 502);
  }

  return jsonResponse({ success: true });
});
