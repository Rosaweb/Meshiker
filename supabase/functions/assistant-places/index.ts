// Proxy Google Places API (New) pour les outils de function calling de
// l'assistant IA de navigation (v2 — cf. lib/assistant/places_service.dart
// et plan-implementation-assistant-ia.md section 4). Même principe que
// `assistant-token` pour la clé Gemini : la clé Google Places ne doit
// jamais atteindre le client, et l'accès est gated premium ici, avant tout
// appel facturé à Google.
//
// Deux actions, données par le champ `action` du corps de la requête :
// - "search" : recherche textuelle de commerces à proximité d'un point
//   (Text Search (New), plus tolérant au langage naturel français que la
//   liste de types anglais de Nearby Search).
// - "hours"  : horaires d'ouverture détaillés d'un commerce déjà trouvé,
//   identifié par son `placeId`.

import { createClient } from 'npm:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const GOOGLE_PLACES_API_KEY = Deno.env.get('GOOGLE_PLACES_API_KEY')!;

const SEARCH_FIELD_MASK =
  'places.id,places.displayName,places.formattedAddress,places.location,places.currentOpeningHours.openNow,places.rating';
const DETAILS_FIELD_MASK = 'id,displayName,formattedAddress,currentOpeningHours,regularOpeningHours';

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

// Haversine — même formule que `GeoUtils.haversineMeters` côté Dart, pour
// annoncer une distance à l'utilisateur plutôt que des coordonnées brutes.
function haversineMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const R = 6371000;
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

// Rectangle approximatif (pas de conversion UTM ici, à la différence de
// `GeoUtils` côté Dart — une approximation plane suffit pour un rayon de
// quelques km) autour du point utilisateur, pour `locationRestriction`.
function boundingRectangle(latitude: number, longitude: number, radiusMeters: number) {
  const metersPerDegreeLat = 111320;
  const deltaLat = radiusMeters / metersPerDegreeLat;
  const deltaLon = radiusMeters / (metersPerDegreeLat * Math.cos((latitude * Math.PI) / 180));
  return {
    low: { latitude: latitude - deltaLat, longitude: longitude - deltaLon },
    high: { latitude: latitude + deltaLat, longitude: longitude + deltaLon },
  };
}

async function searchNearby(query: string, latitude: number, longitude: number, radiusMeters: number) {
  const response = await fetch('https://places.googleapis.com/v1/places:searchText', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': GOOGLE_PLACES_API_KEY,
      'X-Goog-FieldMask': SEARCH_FIELD_MASK,
    },
    body: JSON.stringify({
      textQuery: query,
      languageCode: 'fr',
      maxResultCount: 5,
      // `locationRestriction` (rectangle uniquement) exclut vraiment tout
      // résultat hors zone, contrairement à `locationBias` (essayé
      // d'abord) qui n'est qu'une préférence de classement : en zone
      // rurale/randonnée avec peu de commerces à proximité, Google Places
      // comblait le vide avec des résultats réels mais éloignés (parfois
      // dans un tout autre pays) plutôt que de renvoyer une liste vide —
      // repéré en test réel le 2026-08-30 (commerces français renvoyés
      // pour une recherche en Allemagne). Un résultat vide est le
      // comportement correct ici : mieux vaut que l'assistant dise
      // "rien trouvé à proximité" que d'inventer un commerce inexistant
      // dans le coin.
      locationRestriction: {
        rectangle: boundingRectangle(latitude, longitude, radiusMeters),
      },
    }),
  });

  if (!response.ok) {
    console.error('assistant-places: searchText failed', response.status, await response.text());
    return jsonResponse({ erreur: 'recherche_google_echouee' }, 200);
  }

  const body = await response.json();
  const places = (body.places ?? []).map((p: Record<string, unknown>) => {
    const location = p.location as { latitude?: number; longitude?: number } | undefined;
    const placeLat = location?.latitude;
    const placeLon = location?.longitude;
    const distance =
      placeLat != null && placeLon != null
        ? Math.round(haversineMeters(latitude, longitude, placeLat, placeLon))
        : null;
    return {
      place_id: p.id,
      nom: (p.displayName as { text?: string } | undefined)?.text ?? null,
      adresse: p.formattedAddress ?? null,
      distance_m: distance,
      ouvert_maintenant: (p.currentOpeningHours as { openNow?: boolean } | undefined)?.openNow ?? null,
      note: p.rating ?? null,
    };
  });

  return jsonResponse({ resultats: places }, 200);
}

async function placeHours(placeId: string) {
  const response = await fetch(
    `https://places.googleapis.com/v1/places/${encodeURIComponent(placeId)}`,
    {
      headers: {
        'X-Goog-Api-Key': GOOGLE_PLACES_API_KEY,
        'X-Goog-FieldMask': DETAILS_FIELD_MASK,
      },
    },
  );

  if (!response.ok) {
    console.error('assistant-places: place details failed', response.status, await response.text());
    return jsonResponse({ erreur: 'horaires_google_echoues' }, 200);
  }

  const body = await response.json();
  const hours = body.currentOpeningHours ?? body.regularOpeningHours;
  return jsonResponse(
    {
      nom: (body.displayName as { text?: string } | undefined)?.text ?? null,
      adresse: body.formattedAddress ?? null,
      ouvert_maintenant: hours?.openNow ?? null,
      description_horaires: hours?.weekdayDescriptions ?? null,
    },
    200,
  );
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

  const { data: profile, error: profileError } = await supabase
    .from('profiles')
    .select('is_premium')
    .eq('id', user.id)
    .maybeSingle();

  if (profileError) {
    console.error('assistant-places: profile lookup failed', profileError);
    return jsonResponse({ error: 'internal_error' }, 500);
  }
  if (!profile?.is_premium) {
    return jsonResponse({ error: 'premium_required' }, 403);
  }

  const payload = await req.json();
  const action = payload?.action;

  if (action === 'search') {
    const { query, latitude, longitude, radiusMeters } = payload;
    if (typeof query !== 'string' || typeof latitude !== 'number' || typeof longitude !== 'number') {
      return jsonResponse({ error: 'invalid_params' }, 400);
    }
    return searchNearby(query, latitude, longitude, typeof radiusMeters === 'number' ? radiusMeters : 2000);
  }

  if (action === 'hours') {
    const { placeId } = payload;
    if (typeof placeId !== 'string' || placeId.trim().length === 0) {
      return jsonResponse({ error: 'invalid_params' }, 400);
    }
    return placeHours(placeId);
  }

  return jsonResponse({ error: 'unknown_action' }, 400);
});
