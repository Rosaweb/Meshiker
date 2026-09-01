// Émet un token éphémère Gemini Live pour l'assistant IA conversationnel
// (manuel d'aide v1 + navigation/function calling v2 — voir
// plan-implementation-assistant-ia.md côté client). Le flux audio ne
// transite jamais par cette fonction : son seul
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
//
// Vérifié empiriquement le 2026-08-29 après un faux suspect : ce nom N'ÉTAIT
// PAS la cause du "Connexion assistant fermée de façon inattendue" remonté
// par l'utilisateur ce jour-là. `gemini-live-2.5-flash-native-audio` (nom
// vu dans AI Studio) a été essayé à sa place et rejeté instantanément par le
// WebSocket réel (code 1008, "is not found ... or is not supported for
// bidiGenerateContent") — ce nom n'existe pas dans `GET /v1beta/models`
// pour ce projet. `gemini-3.1-flash-live-preview`, lui, complète bien le
// handshake `setup`/`setupComplete` en conditions réelles. La vraie cause
// du symptôme original était côté client, voir le try/catch ajouté dans
// `AssistantService._startMicStreaming` (lib/assistant/assistant_service.dart).
const LIVE_MODEL = 'models/gemini-3.1-flash-live-preview';

// Session ouverte à la demande (une question = une session courte, décision
// actée avec l'utilisateur — voir plan-implementation-assistant-ia-v1.md
// section 3), pas une session longue façon appel : une fenêtre de démarrage
// courte réduit la portée d'un token capturé sans gêner l'usage réel.
const SESSION_START_WINDOW_MS = 3 * 60 * 1000;

const FALLBACK_INSTRUCTION = `
Tu es l'assistant vocal intégré à l'application mobile de randonnée
Meshiker. Réponds en français, en 1 à 3 phrases courtes et naturelles à
l'oral (une réponse vocale trop longue est pénible à écouter en
randonnée).

Tu réponds à trois types de questions :
1. Questions sur l'usage de l'application — réponds à partir du manuel
   utilisateur ci-dessous.
2. Questions sur l'itinéraire en cours (description, distance restante,
   prochaine direction) ou sur les commerces à proximité (recherche,
   horaires d'ouverture) — utilise les outils mis à ta disposition
   (decrire_itineraire, obtenir_prochaine_direction,
   rechercher_commerces_proximite, horaires_commerce) plutôt que de
   deviner. N'invente JAMAIS une distance, une direction ou un horaire :
   si un outil renvoie qu'aucun itinéraire n'est chargé, ou qu'aucun
   commerce n'a été trouvé, dis-le simplement.
3. Questions sur le terrain traversé (dénivelé, nature du terrain,
   points d'eau, ce qui se trouve sur le chemin — croisements,
   éléments longés) — utilise l'outil decrire_terrain_itineraire.
   Règles STRICTES pour cet outil (anti-hallucination) :
   - Ne mentionne JAMAIS un élément absent du JSON renvoyé.
   - N'invente JAMAIS d'appréciation qualitative non déductible des
     tags reçus (ex. ne dis pas "vue magnifique" si rien dans les
     données ne l'indique).
   - Les indications gauche/droite viennent STRICTEMENT du champ
     "cote" fourni — ne les recalcule jamais toi-même.
   - Les tags "landcover_tags" (ex. "natural=wood", "landuse=farmland")
     et "type"/"valeur" des points d'intérêt sont des tags OpenStreetMap
     bruts : c'est à toi de les traduire en français naturel (tu connais
     leur sens), l'app ne le fait pas.
   - Pour le champ "preview" (au-delà de detailed_limit_m) : reste sur
     des formulations qualitatives à partir de "tendance"
     (ascension_notable / descente_notable / variee / plat) et
     "elements_notables" (noms bruts). N'invente JAMAIS de distance
     chiffrée ni de valeur de dénivelé pour cette portion — seuls les
     "segments" détaillés en contiennent.
   - Si "itineraire_disponible" est false, dis simplement le message
     renvoyé, n'invente rien d'autre.

Pour toute autre question, hors de ces trois périmètres, décline
poliment en expliquant que ce n'est pas disponible.

Ne prétends jamais qu'une fonctionnalité listée dans la section finale
du manuel ("fonctionnalités mentionnées dans l'interface mais pas
encore disponibles") fonctionne.
`.trim();

// v2 (navigation) : déclarations de fonctions verrouillées côté token
// éphémère, comme le modèle et les system instructions — le client ne
// choisit jamais quels outils sont exposés. Les noms doivent matcher
// EXACTEMENT les constantes `_ToolNames` de
// `lib/assistant/assistant_service.dart` (la Live API identifie l'outil
// appelé par son nom).
const FUNCTION_DECLARATIONS = [
  {
    name: 'decrire_itineraire',
    description:
      "Décrit l'itinéraire actuellement chargé dans le roadmap de l'utilisateur : nom, distance totale, dénivelé, distance déjà parcourue et restante, liste des waypoints. À utiliser dès que l'utilisateur demande de décrire son itinéraire, son parcours, ou où il en est.",
    parameters: { type: 'OBJECT', properties: {} },
  },
  {
    name: 'obtenir_prochaine_direction',
    description:
      "Donne la distance et la direction (point cardinal) vers le prochain waypoint de l'itinéraire en cours, ainsi que vers la destination choisie le cas échéant. À utiliser quand l'utilisateur demande où aller, quelle direction prendre, ou combien de distance il reste avant le prochain point.",
    parameters: { type: 'OBJECT', properties: {} },
  },
  {
    name: 'rechercher_commerces_proximite',
    description:
      "Recherche des commerces ou services à proximité de la position actuelle de l'utilisateur (ex: boulangerie, restaurant, pharmacie, épicerie, refuge). À utiliser quand l'utilisateur cherche un commerce ou un service proche de lui.",
    parameters: {
      type: 'OBJECT',
      properties: {
        type: {
          type: 'STRING',
          description: 'Type de commerce recherché, en français, ex: "boulangerie", "pharmacie de garde".',
        },
        rayon_metres: {
          type: 'INTEGER',
          description: 'Rayon de recherche en mètres. Optionnel, 2000 par défaut.',
        },
      },
      required: ['type'],
    },
  },
  {
    name: 'horaires_commerce',
    description:
      "Donne les horaires d'ouverture détaillés d'un commerce déjà trouvé via rechercher_commerces_proximite, à partir de son place_id.",
    parameters: {
      type: 'OBJECT',
      properties: {
        place_id: {
          type: 'STRING',
          description: "Identifiant Google Places du commerce (champ place_id renvoyé par rechercher_commerces_proximite).",
        },
      },
      required: ['place_id'],
    },
  },
  {
    name: 'decrire_terrain_itineraire',
    description:
      "Décrit le terrain traversé par l'itinéraire chargé dans le roadmap : dénivelé détaillé segment par segment, nature du terrain (tags OpenStreetMap bruts à traduire toi-même), points d'eau, et points d'intérêt le long du chemin (croisements de voie ferrée/route/cours d'eau, éléments longés comme un canal, points ponctuels comme un calvaire) avec leur position gauche/droite quand pertinent. À utiliser quand l'utilisateur demande de décrire le terrain, le dénivelé détaillé, la nature du chemin, s'il y a des points d'eau, ou ce qu'il va croiser/longer en chemin — distinct de decrire_itineraire qui ne donne que des chiffres globaux (distance/dénivelé total), pas la nature du terrain.",
    parameters: {
      type: 'OBJECT',
      properties: {
        distance_debut_m: {
          type: 'NUMBER',
          description:
            "Point de départ de l'analyse, en mètres depuis le début de la trace. Optionnel : par défaut, la position actuelle de l'utilisateur le long de l'itinéraire (fonctionne aussi bien en marchant qu'à l'arrêt le soir pour préparer l'étape du lendemain).",
        },
        distance_max_m: {
          type: 'NUMBER',
          description:
            "Distance de la fenêtre d'analyse en mètres, à partir de distance_debut_m. Optionnel, 45000 (45 km) par défaut. Si l'utilisateur précise une distance prévue (ex. \"je compte faire 30 km demain\"), transmets-la ici pour une réponse quantifiée sur la distance réellement prévue.",
        },
      },
      required: [],
    },
  },
];

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
        // v2 : function calling pour la navigation (lecture d'itinéraire,
        // recherche de commerces) — cf. FUNCTION_DECLARATIONS ci-dessus et
        // plan-implementation-assistant-ia.md section 4.
        tools: [{ functionDeclarations: FUNCTION_DECLARATIONS }],
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
