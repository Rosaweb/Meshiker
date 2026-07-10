-- ============================================================
-- Fonctions Supabase (PostgreSQL + PostGIS) — étape 4
-- ------------------------------------------------------------
-- À appliquer APRÈS schema.sql. Contient toute la logique
-- "communautaire" évoquée dans le brief (section 2) : fusion des
-- segments par buffer spatial, indice de fiabilité, lecture par
-- viewport, création automatique du profil à l'inscription.
--
-- Note de sécurité : plusieurs fonctions sont déclarées
-- `security definer`, c'est-à-dire qu'elles s'exécutent avec les
-- privilèges de leur propriétaire (contournant RLS) — nécessaire
-- puisque fusionner un segment implique de lire/modifier des
-- segments appartenant à D'AUTRES utilisateurs. C'est le pattern
-- Supabase standard pour des écritures partagées contrôlées, mais
-- cela signifie que CES fonctions, et uniquement elles, doivent
-- rester le seul chemin d'écriture pour ces tables en pratique.
-- Chacune ne fait que ce que son nom indique, sans requête dynamique
-- ni SQL construit à partir d'une chaîne fournie par le client.
-- ============================================================

-- ---------- Recalcul de l'indice de fiabilité ----------
-- Formule volontairement simple, pensée pour saturer vers 1.0 à mesure
-- que des utilisateurs DISTINCTS (pas juste des passages répétés du même
-- auteur) empruntent le segment — un unique utilisateur très actif ne
-- doit pas pouvoir gonfler artificiellement la fiabilité de son propre
-- tracé. À affiner avec des retours d'usage réels.
create or replace function public.recompute_segment_reliability(p_segment_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_distinct_users integer;
  v_total_passages integer;
  v_last_passage timestamptz;
begin
  select count(distinct user_id), count(*), max(passed_at)
  into v_distinct_users, v_total_passages, v_last_passage
  from public.segment_passages
  where segment_id = p_segment_id;

  update public.segments
  set passage_count = v_total_passages,
      last_passage_at = v_last_passage,
      -- ~1.0 atteint vers 5 contributeurs distincts, progression
      -- logarithmique pour adoucir les premiers passages.
      reliability_index = least(1.0, ln(1 + v_distinct_users) / ln(6)),
      updated_at = now()
  where id = p_segment_id;
end;
$$;

-- ---------- Fusion des segments par lot ----------
-- Reçoit un tableau JSON de segments en attente (voir SyncEngine côté
-- Dart) et, pour chacun :
--   1. reconstruit sa géométrie (LineStringZ) à partir des points bruts ;
--   2. cherche un segment existant dont le recouvrement avec la nouvelle
--      géométrie dépasse le seuil (même logique de "coverage ratio" que
--      SegmentationEngine._coverageRatio côté client, ici appliquée
--      GLOBALEMENT plutôt qu'à la seule toile locale d'un appareil) ;
--   3. si oui : n'insère PAS de nouveau segment, enregistre juste un
--      passage supplémentaire et recalcule la fiabilité ;
--   4. sinon : crée un nouveau segment canonique.
-- Traiter tout un lot en un seul appel (plutôt qu'un appel par segment)
-- limite le nombre d'aller-retours réseau — important au retour d'un
-- trek de plusieurs jours en zone blanche, où des centaines de segments
-- peuvent s'être accumulés avant la première occasion de synchroniser.
create or replace function public.upsert_segments_batch(
  p_segments jsonb,
  p_buffer_meters double precision default 8
)
returns table (local_uuid uuid, segment_id uuid, was_merged boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  seg jsonb;
  v_geom geometry(LineStringZ, 4326);
  v_existing_id uuid;
  v_new_id uuid;
  v_local_uuid uuid;
  v_distance double precision;
begin
  for seg in select * from jsonb_array_elements(p_segments)
  loop
    v_local_uuid := (seg->>'local_uuid')::uuid;
    v_distance := (seg->>'distance_meters')::double precision;

    select st_makeline(array_agg(
      st_setsrid(st_makepoint(
        (pt->>'lon')::double precision,
        (pt->>'lat')::double precision,
        coalesce((pt->>'alt')::double precision, 0)
      ), 4326) order by ord
    ))
    into v_geom
    from jsonb_array_elements(seg->'points') with ordinality as t(pt, ord);

    if v_geom is null or st_npoints(v_geom) < 2 then
      continue; -- segment invalide (points insuffisants) : ignoré, le
                -- client le retentera à la prochaine synchronisation
    end if;

    -- Pré-filtre grossier sur l'index GIST (bien moins coûteux qu'un
    -- ST_Buffer/ST_Intersection), puis recouvrement précis sur les
    -- quelques candidats restants seulement.
    select s.id into v_existing_id
    from public.segments s
    where s.merged_into is null
      and st_dwithin(s.geom::geography, v_geom::geography, p_buffer_meters + 50)
      and abs(s.distance_meters - v_distance) <= greatest(s.distance_meters, v_distance) * 0.3
      and st_length(
            st_intersection(
              v_geom,
              st_buffer(s.geom::geography, p_buffer_meters)::geometry
            )::geography
          ) / nullif(st_length(v_geom::geography), 0) >= 0.75
    order by st_distance(s.geom::geography, v_geom::geography)
    limit 1;

    if v_existing_id is not null then
      insert into public.segment_passages (segment_id, user_id, passed_at, traveled_forward)
      values (v_existing_id, (seg->>'author_id')::uuid, now(), true);

      perform public.recompute_segment_reliability(v_existing_id);

      local_uuid := v_local_uuid;
      segment_id := v_existing_id;
      was_merged := true;
      return next;
      continue;
    end if;

    v_new_id := gen_random_uuid();
    insert into public.segments (
      id, local_uuid, author_id, geom, mode, distance_meters,
      elevation_gain_meters, elevation_loss_meters, difficulty,
      passage_count, last_passage_at
    ) values (
      v_new_id, v_local_uuid, (seg->>'author_id')::uuid, v_geom,
      seg->>'mode', v_distance,
      (seg->>'elevation_gain_meters')::double precision,
      (seg->>'elevation_loss_meters')::double precision,
      seg->>'difficulty', 1, now()
    );

    insert into public.segment_passages (segment_id, user_id, passed_at, traveled_forward)
    values (v_new_id, (seg->>'author_id')::uuid, now(), true);

    perform public.recompute_segment_reliability(v_new_id);

    local_uuid := v_local_uuid;
    segment_id := v_new_id;
    was_merged := false;
    return next;
  end loop;
end;
$$;

-- ---------- Fusion des POI par lot ----------
-- Même principe que ci-dessus, en plus simple : un POI est un point, la
-- correspondance se limite à une distance (ST_DWithin), pas à un
-- recouvrement de tracé.
create or replace function public.upsert_pois_batch(
  p_pois jsonb,
  p_buffer_meters double precision default 25
)
returns table (local_uuid uuid, poi_id uuid, was_merged boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  item jsonb;
  v_point geometry(PointZ, 4326);
  v_existing_id uuid;
  v_new_id uuid;
  v_local_uuid uuid;
begin
  for item in select * from jsonb_array_elements(p_pois)
  loop
    v_local_uuid := (item->>'local_uuid')::uuid;
    v_point := st_setsrid(st_makepoint(
      (item->>'longitude')::double precision,
      (item->>'latitude')::double precision,
      coalesce((item->>'altitude')::double precision, 0)
    ), 4326);

    select p.id into v_existing_id
    from public.points_of_interest p
    where st_dwithin(p.geom::geography, v_point::geography, p_buffer_meters)
    order by st_distance(p.geom::geography, v_point::geography)
    limit 1;

    if v_existing_id is not null then
      update public.points_of_interest
      set times_referenced = times_referenced + 1,
          updated_at = now()
      where id = v_existing_id;

      local_uuid := v_local_uuid;
      poi_id := v_existing_id;
      was_merged := true;
      return next;
      continue;
    end if;

    v_new_id := gen_random_uuid();
    insert into public.points_of_interest (
      id, local_uuid, author_id, name, description, type, geom, times_referenced
    ) values (
      v_new_id, v_local_uuid, (item->>'author_id')::uuid,
      item->>'name', item->>'description', item->>'type', v_point, 1
    );

    local_uuid := v_local_uuid;
    poi_id := v_new_id;
    was_merged := false;
    return next;
  end loop;
end;
$$;

-- ---------- Lecture par viewport ----------
-- Renvoie les points sous forme de coordonnées GeoJSON déjà extraites
-- (points_geojson) plutôt que la géométrie brute : évite au client de
-- décoder du WKB, et rend le format directement consommable en Dart.
-- ATTENTION à l'ordre des coordonnées GeoJSON : [longitude, latitude,
-- altitude?], PAS [latitude, longitude] comme dans le reste de l'app —
-- voir SupabaseMapper côté Dart, qui documente ce point explicitement.
create or replace function public.segments_in_viewport(
  p_min_lon double precision,
  p_min_lat double precision,
  p_max_lon double precision,
  p_max_lat double precision,
  p_limit integer default 500
)
returns table (
  id uuid,
  local_uuid uuid,
  author_id uuid,
  mode text,
  distance_meters double precision,
  elevation_gain_meters double precision,
  elevation_loss_meters double precision,
  difficulty text,
  reliability_index double precision,
  passage_count integer,
  last_passage_at timestamptz,
  merged_into uuid,
  points_geojson json
)
language sql
stable
as $$
  select
    s.id, s.local_uuid, s.author_id, s.mode, s.distance_meters,
    s.elevation_gain_meters, s.elevation_loss_meters, s.difficulty,
    s.reliability_index, s.passage_count, s.last_passage_at, s.merged_into,
    (st_asgeojson(s.geom)::json -> 'coordinates') as points_geojson
  from public.segments s
  where s.merged_into is null
    -- L'opérateur && (recoupement de bounding box) exploite directement
    -- l'index GIST, contrairement à ST_Intersects qui est plus précis
    -- mais plus coûteux — un léger surplus de résultats aux abords du
    -- viewport est sans conséquence ici (l'app affiche simplement un peu
    -- plus large que la fenêtre visible).
    and s.geom && st_makeenvelope(p_min_lon, p_min_lat, p_max_lon, p_max_lat, 4326)
  limit p_limit;
$$;

create or replace function public.pois_in_viewport(
  p_min_lon double precision,
  p_min_lat double precision,
  p_max_lon double precision,
  p_max_lat double precision,
  p_limit integer default 500
)
returns table (
  id uuid,
  local_uuid uuid,
  author_id uuid,
  name text,
  description text,
  type text,
  latitude double precision,
  longitude double precision,
  times_referenced integer
)
language sql
stable
as $$
  select
    p.id, p.local_uuid, p.author_id, p.name, p.description, p.type,
    st_y(p.geom::geometry) as latitude,
    st_x(p.geom::geometry) as longitude,
    p.times_referenced
  from public.points_of_interest p
  where p.geom && st_makeenvelope(p_min_lon, p_min_lat, p_max_lon, p_max_lat, 4326)
  limit p_limit;
$$;

-- ---------- Création automatique du profil à l'inscription ----------
-- Pattern Supabase standard : évite au client d'avoir à insérer dans
-- `profiles` (et de se heurter à la contrainte de clé étrangère vers
-- auth.users si l'ordre des opérations n'était pas garanti). Le client
-- n'a plus qu'à METTRE À JOUR les champs modifiables (pseudo, avatar)
-- une fois connecté — voir SyncEngine._pushProfile côté Dart.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, pseudo)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'pseudo', 'Randonneur'))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
