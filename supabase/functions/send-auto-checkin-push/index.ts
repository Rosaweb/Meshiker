// Réveil des devices iOS en partage Auto par push silencieux
// (content-available: 1) — voir spec-partage-position-live-tracking.md §6
// et le plan d'implémentation, Milestone D. Android n'a besoin d'aucune
// infrastructure serveur (alarme exacte système, voir
// lib/sharing/location_auto_alarm_service.dart) : cette fonction ne
// s'adresse qu'aux membres iOS (push_tokens.platform = 'ios').
//
// Invoquée par un cron Postgres (pg_net) toutes les minutes — voir
// trigger_auto_checkin_push() dans supabase/functions.sql. verify_jwt =
// false dans config.toml (même raison que revenuecat-webhook : le cron
// n'a pas de JWT Supabase, seulement le secret partagé vérifié ici à la
// main) — PAS un accès public ouvert, voir la vérification du header
// Authorization ci-dessous.
//
// Déploiement :
//   npx supabase functions deploy send-auto-checkin-push
//   npx supabase secrets set CRON_SHARED_SECRET=<valeur choisie, identique
//     à celle stockée dans Vault pour trigger_auto_checkin_push>
//   npx supabase secrets set APNS_AUTH_KEY_P8="-----BEGIN PRIVATE KEY-----
//     ...
//     -----END PRIVATE KEY-----"
//   npx supabase secrets set APNS_KEY_ID=<Key ID de la clé .p8, portail Apple Developer>
//   npx supabase secrets set APNS_TEAM_ID=<Team ID Apple Developer>
//   npx supabase secrets set APNS_BUNDLE_ID=<bundle id iOS de l'app, ex. com.rosaweb.meshiker>
//
// PRÉREQUIS HUMAIN (pas faisable depuis cet environnement de
// développement) : créer la clé d'authentification APNs (.p8) dans le
// compte Apple Developer (Certificates, Identifiers & Profiles > Keys),
// avec la capacité "Apple Push Notifications service (APNs)" cochée.

import { createClient } from 'npm:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const CRON_SHARED_SECRET = Deno.env.get('CRON_SHARED_SECRET')!;

const APNS_AUTH_KEY_P8 = Deno.env.get('APNS_AUTH_KEY_P8')!;
const APNS_KEY_ID = Deno.env.get('APNS_KEY_ID')!;
const APNS_TEAM_ID = Deno.env.get('APNS_TEAM_ID')!;
const APNS_BUNDLE_ID = Deno.env.get('APNS_BUNDLE_ID')!;

// Environnement de production APNs par défaut — utiliser
// api.sandbox.push.apple.com pour un build de développement (TestFlight/
// App Store utilise systématiquement l'environnement de production).
const APNS_HOST = 'https://api.push.apple.com';

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

// Le token d'authentification APNs (JWT ES256, distinct par device — c'est
// le MÊME token pour tous les appareils, seul le device token dans l'URL
// change) reste valide jusqu'à 1h côté Apple ; Apple recommande de ne pas
// en générer plus d'un toutes les ~20 minutes. Mis en cache au niveau du
// module : réutilisé tant que la fonction reste "chaude" entre deux
// invocations (comportement standard des Edge Functions Deno Deploy).
let cachedApnsToken: { token: string; issuedAtMs: number } | null = null;

async function importApnsPrivateKey(pem: string): Promise<CryptoKey> {
  const stripped = pem
    .replace('-----BEGIN PRIVATE KEY-----', '')
    .replace('-----END PRIVATE KEY-----', '')
    .replace(/\s+/g, '');
  const raw = Uint8Array.from(atob(stripped), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    'pkcs8',
    raw,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  );
}

function base64Url(bytes: Uint8Array): string {
  let binary = '';
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function getApnsAuthToken(): Promise<string> {
  const now = Date.now();
  if (cachedApnsToken && now - cachedApnsToken.issuedAtMs < 20 * 60 * 1000) {
    return cachedApnsToken.token;
  }

  const header = base64Url(new TextEncoder().encode(JSON.stringify({ alg: 'ES256', kid: APNS_KEY_ID })));
  const payload = base64Url(
    new TextEncoder().encode(JSON.stringify({ iss: APNS_TEAM_ID, iat: Math.floor(now / 1000) })),
  );
  const unsigned = `${header}.${payload}`;

  const key = await importApnsPrivateKey(APNS_AUTH_KEY_P8);
  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    new TextEncoder().encode(unsigned),
  );
  const token = `${unsigned}.${base64Url(new Uint8Array(signature))}`;
  cachedApnsToken = { token, issuedAtMs: now };
  return token;
}

// Push silencieux STRICT : `content-available: 1` uniquement, jamais
// d'alert/badge/sound — l'utilisateur ne doit jamais voir de notification
// visible pour un simple check-in Auto en arrière-plan (spec §6).
async function sendSilentPush(deviceToken: string, authToken: string): Promise<boolean> {
  const response = await fetch(`${APNS_HOST}/3/device/${deviceToken}`, {
    method: 'POST',
    headers: {
      authorization: `bearer ${authToken}`,
      'apns-topic': APNS_BUNDLE_ID,
      'apns-push-type': 'background',
      'apns-priority': '5',
    },
    body: JSON.stringify({ aps: { 'content-available': 1 } }),
  });
  if (!response.ok) {
    console.error('send-auto-checkin-push: APNs error', response.status, await response.text());
  }
  return response.ok;
}

Deno.serve(async (req) => {
  const authHeader = req.headers.get('Authorization');
  if (authHeader !== `Bearer ${CRON_SHARED_SECRET}`) {
    return jsonResponse({ error: 'unauthorized' }, 401);
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // Partages Auto actifs dont l'heure courante (±2 min de tolérance, le
  // cron tourne à la minute) correspond à une entrée de auto_times.
  // `auto_times` est un `time[]` Postgres — comparé côté SQL plutôt que
  // rapatrié en entier ici, via une RPC dédiée pour rester simple côté
  // fonction (voir due_auto_location_shares dans functions.sql).
  const { data: dueShares, error: dueError } = await supabase.rpc('due_auto_location_shares');
  if (dueError) {
    console.error('send-auto-checkin-push: due_auto_location_shares error', dueError);
    return jsonResponse({ error: 'internal_error' }, 500);
  }
  if (!dueShares || dueShares.length === 0) {
    return jsonResponse({ sent: 0 });
  }

  const shareIds: string[] = dueShares.map((s: { share_id: string }) => s.share_id);

  // Admin + membres app acceptés de ces partages, dont on a un token iOS.
  const { data: userIdsRows, error: membersError } = await supabase.rpc('location_share_ios_recipients', {
    p_share_ids: shareIds,
  });
  if (membersError) {
    console.error('send-auto-checkin-push: location_share_ios_recipients error', membersError);
    return jsonResponse({ error: 'internal_error' }, 500);
  }

  const tokens: string[] = (userIdsRows ?? []).map((r: { token: string }) => r.token);
  if (tokens.length === 0) {
    return jsonResponse({ sent: 0 });
  }

  let authToken: string;
  try {
    authToken = await getApnsAuthToken();
  } catch (e) {
    console.error('send-auto-checkin-push: échec signature JWT APNs', e);
    return jsonResponse({ error: 'apns_auth_failed' }, 500);
  }

  let sent = 0;
  for (const token of tokens) {
    const ok = await sendSilentPush(token, authToken);
    if (ok) sent++;
  }

  return jsonResponse({ sent, total: tokens.length });
});
