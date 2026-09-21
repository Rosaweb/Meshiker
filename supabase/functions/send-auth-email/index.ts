// Hook Supabase Auth « Send Email » : remplace l'envoi des emails d'auth par
// Supabase (un seul template, une seule langue) par un envoi via Resend,
// localisé selon la langue de l'utilisateur (voir emails.ts).
//
// Appelée par Supabase Auth (pas par un client) : la passerelle ne peut donc
// pas exiger de JWT (verify_jwt = false dans config.toml) ; l'authenticité de
// l'appel est vérifiée ici avec la signature Standard Webhooks.
//
// Déploiement (voir aussi supabase/config.toml) :
//   npx supabase functions deploy send-auth-email
//   npx supabase secrets set RESEND_API_KEY=<clé Resend autorisée pour le domaine d'envoi>
//   npx supabase secrets set AUTH_FROM_EMAIL="Meshiker <no-reply@mail.meshiker.com>"
//   npx supabase secrets set SEND_EMAIL_HOOK_SECRET="v1,whsec_..."   (fourni par le dashboard)
// Puis dashboard > Authentication > Hooks > Send Email > HTTPS/Edge Function.
//
// ⚠️ Une fois le hook activé, Supabase n'envoie PLUS aucun email d'auth
// lui-même (ni SMTP personnalisé, ni templates du dashboard) : une erreur ici
// bloque inscription, mot de passe oublié et ajout d'email depuis l'app.

import { Webhook } from 'npm:standardwebhooks@1.0.0';

import { emailKindFor, renderEmail, resolveLocale } from './emails.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')!;
const AUTH_FROM_EMAIL = Deno.env.get('AUTH_FROM_EMAIL')!;
const HOOK_SECRET = Deno.env.get('SEND_EMAIL_HOOK_SECRET')!.replace('v1,whsec_', '');

const REPLY_TO = 'contact@meshiker.com';

interface HookPayload {
  user: {
    email?: string | null;
    new_email?: string | null;
    user_metadata?: Record<string, unknown> | null;
  };
  email_data: {
    token: string;
    token_hash: string;
    redirect_to: string;
    email_action_type: string;
    site_url: string;
    token_new?: string;
    token_hash_new?: string;
  };
}

function errorResponse(status: number, message: string) {
  return new Response(JSON.stringify({ error: { http_code: status, message } }), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

/// Lien de l'email. Si l'appelant a demandé un retour vers le site
/// (`redirect_to` = /auth/callback), on pointe directement vers le site avec
/// le jeton : la validation se fait sur la page, ce qui fonctionne même si le
/// lien est ouvert sur un autre appareil. Sinon (ex. ajout d'email depuis
/// l'app, sans redirection propre), on garde le lien de vérification
/// Supabase, comme le template par défaut.
function buildActionUrl(tokenHash: string, actionType: string, redirectTo: string): string {
  const type = actionType === 'signup' || actionType === 'invite' ? 'email' : actionType;

  try {
    const redirect = new URL(redirectTo);
    if (redirect.pathname.endsWith('/auth/callback')) {
      redirect.searchParams.set('token_hash', tokenHash);
      redirect.searchParams.set('type', type);
      return redirect.toString();
    }
  } catch {
    // redirect_to vide ou invalide : lien de vérification Supabase ci-dessous.
  }

  const verify = new URL(`${SUPABASE_URL}/auth/v1/verify`);
  verify.searchParams.set('token', tokenHash);
  verify.searchParams.set('type', actionType);
  if (redirectTo) verify.searchParams.set('redirect_to', redirectTo);
  return verify.toString();
}

async function sendViaResend(to: string, email: { subject: string; html: string; text: string }) {
  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: AUTH_FROM_EMAIL,
      to: [to],
      reply_to: REPLY_TO,
      subject: email.subject,
      html: email.html,
      text: email.text,
    }),
  });

  if (!response.ok) {
    // Le corps de l'erreur Resend ne contient pas de secret ; on ne journalise
    // volontairement ni le destinataire ni les jetons.
    throw new Error(`Resend ${response.status}: ${await response.text()}`);
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(405, 'method_not_allowed');

  const payload = await req.text();
  const headers = Object.fromEntries(req.headers);

  let hook: HookPayload;
  try {
    hook = new Webhook(HOOK_SECRET).verify(payload, headers) as HookPayload;
  } catch {
    return errorResponse(401, 'invalid_signature');
  }

  const { user, email_data: data } = hook;
  const kind = emailKindFor(data.email_action_type);
  if (!kind) {
    console.error('send-auth-email: type non géré:', data.email_action_type);
    return errorResponse(400, `unsupported_email_action_type: ${data.email_action_type}`);
  }

  const locale = resolveLocale(user.user_metadata?.locale, data.redirect_to);

  // Liste (destinataire, email) à envoyer.
  const outgoing: { to: string; email: ReturnType<typeof renderEmail> }[] = [];
  try {
    if (kind === 'email_change') {
      // Noms des jetons inversés pour compatibilité ascendante (doc Supabase) :
      // - changement sécurisé (ancien email présent ET token_hash_new fourni) :
      //   ancien email <- token_new/token_hash_new ; nouvel email <- token/token_hash ;
      // - sinon un seul email, au nouvel email, avec le couple renseigné.
      const newEmail = user.new_email;
      if (!newEmail) throw new Error('new_email manquant pour email_change');

      const secure = !!user.email && !!data.token_hash_new;
      if (secure) {
        outgoing.push({
          to: user.email!,
          email: renderEmail({
            kind,
            locale,
            url: buildActionUrl(data.token_hash_new!, data.email_action_type, data.redirect_to),
          }),
        });
        outgoing.push({
          to: newEmail,
          email: renderEmail({
            kind,
            locale,
            url: buildActionUrl(data.token_hash, data.email_action_type, data.redirect_to),
          }),
        });
      } else {
        const hash = data.token_hash || data.token_hash_new;
        if (!hash) throw new Error('token_hash manquant pour email_change');
        outgoing.push({
          to: newEmail,
          email: renderEmail({
            kind,
            locale,
            url: buildActionUrl(hash, data.email_action_type, data.redirect_to),
          }),
        });
      }
    } else {
      if (!user.email) throw new Error('email manquant');
      outgoing.push({
        to: user.email,
        email:
          kind === 'reauthentication'
            ? renderEmail({ kind, locale, code: data.token })
            : renderEmail({
                kind,
                locale,
                url: buildActionUrl(data.token_hash, data.email_action_type, data.redirect_to),
              }),
      });
    }

    for (const { to, email } of outgoing) {
      await sendViaResend(to, email);
    }
  } catch (e) {
    console.error('send-auth-email: échec', kind, (e as Error).message);
    return errorResponse(500, 'email_send_failed');
  }

  return new Response(JSON.stringify({}), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
});
