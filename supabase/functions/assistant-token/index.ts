// Émet un token éphémère Gemini Live pour l'assistant IA conversationnel
// (manuel d'aide, v1 — voir plan-implementation-assistant-ia-v1.md côté
// client). Le flux audio ne transite jamais par cette fonction : son seul
// rôle est de vérifier le statut premium puis de verrouiller et renvoyer un
// token à usage unique, que le client utilise pour ouvrir une connexion
// WebSocket directe avec l'API Gemini (aucune donnée audio ne passe par
// Supabase — cf. spec-assistant-vocal-ia.md section 5, piège à ne pas
// reproduire).
//
// `manuel_utilisateur.md` dans ce dossier est une copie synchronisée
// manuellement de `docs/manuel_utilisateur.md` (source de vérité) : le
// bundler Supabase ne peut inclure que des fichiers déclarés dans
// `static_files` (config.toml) à l'intérieur du dossier de la fonction, pas
// de chemin relatif remontant vers la racine du repo (vérifié empiriquement
// — voir la doc "Add static files to Edge Functions"). Avant de déployer
// cette fonction après une modification du manuel :
//   cp docs/manuel_utilisateur.md supabase/functions/assistant-token/manuel_utilisateur.md
//   npx supabase functions deploy assistant-token

import { createClient } from 'npm:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const GEMINI_API_KEY = Deno.env.get('GEMINI_API_KEY')!;

// Nom de modèle Live à vérifier périodiquement dans la doc Google (évolue
// vite, cf. spec-assistant-vocal-ia.md section 6) : à ce jour (2026-08),
// `gemini-3.1-flash-live-preview` est le modèle audio natif recommandé sur
// la Gemini Developer API standard (pas Vertex — les tokens éphémères n'y
// sont pas supportés, cf. plan-implementation-assistant-vocal-conversationnel.md).
const LIVE_MODEL = 'models/gemini-3.1-flash-live-preview';

// Session ouverte à la demande (une question = une session courte, décision
// actée avec l'utilisateur — voir plan-implementation-assistant-ia-v1.md
// section 3), pas une session longue façon appel : une fenêtre de démarrage
// courte réduit la portée d'un token capturé sans gêner l'usage réel.
const SESSION_START_WINDOW_MS = 3 * 60 * 1000;

const FALLBACK_INSTRUCTION = `
Tu es l'assistant vocal intégré à l'application mobile de randonnée
Meshiker. Tu réponds UNIQUEMENT aux questions sur l'usage de
l'application, à partir du manuel utilisateur ci-dessous. Réponds en
français, en 1 à 3 phrases courtes et naturelles à l'oral (une réponse
vocale trop longue est pénible à écouter en randonnée).

Si une question porte sur autre chose que l'usage de l'application —
par exemple décrire l'itinéraire en cours, donner des instructions de
direction, ou chercher un commerce à proximité — décline poliment en
expliquant que ce n'est pas encore disponible et sera ajouté dans une
prochaine version. N'invente jamais de réponse sur ces sujets.

Ne prétends jamais qu'une fonctionnalité listée dans la section finale
du manuel ("fonctionnalités mentionnées dans l'interface mais pas
encore disponibles") fonctionne.
`.trim();

let cachedManuel: string | null = null;

async function loadManuel(): Promise<string> {
  if (cachedManuel === null) {
    cachedManuel = await Deno.readTextFile('./manuel_utilisateur.md');
  }
  return cachedManuel;
}

function jsonResponse(body: unknown, status: number): Response {
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

  // Pas de restriction sur is_anonymous : un achat premium peut avoir lieu
  // avant conversion de compte (spec-authentification-paywall.md section
  // 3.2) — un utilisateur anonyme premium doit avoir accès à l'assistant.
  const { data: profile, error: profileError } = await supabase
    .from('profiles')
    .select('is_premium')
    .eq('id', user.id)
    .maybeSingle();

  if (profileError) {
    console.error('assistant-token: profile lookup failed', profileError);
    return jsonResponse({ error: 'internal_error' }, 500);
  }
  if (!profile?.is_premium) {
    return jsonResponse({ error: 'premium_required' }, 403);
  }

  const manuel = await loadManuel();
  const systemInstruction = `${FALLBACK_INSTRUCTION}\n\n---\n\n${manuel}`;

  const mintResponse = await fetch('https://generativelanguage.googleapis.com/v1beta/auth_tokens', {
    method: 'POST',
    headers: {
      'x-goog-api-key': GEMINI_API_KEY,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      uses: 1,
      newSessionExpireTime: new Date(Date.now() + SESSION_START_WINDOW_MS).toISOString(),
      // Champ réel de la ressource AuthToken (vérifié empiriquement contre
      // l'API le 2026-08-20 : la doc trouvée en ligne mentionne à tort
      // "liveConnectConstraints" dans certains résumés, l'API renvoie
      // "Unknown name liveConnectConstraints" — le vrai champ est
      // bidiGenerateContentSetup, cf. https://ai.google.dev/api/live).
      bidiGenerateContentSetup: {
        model: LIVE_MODEL,
        generationConfig: {
          responseModalities: ['AUDIO'],
        },
        systemInstruction: { parts: [{ text: systemInstruction }] },
        // Aucun tool en v1 (function calling différé en v2, cf.
        // spec-assistant-vocal-ia.md section 3.4).
        tools: [],
      },
    }),
  });

  if (!mintResponse.ok) {
    const errText = await mintResponse.text();
    console.error('assistant-token: Gemini auth_tokens error', mintResponse.status, errText);
    return jsonResponse({ error: 'token_mint_failed' }, 502);
  }

  const mintBody = await mintResponse.json();
  const token = mintBody?.token?.name ?? mintBody?.name;
  if (!token) {
    console.error('assistant-token: unexpected auth_tokens response shape', JSON.stringify(mintBody));
    return jsonResponse({ error: 'token_mint_failed' }, 502);
  }

  return jsonResponse({ token, model: LIVE_MODEL }, 200);
});
