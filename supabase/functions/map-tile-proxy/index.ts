// Proxy générique de tuiles raster pour les fonds de carte nationaux dont
// le fournisseur exige une clé API (Suède : Lantmäteriet ; Finlande :
// Maanmittauslaitos / MML). Même principe que `assistant-token` /
// `assistant-places` pour les clés Gemini / Google Places : la clé ne doit
// JAMAIS atteindre le client. Une seule fonction, paramétrée par un
// identifiant de source dans le chemin, plutôt qu'une fonction par pays.
//
// Route (via la passerelle Supabase) :
//   GET /functions/v1/map-tile-proxy/:source/:z/:x/:y[.png]
//     :source  -> `lantmateriet` | `mml`
//     :z/:x/:y -> indices de tuile Web Mercator, TOUJOURS en ordre z/x/y
//                 côté client (comme flutter_map). Le réordonnancement en
//                 z/y/x attendu par les WMTS RESTful est fait ici, côté
//                 serveur (gabarits `UPSTREAMS` ci-dessous).
//
// USGS et Kartverket n'ont PAS besoin de ce proxy (aucune clé) : le client
// les appelle en direct.
//
// verify_jwt = false (voir supabase/config.toml) : un fond de carte doit
// rester affichable même sans session utilisateur (contrainte « zone
// blanche »). Aucune vérification `is_premium` pour l'instant — ces sources
// sont gratuites côté fournisseur (cf. spec §6/§10). Si le produit décide
// plus tard de les réserver au premium : repasser verify_jwt à true et
// résoudre l'utilisateur via le JWT (pattern `assistant-places`).
//
// Déploiement :
//   npx supabase functions deploy map-tile-proxy
//   npx supabase secrets set LANTMATERIET_API_TOKEN=<token opendata.lantmateriet.se>
//   npx supabase secrets set MML_API_KEY=<clé "Oma tili" maanmittauslaitos.fi>

const LANTMATERIET_API_TOKEN = Deno.env.get('LANTMATERIET_API_TOKEN') ?? '';
const MML_API_KEY = Deno.env.get('MML_API_KEY') ?? '';

// Gabarits d'URL amont. `{z}`/`{x}`/`{y}` sont remplacés par position, donc
// l'ordre écrit ici (z/y/x = TileMatrix/TileRow/TileCol, forme RESTful
// standard des WMTS) est celui envoyé au fournisseur, indépendamment de
// l'ordre reçu du client (toujours z/x/y).
//
// ⚠️ À vérifier une fois les comptes validés, via le `GetCapabilities` de
// chaque service (nom exact du TileMatrixSet, plage de zoom, ordre
// row/col). Point unique à corriger si besoin : ces deux chaînes.
const UPSTREAMS: Record<string, (z: string, x: string, y: string) => string> = {
  lantmateriet: (z, x, y) =>
    `https://api.lantmateriet.se/open/topowebb-ccby/v1/wmts/token/${LANTMATERIET_API_TOKEN}` +
    `/1.0.0/topowebb/default/3857/${z}/${y}/${x}.png`,
  mml: (z, x, y) =>
    `https://avoin-karttakuva.maanmittauslaitos.fi/avoin/wmts/1.0.0/maastokartta/default/` +
    `WGS84_Pseudo-Mercator/${z}/${y}/${x}.png?api-key=${MML_API_KEY}`,
};

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
};

function errorResponse(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

// Indices de tuile plausibles : entiers positifs, zoom <= 22. Barrière
// minimale contre l'usage du proxy comme relais HTTP arbitraire (les
// gabarits sont figés, mais autant refuser tôt les entrées absurdes).
function isTileIndex(value: string): boolean {
  return /^\d{1,10}$/.test(value);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== 'GET') {
    return errorResponse(405, 'method_not_allowed');
  }

  // pathname ~= /map-tile-proxy/<source>/<z>/<x>/<y>.png
  const segments = new URL(req.url).pathname
    .split('/')
    .filter((s) => s.length > 0);
  const proxyIdx = segments.indexOf('map-tile-proxy');
  const parts = proxyIdx >= 0 ? segments.slice(proxyIdx + 1) : segments;

  if (parts.length !== 4) {
    return errorResponse(400, 'expected /:source/:z/:x/:y');
  }

  const [source, z, x, yRaw] = parts;
  const y = yRaw.replace(/\.(png|jpg|jpeg|webp)$/i, '');

  const buildUrl = UPSTREAMS[source];
  if (!buildUrl) {
    return errorResponse(404, 'unknown_source');
  }
  if (!isTileIndex(z) || !isTileIndex(x) || !isTileIndex(y)) {
    return errorResponse(400, 'invalid_tile_index');
  }
  if (source === 'lantmateriet' && !LANTMATERIET_API_TOKEN) {
    return errorResponse(503, 'lantmateriet_token_missing');
  }
  if (source === 'mml' && !MML_API_KEY) {
    return errorResponse(503, 'mml_key_missing');
  }

  let upstream: Response;
  try {
    upstream = await fetch(buildUrl(z, x, y), {
      headers: { 'User-Agent': 'Meshiker/1.0 (+https://meshiker.app)' },
    });
  } catch (e) {
    console.error('map-tile-proxy: upstream fetch failed', source, e);
    return errorResponse(502, 'upstream_unreachable');
  }

  if (!upstream.ok) {
    // Ne pas relayer le corps d'erreur du fournisseur (peut contenir le
    // token dans un message). On journalise le statut, on renvoie sec.
    console.error('map-tile-proxy: upstream error', source, upstream.status);
    return errorResponse(upstream.status === 404 ? 404 : 502, 'upstream_error');
  }

  const body = await upstream.arrayBuffer();
  return new Response(body, {
    status: 200,
    headers: {
      ...CORS_HEADERS,
      'Content-Type': upstream.headers.get('Content-Type') ?? 'image/png',
      // Les tuiles nationales bougent rarement ; on laisse le client / le
      // CDN Supabase les garder un moment. Le cache disque applicatif
      // (_CachedTileImageProvider) reste la couche principale côté app.
      'Cache-Control': 'public, max-age=86400',
    },
  });
});
