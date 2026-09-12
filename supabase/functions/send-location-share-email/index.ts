// Diffusion email d'un partage de position (spec-partage-position-live-
// tracking.md §11.1). Contenu minimal : lien vers /track/[token] — MORT
// tant que meshiker-web (github.com/Rosaweb/Meshiker_web) n'existe pas,
// accepté par décision utilisateur (voir plan d'implémentation) : le lien
// s'activera de lui-même le jour où ce site sort, sans retoucher cette
// fonction.
//
// Appelée directement par LocationShareService (Manuel : juste après
// l'insert du ping unique ; Auto : depuis le callback Android/l'appel iOS
// à chaque check-in) — JAMAIS via pg_cron, contrairement à
// send-auto-checkin-push : les deux chemins Auto exécutent déjà du code
// Dart au moment du check-in, pas besoin de la complexité pg_net/clé
// service-role ici (voir plan d'implémentation, écart §7).
//
// verify_jwt reste à sa valeur par défaut (true) dans config.toml : la
// passerelle Supabase exige un JWT valide avant même d'atteindre ce code,
// mais on construit quand même un client sur la clé anonyme + l'en-tête
// Authorization reçu pour que les policies RLS scopent la lecture au
// partage réellement possédé par l'appelant (jamais un id arbitraire).
//
// Déploiement :
//   npx supabase functions deploy send-location-share-email
//   npx supabase secrets set RESEND_API_KEY=<clé API Resend>
//   npx supabase secrets set RESEND_FROM_EMAIL="Meshiker <partage@meshiker.com>"
// PRÉREQUIS HUMAIN : compte Resend + domaine d'envoi vérifié (DNS SPF/
// DKIM) — pas faisable depuis cet environnement de développement.

import { createClient } from 'npm:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')!;
const RESEND_FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL')!;

const TRACK_URL_BASE = 'https://meshiker.com/track';

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'method_not_allowed' }, 405);
  }

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return jsonResponse({ error: 'unauthorized' }, 401);
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();
  if (userError || !user) {
    return jsonResponse({ error: 'unauthorized' }, 401);
  }

  let shareId: unknown;
  try {
    const body = await req.json();
    shareId = body?.share_id;
  } catch {
    return jsonResponse({ error: 'invalid_body' }, 400);
  }
  if (typeof shareId !== 'string' || shareId.length === 0) {
    return jsonResponse({ error: 'invalid_body' }, 400);
  }

  // Client scopé sur le JWT de l'appelant (pas service_role) : la policy
  // "owners manage their location shares" garantit qu'on ne peut déclencher
  // un envoi que pour un partage réellement possédé par l'appelant.
  const { data: share, error: shareError } = await supabase
    .from('location_shares')
    .select('share_token, label')
    .eq('id', shareId)
    .eq('owner_id', user.id)
    .maybeSingle();
  if (shareError) {
    console.error('send-location-share-email: share lookup error', shareError);
    return jsonResponse({ error: 'internal_error' }, 500);
  }
  if (!share) {
    return jsonResponse({ error: 'not_found' }, 404);
  }

  const { data: members, error: membersError } = await supabase
    .from('location_share_members')
    .select('contact')
    .eq('share_id', shareId)
    .eq('channel', 'email');
  if (membersError) {
    console.error('send-location-share-email: members lookup error', membersError);
    return jsonResponse({ error: 'internal_error' }, 500);
  }

  const recipients = (members ?? [])
    .map((m: { contact: string | null }) => m.contact)
    .filter((c): c is string => !!c);
  if (recipients.length === 0) {
    return jsonResponse({ sent: 0 });
  }

  const { data: profile } = await supabase.from('profiles').select('pseudo').eq('id', user.id).maybeSingle();
  const senderPseudo = profile?.pseudo ?? 'Un proche';
  const trackUrl = `${TRACK_URL_BASE}/${share.share_token}`;
  const label = share.label ? ` (${share.label})` : '';

  const emailResponse = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: RESEND_FROM_EMAIL,
      to: recipients,
      subject: `${senderPseudo} partage sa position avec vous${label}`,
      html: `
        <p>${senderPseudo} partage sa position avec vous${label} sur Meshiker.</p>
        <p><a href="${trackUrl}">${trackUrl}</a></p>
      `.trim(),
    }),
  });

  if (!emailResponse.ok) {
    console.error('send-location-share-email: Resend error', emailResponse.status, await emailResponse.text());
    return jsonResponse({ error: 'email_send_failed' }, 502);
  }

  return jsonResponse({ sent: recipients.length });
});
