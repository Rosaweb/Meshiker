-- ============================================================
-- Schéma Supabase (PostgreSQL + PostGIS) — "Toile d'araignée"
-- ------------------------------------------------------------
-- Étape 1 : tables, contraintes et index.
-- Étape 4 (voir functions.sql) : la logique de fusion par buffer
-- spatial, le recalcul de l'indice de fiabilité, et les fonctions
-- de lecture par viewport sont dans un fichier séparé afin de
-- garder ce fichier-ci purement déclaratif (DDL).
-- ============================================================

create extension if not exists postgis;
create extension if not exists "uuid-ossp";

-- ---------- Profils utilisateurs ----------
-- S'appuie sur auth.users (Supabase Auth) ; cette table ne stocke
-- que les données de profil propres à l'app. Correspond à
-- lib/models/utilisateur.dart.
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  local_uuid uuid unique, -- Utilisateur.localUuid avant liaison au compte
  pseudo text not null,
  avatar_url text,
  total_distance_meters bigint not null default 0,
  total_segments_contributed integer not null default 0,
  trust_level double precision not null default 0.5,
  -- Statut premium RevenueCat, synchronisé par le webhook Edge Function
  -- `revenuecat-webhook` (voir functions.sql) sur app_user_id = profiles.id
  -- (garanti être cet UUID Supabase grâce à Purchases.logIn() côté client,
  -- cf. spec-authentification-paywall.md). Un utilisateur anonyme peut
  -- légitimement être premium (achat avant conversion de compte) : ne pas
  -- confondre avec la distinction is_anonymous du JWT, qui gate uniquement
  -- les fonctionnalités sociales (voir create_trace_share dans functions.sql).
  is_premium boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------- Segments ----------
-- Un segment est un tronçon unique et partagé : la géométrie est la
-- source de vérité pour la fusion (ST_DWithin sur un buffer de 5-10 m).
-- Correspond à lib/models/segment.dart.
create table if not exists public.segments (
  id uuid primary key default uuid_generate_v4(),
  local_uuid uuid, -- premier UUID client à avoir créé ce segment (traçabilité)
  author_id uuid references public.profiles (id),
  -- LineStringZ (et non un simple LineString) pour conserver l'altitude
  -- de chaque point — utile pour reconstruire un profil altimétrique
  -- côté client sans dépendre des points bruts d'un import ultérieur.
  geom geometry(LineStringZ, 4326) not null,
  mode text not null check (mode in ('routed', 'offPath')),
  distance_meters double precision not null default 0,
  elevation_gain_meters double precision not null default 0,
  elevation_loss_meters double precision not null default 0,
  difficulty text not null default 'moderate'
    check (difficulty in ('easy', 'moderate', 'difficult', 'veryDifficult', 'expert')),
  reliability_index double precision not null default 0,
  passage_count integer not null default 1,
  last_passage_at timestamptz,
  -- Redirection vers un autre segment si celui-ci a été fusionné a
  -- posteriori avec un segment équivalent découvert plus tard (ex : un
  -- job de consolidation périodique, non implémenté à ce stade — voir
  -- README, étape 4). Les clients qui connaissent déjà ce segment
  -- doivent suivre cette redirection lors du pull d'agrégats.
  merged_into uuid references public.segments (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Index spatial GIST : cœur de la fusion de segments proches et des
-- requêtes "segments visibles dans ce viewport".
create index if not exists segments_geom_gix
  on public.segments using gist (geom);

-- Index partiel : n'indexe que les segments encore "vivants", pour que
-- les requêtes de lecture (qui filtrent systématiquement
-- merged_into is null) restent rapides même si le nombre de segments
-- fusionnés grossit avec le temps.
create index if not exists segments_merged_into_idx
  on public.segments (merged_into) where merged_into is not null;

-- ---------- Passages ----------
-- Une ligne par passage d'un utilisateur sur un segment. Alimente le
-- recalcul de reliability_index / passage_count / last_passage_at,
-- via un trigger ou un job planifié à définir à l'étape "synchronisation".
create table if not exists public.segment_passages (
  id uuid primary key default uuid_generate_v4(),
  segment_id uuid not null references public.segments (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  trace_id uuid, -- renseigné une fois la trace correspondante créée
  passed_at timestamptz not null default now(),
  traveled_forward boolean not null default true
);

create index if not exists segment_passages_segment_idx
  on public.segment_passages (segment_id);

-- ---------- Points d'intérêt ----------
-- Correspond à lib/models/point_of_interest.dart. Alimentée par les
-- waypoints (<wpt>) des GPX importés (voir SegmentationEngine côté app)
-- ou par un ajout manuel.
create table if not exists public.points_of_interest (
  id uuid primary key default uuid_generate_v4(),
  local_uuid uuid,
  author_id uuid references public.profiles (id),
  name text not null,
  description text,
  type text not null default 'other'
    check (type in (
      'summit', 'viewpoint', 'waterSource', 'campsite',
      'shelter', 'parking', 'junction', 'danger', 'other'
    )),
  geom geometry(PointZ, 4326) not null,
  times_referenced integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists points_of_interest_geom_gix
  on public.points_of_interest using gist (geom);

alter table public.points_of_interest enable row level security;

create policy "points of interest are publicly readable"
  on public.points_of_interest for select
  using (true);

create policy "authenticated users can insert points of interest"
  on public.points_of_interest for insert
  to authenticated
  with check (true);

-- ---------- Traces ----------
-- Correspond à lib/models/trace.dart.
create table if not exists public.traces (
  id uuid primary key default uuid_generate_v4(),
  local_uuid uuid,
  owner_id uuid not null references public.profiles (id) on delete cascade,
  name text not null,
  description text,
  total_distance_meters double precision not null default 0,
  total_elevation_gain_meters double precision not null default 0,
  total_elevation_loss_meters double precision not null default 0,
  activity_type text not null default 'hiking',
  visibility text not null default 'private'
    check (visibility in ('private', 'friendsOnly', 'public')),
  started_at timestamptz not null,
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Table de jointure ORDONNÉE : correspond exactement à
-- Trace.segments (List<TraceSegmentEntry>) côté Dart.
create table if not exists public.trace_segments (
  trace_id uuid not null references public.traces (id) on delete cascade,
  segment_id uuid not null references public.segments (id) on delete restrict,
  order_index integer not null,
  traveled_forward boolean not null default true,
  primary key (trace_id, order_index)
);

create index if not exists trace_segments_segment_idx
  on public.trace_segments (segment_id);

-- ---------- Row Level Security (base à affiner à l'étape sync) ----------
alter table public.profiles enable row level security;
alter table public.traces enable row level security;
alter table public.segments enable row level security;
alter table public.segment_passages enable row level security;

-- Les segments sont un bien commun : lecture publique, écriture par
-- utilisateurs authentifiés uniquement. Ces policies d'insertion directe
-- restent en place par sécurité/flexibilité, mais le chemin d'écriture
-- RÉEL passe par les fonctions SECURITY DEFINER de functions.sql
-- (upsert_segments_batch, upsert_pois_batch), qui contournent RLS pour
-- pouvoir lire/fusionner les segments d'autres utilisateurs — c'est
-- pourquoi leur logique interne doit rester strictement contrôlée (voir
-- le commentaire de sécurité en tête de functions.sql).
create policy "segments are publicly readable"
  on public.segments for select
  using (true);

create policy "authenticated users can insert segments"
  on public.segments for insert
  to authenticated
  with check (true);

create policy "owners manage their traces"
  on public.traces for all
  using (auth.uid() = owner_id)
  with check (auth.uid() = owner_id);

create policy "public traces are readable by anyone"
  on public.traces for select
  using (visibility = 'public' or auth.uid() = owner_id);

create policy "users manage their own profile"
  on public.profiles for update
  using (auth.uid() = id);

create policy "profiles are publicly readable"
  on public.profiles for select
  using (true);

-- ============================================================
-- Partage de trace GPX par QR code (volet génération uniquement,
-- voir spec-live-tracking-partage-gpx.md section 3). Le scan/
-- réception et la config App Links sont un chantier séparé.
-- ============================================================

create extension if not exists pgcrypto; -- gen_random_bytes() pour le token de partage

-- Pas de FK vers public.traces : une trace n'a pas besoin d'être déjà
-- synchronisée pour être partageable (SyncEngine n'est pas branché
-- côté app à ce stade) — trace_local_uuid n'est conservé qu'à titre
-- indicatif/débogage, jamais utilisé pour contrôler l'accès.
create table if not exists public.trace_shares (
  id uuid primary key default uuid_generate_v4(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  trace_local_uuid uuid not null,
  trace_name text not null,
  -- Généré côté serveur (jamais côté client) dans create_trace_share.
  -- Sert AUSSI de nom d'objet dans le bucket Storage "trace-shares"
  -- (chemin `{token}.gpx`) : connaître le token exact équivaut à
  -- posséder le fichier — même modèle de menace que share_token pour
  -- tracking_sessions (brief section 6).
  token text not null unique,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '30 days'),
  revoked_at timestamptz
);

create index if not exists trace_shares_owner_idx on public.trace_shares (owner_id);

alter table public.trace_shares enable row level security;

-- Le propriétaire gère (crée/consulte/révoque) ses propres partages.
-- Pas de policy `to anon` : l'accès public au CONTENU passe par l'URL
-- publique du bucket Storage (device qui a le token), pas par une
-- requête sur cette table — voir functions.sql.
create policy "owners manage their trace shares"
  on public.trace_shares for all
  using (auth.uid() = owner_id)
  with check (auth.uid() = owner_id);

-- Bucket public en LECTURE via URL directe uniquement (comportement
-- natif Supabase pour bucket.public = true) ; la LISTE reste bloquée
-- faute de policy SELECT sur storage.objects ci-dessous, donc aucune
-- énumération possible sans connaître un token exact.
insert into storage.buckets (id, name, public)
values ('trace-shares', 'trace-shares', true)
on conflict (id) do nothing;

-- Seule policy sur storage.objects pour ce bucket : INSERT, restreint
-- à un token déjà réservé par create_trace_share() pour CET
-- utilisateur. Pas de policy UPDATE/DELETE/SELECT — la révocation ne
-- passe QUE par purge_expired_trace_shares() (SECURITY DEFINER, voir
-- functions.sql).
create policy "trace share owners can upload their gpx object"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'trace-shares'
    and exists (
      select 1 from public.trace_shares ts
      where ts.token || '.gpx' = storage.objects.name
        and ts.owner_id = auth.uid()
    )
  );

-- ============================================================
-- Codes promo / octroi premium (voir spec-codes-promo.md et
-- functions.sql pour redeem_promo_code). Système à part du paywall
-- store : octroie un accès gratuit via les promotional entitlements
-- RevenueCat, jamais une remise sur achat.
-- ============================================================

create table if not exists public.promo_codes (
  id uuid primary key default uuid_generate_v4(),
  code text not null unique,
  -- Doit correspondre exactement à l'identifiant d'entitlement vérifié
  -- côté client (SubscriptionService._updateFromCustomerInfo,
  -- entitlements.active.containsKey('Meshiker Pro')) — PAS "premium".
  -- Un mauvais identifiant ici octroierait un entitlement RevenueCat que
  -- l'app ne regarde jamais : redemption "réussie" en base, mais aucun
  -- accès premium réel côté utilisateur.
  entitlement_id text not null default 'Meshiker Pro',
  duration text not null check (duration in (
    'daily', 'weekly', 'monthly', 'two_month', 'three_month',
    'six_month', 'yearly', 'lifetime'
  )),
  max_redemptions integer,          -- null = illimité
  redemptions_count integer not null default 0,
  expires_at timestamptz,           -- null = pas de limite de temps
  is_active boolean not null default true,
  campaign_name text,               -- ex. "cadeau Marc", "lancement V2"
  created_at timestamptz not null default now(),
  created_by uuid references auth.users (id)
);

create index if not exists idx_promo_codes_code on public.promo_codes (code) where is_active;

create table if not exists public.promo_code_redemptions (
  id uuid primary key default uuid_generate_v4(),
  code_id uuid not null references public.promo_codes (id),
  user_id uuid not null references auth.users (id),
  redeemed_at timestamptz not null default now(),
  unique (code_id, user_id) -- empêche la réutilisation du même code par le même user
);

alter table public.promo_codes enable row level security;
alter table public.promo_code_redemptions enable row level security;

-- Volontairement aucune policy pour anon/authenticated : ces deux tables
-- ne sont lues/écrites que depuis l'Edge Function redeem-promo-code (clé
-- service_role, via la RPC security definer redeem_promo_code), jamais
-- directement par le client.

-- ============================================================
-- Partage de position & Live tracking (voir spec-partage-position-
-- live-tracking.md, doc de référence complet, et functions.sql pour
-- create_location_share/join_location_share/archive_group_location_history/
-- purge_expired_location_shares). Fonctionnalité intégralement premium —
-- vérification serveur systématique dans create_location_share, jamais une
-- simple vérification côté client (même pattern qu'assistant-token).
-- ============================================================

create table if not exists public.location_shares (
  id uuid primary key default uuid_generate_v4(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  label text, -- nom libre donné par l'administrateur ("Battue du 12 septembre")

  mode text not null check (mode in ('manual', 'auto', 'live')),
  -- Sous-ensemble de {'web','email','sms','app'} — 'email' absent si mode='live'.
  channels text[] not null default '{}',

  reciprocity text not null default 'unilateral'
    check (reciprocity in ('unilateral', 'bilateral', 'multilateral')),
  -- Toujours 'unilateral' si mode='manual' (imposé par create_location_share,
  -- non exposé dans l'UI pour ce mode).

  -- Live uniquement.
  live_interval_seconds integer check (live_interval_seconds between 5 and 7200),
  -- Auto uniquement : 1 à 3 heures de check-in dans la journée.
  auto_times time[] check (auto_times is null or array_length(auto_times, 1) between 1 and 3),

  -- Historique : affichage local + proposition de sauvegarde en fin de
  -- session, jamais une trace créée automatiquement (voir spec §8).
  history_enabled boolean not null default false,
  -- Réservé à l'administrateur d'un partage App-to-app à 3+ participants :
  -- demande de conservation d'historique pour tout le groupe, effective
  -- membre par membre selon leur consentement (location_share_members.history_consent).
  history_global boolean not null default false,

  -- 'accounts_only' et password_hash/web_access restent inertes tant que
  -- meshiker-web (seul consommateur de l'accès web) n'existe pas — voir le
  -- plan d'implémentation, écart §5 : la policy select de location_pings
  -- ci-dessous n'a volontairement pas de branche anon/JWT pour ce chantier.
  web_access text not null default 'public'
    check (web_access in ('public', 'password', 'accounts_only')),
  password_hash text, -- rempli seulement si web_access = 'password' (pgcrypto crypt())
  share_token text not null unique default encode(gen_random_bytes(16), 'hex'),

  is_active boolean not null default true,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  -- Valeur réelle toujours fixée explicitement par create_location_share
  -- selon le mode (Live=12h, Auto=72h, Manuel=1h) — ce défaut colonne ne
  -- sert que de filet de sécurité si une ligne était insérée hors RPC.
  expires_at timestamptz not null default (now() + interval '12 hours'),

  created_at timestamptz not null default now()
);

create table if not exists public.location_share_members (
  id uuid primary key default uuid_generate_v4(),
  share_id uuid not null references public.location_shares (id) on delete cascade,

  -- Rempli uniquement pour channel in ('app', 'accounts_only') — un compte
  -- Meshiker identifiable. Reste NULL pour 'email'/'sms', qui ne référencent
  -- qu'un moyen de contact, pas un compte.
  user_id uuid references public.profiles (id),
  channel text not null check (channel in ('app', 'accounts_only', 'email', 'sms')),
  contact text, -- adresse email ou numéro E.164, si channel in ('email', 'sms')

  -- Un membre 'app' doit accepter explicitement l'invitation avant que son
  -- appareil ne commence à émettre sa position — jamais de déclenchement
  -- distant du GPS d'un tiers sans son accord.
  invite_status text not null default 'pending'
    check (invite_status in ('pending', 'accepted', 'declined')),
  invite_responded_at timestamptz,

  -- Distinct du consentement de partage ci-dessus : ne s'applique que si
  -- location_shares.history_global = true. Jamais déduit de invite_status
  -- (deux consentements séparés, voir spec §2/§8.3/§15).
  history_consent boolean not null default false,
  history_consent_at timestamptz,

  created_at timestamptz not null default now()
);

create table if not exists public.location_pings (
  id bigint generated always as identity primary key,
  share_id uuid not null references public.location_shares (id) on delete cascade,
  -- Auteur du point : l'administrateur, ou un membre en réciprocité
  -- bilatérale/multilatérale. Toujours renseigné, y compris pour
  -- l'administrateur lui-même (pas de ligne "virtuelle").
  user_id uuid not null references public.profiles (id),
  lat double precision not null,
  lng double precision not null,
  altitude double precision,
  speed double precision,
  accuracy double precision,
  recorded_at timestamptz not null default now()
);

create index if not exists location_pings_share_recorded_idx
  on public.location_pings (share_id, recorded_at desc);

-- Nécessaire pour que postgres_changes pousse les événements INSERT aux
-- clients abonnés (écran "Partage actif", marqueurs des participants).
-- Première utilisation de Supabase Realtime dans ce repo — à tester
-- explicitement (voir plan d'implémentation, section Vérification), ne
-- pas supposer que ça fonctionne par analogie avec trace_shares.
alter publication supabase_realtime add table public.location_pings;

-- Centralise la logique de réciprocité (qui voit quels points) dans une
-- fonction security definer plutôt que dupliquée dans chaque policy.
create or replace function public.is_accepted_app_member(p_share_id uuid, p_user_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.location_share_members m
    where m.share_id = p_share_id
      and m.user_id = p_user_id
      and m.channel in ('app', 'accounts_only')
      and m.invite_status = 'accepted'
  );
$$;

alter table public.location_shares enable row level security;
alter table public.location_share_members enable row level security;
alter table public.location_pings enable row level security;

create policy "owners manage their location shares"
  on public.location_shares for all
  using (auth.uid() = owner_id)
  with check (auth.uid() = owner_id);

-- Nécessaire pour que l'écran d'invitation / l'écran "Partage actif" d'un
-- membre (pas seulement l'administrateur) puisse lire le libellé et les
-- réglages du partage auquel il appartient.
create policy "members can view shares they belong to"
  on public.location_shares for select
  using (
    exists (
      select 1 from public.location_share_members m
      where m.share_id = location_shares.id and m.user_id = auth.uid()
    )
  );

create policy "owners manage all members of their shares"
  on public.location_share_members for all
  using (exists (select 1 from public.location_shares s
                 where s.id = location_share_members.share_id and s.owner_id = auth.uid()))
  with check (exists (select 1 from public.location_shares s
                       where s.id = location_share_members.share_id and s.owner_id = auth.uid()));

create policy "members read their own membership row"
  on public.location_share_members for select
  using (user_id = auth.uid());

-- Un membre répond à sa propre invitation (invite_status, via
-- respond_location_share_invite) et à son propre consentement d'historique
-- (history_consent, via set_history_consent) — les deux passent par cette
-- même policy update, mais restent deux actions distinctes côté RPC/UI.
create policy "members respond to their own invite and history consent"
  on public.location_share_members for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy "members insert their own pings"
  on public.location_pings for insert
  to authenticated
  with check (
    location_pings.user_id = auth.uid()
    and exists (
      select 1 from public.location_shares s
      where s.id = location_pings.share_id
        and s.is_active
        and (s.owner_id = auth.uid() or public.is_accepted_app_member(s.id, auth.uid()))
    )
  );

-- Modèle de réciprocité — voir spec-partage-position-live-tracking.md §5.1.
-- Volontairement SANS la branche anon/JWT `share_id` du document d'origine :
-- elle dépend de verify-share-password (Edge Function), qui n'a de sens
-- qu'une fois meshiker-web construit (hors périmètre de ce chantier).
create policy "voir les points selon le modèle de réciprocité"
  on public.location_pings for select
  to authenticated
  using (
    exists (
      select 1 from public.location_shares s
      where s.id = location_pings.share_id
        and s.is_active and s.expires_at > now()
        and (
          -- L'auteur voit toujours ses propres points ; l'administrateur
          -- voit toujours tout, quel que soit le modèle de réciprocité.
          location_pings.user_id = auth.uid() or s.owner_id = auth.uid()
          -- Unilatéral : seuls les points de l'administrateur sont
          -- visibles aux autres membres.
          or (s.reciprocity = 'unilateral' and location_pings.user_id = s.owner_id
              and public.is_accepted_app_member(s.id, auth.uid()))
          -- Bilatéral / Multilatéral : tout membre accepté voit tous les points.
          or (s.reciprocity in ('bilateral', 'multilateral')
              and public.is_accepted_app_member(s.id, auth.uid()))
        )
    )
  );

-- ------------------------------------------------------------
-- Archive serveur de l'historique de groupe. Décision produit (voir plan
-- d'implémentation) : en plus de la sauvegarde locale individuelle de
-- chaque participant (spec §8.1/§8.2, jamais synchronisée), l'administrateur
-- d'un partage à historique global peut déclencher une archive serveur
-- PERMANENTE de l'intégralité du groupe, pour une future consultation via
-- meshiker-web (pas construite dans ce chantier — écriture seule côté
-- mobile). Calquée sur le précédent promo_codes : RLS activée, AUCUNE
-- policy d'écriture — seule la RPC security definer
-- archive_group_location_history() (functions.sql) y écrit.
-- ------------------------------------------------------------
create table if not exists public.location_share_archives (
  id bigint generated always as identity primary key,
  share_id uuid references public.location_shares (id) on delete set null,
  owner_id uuid not null references public.profiles (id) on delete cascade, -- admin ayant déclenché l'archive
  user_id uuid not null references public.profiles (id), -- membre auquel appartient ce point
  lat double precision not null,
  lng double precision not null,
  altitude double precision,
  speed double precision,
  accuracy double precision,
  recorded_at timestamptz not null,
  archived_at timestamptz not null default now()
);

create index if not exists location_share_archives_owner_idx
  on public.location_share_archives (owner_id);

alter table public.location_share_archives enable row level security;

-- Lecture réservée à l'administrateur — non consommée côté mobile dans ce
-- chantier (écriture seule via la RPC), prête pour un futur écran web.
create policy "owners can read their archived group history"
  on public.location_share_archives for select
  using (auth.uid() = owner_id);

-- ------------------------------------------------------------
-- Tokens push (Auto/iOS uniquement, spec §6) : Android n'en a pas besoin,
-- l'alarme exacte système est gérée nativement côté client sans aucune
-- infrastructure serveur.
-- ------------------------------------------------------------
create table if not exists public.push_tokens (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  platform text not null check (platform in ('ios')),
  token text not null,
  updated_at timestamptz not null default now(),
  unique (user_id, platform, token)
);

alter table public.push_tokens enable row level security;

create policy "users manage their own push tokens"
  on public.push_tokens for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
