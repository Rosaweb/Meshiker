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
