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

-- ============================================================
-- Partage de trace GPX par QR code (voir schema.sql pour
-- trace_shares et le bucket "trace-shares").
-- ============================================================

-- ---------- Génération de token + réservation du partage ----------
-- security invoker (pas definer) : le token est généré ici mais
-- l'INSERT passe par la RLS normale de trace_shares (owner_id =
-- auth.uid()), pas besoin de privilèges élevés.
create or replace function public.create_trace_share(
  p_trace_local_uuid uuid,
  p_trace_name text,
  p_expires_in_days integer default 30
)
returns table (token text, expires_at timestamptz)
language plpgsql
security invoker
-- gen_random_bytes() vit dans le schéma "extensions" chez Supabase (où
-- pgcrypto s'installe par défaut), pas dans "public" : il faut l'inclure
-- explicitement dans le search_path de la fonction.
set search_path = public, extensions
as $$
declare
  v_token text;
  v_expires timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Authentification requise pour partager une trace.';
  end if;

  -- Partage nominatif = fonctionnalité "sociale" (spec-authentification-
  -- paywall.md section 7) : un utilisateur anonyme peut légitimement être
  -- premium (achat avant conversion de compte), mais doit d'abord se créer
  -- un compte permanent avant de pouvoir partager une trace.
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'Un compte permanent est requis pour partager une trace (voir Paramètres > Compte).';
  end if;

  -- 16 octets aléatoires cryptographiquement sûrs, encodés en base64
  -- URL-safe (même mécanisme que share_token pour tracking_sessions,
  -- brief section 3.5) — c'est aussi le nom de l'objet Storage.
  v_token := replace(replace(replace(
    encode(gen_random_bytes(16), 'base64'), '+', '-'), '/', '_'), '=', '');
  v_expires := now() + make_interval(days => p_expires_in_days);

  insert into public.trace_shares (owner_id, trace_local_uuid, trace_name, token, expires_at)
  values (auth.uid(), p_trace_local_uuid, p_trace_name, v_token, v_expires);

  token := v_token;
  expires_at := v_expires;
  return next;
end;
$$;

-- ---------- Révocation manuelle ----------
-- Pas de UI câblée dessus dans l'itération "génération" — prête pour
-- un futur écran "gérer mes partages".
create or replace function public.revoke_trace_share(p_token text)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  update public.trace_shares
  set revoked_at = now()
  where token = p_token and owner_id = auth.uid();
end;
$$;

-- ---------- Nettoyage périodique (pg_cron) ----------
-- Supprime la ligne storage.objects des partages expirés/révoqués :
-- suffisant pour BLOQUER toute lecture ultérieure (la route publique
-- consulte storage.objects pour résoudre l'objet). SECURITY DEFINER
-- nécessaire : le propriétaire du partage n'a normalement pas le
-- droit de DELETE sur storage.objects.
-- LIMITE CONNUE : ne libère pas l'espace de stockage sous-jacent
-- (l'octet physique reste dans le bucket S3-compatible tant qu'un
-- appel à l'API Storage remove() — nécessitant une clé service_role,
-- donc une Edge Function — n'a pas été fait). Acceptable pour un usage
-- gratuit/faible volume ; à revisiter si le stockage devient un sujet.
create or replace function public.purge_expired_trace_shares()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from storage.objects
  where bucket_id = 'trace-shares'
    and name in (
      select token || '.gpx' from public.trace_shares
      where revoked_at is not null or expires_at < now()
    );
end;
$$;

-- Activation directe par SQL (équivalent au toggle Dashboard > Database >
-- Extensions) : rend ce fichier autonome, sans dépendre d'une étape
-- manuelle préalable dans le dashboard.
create extension if not exists pg_cron;

do $$
begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'purge-expired-trace-shares';
exception when others then null;
end $$;

select cron.schedule(
  'purge-expired-trace-shares',
  '*/15 * * * *',
  $$select public.purge_expired_trace_shares();$$
);

-- ---------- Rédemption de code promo (validation + insertion atomique) ----------
-- Voir spec-codes-promo.md section 2. `for update` verrouille la ligne du
-- code le temps de la transaction : évite qu'une course entre deux
-- requêtes concurrentes sur un code à un seul usage restant ne les laisse
-- toutes les deux passer. Ne fait QUE la validation et l'écriture
-- Postgres — l'appel à l'API Grant de RevenueCat se fait ensuite, côté
-- Edge Function `redeem-promo-code`, uniquement si `success = true`
-- (jamais l'inverse : ne pas accorder l'entitlement avant confirmation
-- Postgres, pour ne pas octroyer un accès sans trace côté DB).
create or replace function public.redeem_promo_code(
  p_code text,
  p_user_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_promo record;
begin
  select * into v_promo
  from public.promo_codes
  where code = p_code
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error', 'invalid_code');
  end if;

  if not v_promo.is_active then
    return jsonb_build_object('success', false, 'error', 'code_inactive');
  end if;

  if v_promo.expires_at is not null and v_promo.expires_at < now() then
    return jsonb_build_object('success', false, 'error', 'code_expired');
  end if;

  if v_promo.max_redemptions is not null
     and v_promo.redemptions_count >= v_promo.max_redemptions then
    return jsonb_build_object('success', false, 'error', 'quota_reached');
  end if;

  if exists (
    select 1 from public.promo_code_redemptions
    where code_id = v_promo.id and user_id = p_user_id
  ) then
    return jsonb_build_object('success', false, 'error', 'already_redeemed');
  end if;

  insert into public.promo_code_redemptions (code_id, user_id)
  values (v_promo.id, p_user_id);

  update public.promo_codes
  set redemptions_count = redemptions_count + 1
  where id = v_promo.id;

  return jsonb_build_object(
    'success', true,
    'entitlement_id', v_promo.entitlement_id,
    'duration', v_promo.duration
  );
end;
$$;

-- ============================================================
-- Partage de position & Live tracking (voir schema.sql pour
-- location_shares/location_share_members/location_pings/
-- location_share_archives/push_tokens, et spec-partage-position-
-- live-tracking.md pour le document de référence complet).
-- ============================================================

-- ---------- Création d'un partage (gating premium serveur) ----------
-- security invoker (comme create_trace_share) : le gating premium ne
-- nécessite aucun privilège élevé — profiles.is_premium est déjà lisible
-- publiquement (policy "profiles are publicly readable") — et l'insertion
-- elle-même passe par la RLS normale de location_shares (owner_id =
-- auth.uid()). Même principe qu'assistant-token : jamais une simple
-- vérification côté client.
create or replace function public.create_location_share(
  p_label text,
  p_mode text,
  p_channels text[],
  p_reciprocity text default 'unilateral',
  p_live_interval_seconds integer default null,
  p_auto_times time[] default null,
  p_history_enabled boolean default false,
  p_history_global boolean default false,
  p_web_access text default 'public',
  p_web_password text default null,
  p_expires_in_hours integer default null
)
returns table (id uuid, share_token text, expires_at timestamptz)
language plpgsql
security invoker
-- gen_random_bytes()/crypt() vivent dans le schéma "extensions" chez
-- Supabase, pas dans "public" : il faut l'inclure explicitement.
set search_path = public, extensions
as $$
declare
  v_is_premium boolean;
  v_hours integer;
  v_expires timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Authentification requise pour créer un partage de position.';
  end if;

  -- Fonctionnalité intégralement premium (spec §1) : aucun accès même
  -- dégradé pour un compte non abonné, vérification serveur systématique.
  select is_premium into v_is_premium from public.profiles where id = auth.uid();
  if not coalesce(v_is_premium, false) then
    raise exception 'premium_required';
  end if;

  -- Même règle que create_trace_share (fonctionnalité "sociale") : un
  -- compte permanent est requis même pour un utilisateur anonyme premium.
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'Un compte permanent est requis pour partager votre position (voir Paramètres > Compte).';
  end if;

  if p_mode not in ('manual', 'auto', 'live') then
    raise exception 'Mode de partage invalide : %', p_mode;
  end if;

  -- Durées par défaut arrêtées avec l'utilisateur (voir plan
  -- d'implémentation) : Live=12h, Auto=72h (camps scouts/battues sur
  -- plusieurs jours), Manuel=1h (l'envoi ponctuel se termine
  -- immédiatement côté client via stop_location_share, cette valeur n'est
  -- qu'un filet de sécurité si cet appel échouait).
  v_hours := coalesce(p_expires_in_hours,
    case p_mode
      when 'auto' then 72
      when 'live' then 12
      else 1
    end);
  v_expires := now() + make_interval(hours => v_hours);

  insert into public.location_shares (
    owner_id, label, mode, channels, reciprocity,
    live_interval_seconds, auto_times, history_enabled, history_global,
    web_access, password_hash, expires_at
  )
  values (
    auth.uid(), p_label, p_mode, p_channels,
    case when p_mode = 'manual' then 'unilateral' else p_reciprocity end,
    p_live_interval_seconds, p_auto_times, p_history_enabled, p_history_global,
    p_web_access,
    case when p_web_password is not null then crypt(p_web_password, gen_salt('bf')) end,
    v_expires
  )
  returning location_shares.id, location_shares.share_token, location_shares.expires_at
  into id, share_token, expires_at;

  return next;
end;
$$;

-- ---------- Rejoindre un partage (App-to-app) ----------
-- security DEFINER : au moment de l'appel, le nouvel invité n'a encore
-- aucune ligne location_share_members — la policy "members can view
-- shares they belong to" ne peut donc pas encore le laisser lire le
-- partage. C'est exactement le cas qui justifie le bypass (contrairement
-- à create_location_share ci-dessus, qui n'en a pas besoin).
create or replace function public.join_location_share(p_share_token text)
returns table (
  share_id uuid, label text, owner_pseudo text, mode text,
  reciprocity text, history_global boolean, member_id uuid, invite_status text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_share record;
  v_member_id uuid;
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'Connexion requise pour rejoindre un partage de position.';
  end if;

  select * into v_share
  from public.location_shares s
  where s.share_token = p_share_token and s.is_active and s.expires_at > now();

  if not found then
    raise exception 'Ce lien de partage est invalide, expiré ou révoqué.';
  end if;

  select m.id, m.invite_status into v_member_id, v_status
  from public.location_share_members m
  where m.share_id = v_share.id and m.user_id = auth.uid();

  if v_member_id is null then
    insert into public.location_share_members (share_id, user_id, channel, invite_status)
    values (v_share.id, auth.uid(), 'app', 'pending')
    returning location_share_members.id, location_share_members.invite_status
    into v_member_id, v_status;
  end if;

  return query
    select v_share.id, v_share.label, p.pseudo, v_share.mode,
           v_share.reciprocity, v_share.history_global, v_member_id, v_status
    from public.profiles p
    where p.id = v_share.owner_id;
end;
$$;

-- ---------- Réponse à l'invitation App-to-app ----------
-- security invoker : le membre ne modifie que sa propre ligne, couvert par
-- la policy "members respond to their own invite and history consent".
-- Aucune émission de position n'est possible avant `accepted` : la policy
-- d'insert de location_pings exige is_accepted_app_member().
create or replace function public.respond_location_share_invite(
  p_member_id uuid,
  p_accept boolean
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  update public.location_share_members
  set invite_status = case when p_accept then 'accepted' else 'declined' end,
      invite_responded_at = now()
  where id = p_member_id and user_id = auth.uid();

  if not found then
    raise exception 'Invitation introuvable.';
  end if;
end;
$$;

-- ---------- Consentement à la conservation d'historique (spec §8.3) -------
-- Distinct de respond_location_share_invite ci-dessus à dessein : ce sont
-- deux consentements jamais l'un déduit de l'autre (spec §2, §15).
create or replace function public.set_history_consent(
  p_member_id uuid,
  p_consent boolean
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  update public.location_share_members
  set history_consent = p_consent,
      history_consent_at = now()
  where id = p_member_id and user_id = auth.uid();

  if not found then
    raise exception 'Membre introuvable.';
  end if;
end;
$$;

-- ---------- Extension de durée ("Étendre la durée", spec §7.4) ----------
create or replace function public.extend_location_share(
  p_share_id uuid,
  p_extra_hours integer
)
returns timestamptz
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_expires timestamptz;
begin
  update public.location_shares
  set expires_at = expires_at + make_interval(hours => p_extra_hours)
  where id = p_share_id and owner_id = auth.uid() and is_active
  returning expires_at into v_expires;

  if v_expires is null then
    raise exception 'Partage introuvable ou déjà terminé.';
  end if;

  return v_expires;
end;
$$;

-- ---------- Arrêt d'un partage ("Arrêter le partage", spec §7.5) --------
create or replace function public.stop_location_share(p_share_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  update public.location_shares
  set is_active = false, ended_at = now()
  where id = p_share_id and owner_id = auth.uid();

  if not found then
    raise exception 'Partage introuvable.';
  end if;
end;
$$;

-- ---------- Archive serveur de l'historique de groupe ----------
-- Décision produit (voir plan d'implémentation, hors texte brut de la
-- spec) : security DEFINER, seule fonction pouvant écrire dans
-- location_share_archives (aucune policy d'insert sur cette table, même
-- précédent que promo_codes). N'archive que l'administrateur lui-même et
-- les membres ayant explicitement consenti (history_consent = true) —
-- jamais les autres, même s'ils restent visibles en direct pendant la
-- session (spec §8.3).
create or replace function public.archive_group_location_history(p_share_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  if not exists (
    select 1 from public.location_shares
    where id = p_share_id and owner_id = auth.uid() and history_global
  ) then
    raise exception 'Historique global non activé, ou vous n''êtes pas l''administrateur de ce partage.';
  end if;

  insert into public.location_share_archives (
    share_id, owner_id, user_id, lat, lng, altitude, speed, accuracy, recorded_at
  )
  select lp.share_id, s.owner_id, lp.user_id, lp.lat, lp.lng, lp.altitude, lp.speed, lp.accuracy, lp.recorded_at
  from public.location_pings lp
  join public.location_shares s on s.id = lp.share_id
  left join public.location_share_members m on m.share_id = lp.share_id and m.user_id = lp.user_id
  where lp.share_id = p_share_id
    and (lp.user_id = s.owner_id or m.history_consent);

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ---------- Nettoyage périodique (pg_cron) ----------
-- Même cadence (15 min) et même pattern d'enregistrement idempotent que
-- purge_expired_trace_shares. Délai de grâce d'1h pour les partages à
-- historique (history_enabled ou history_global) avant de purger leurs
-- location_pings : décision utilisateur (voir plan d'implémentation) pour
-- laisser une fenêtre de réouverture de l'app et répondre aux
-- propositions de sauvegarde/archivage de fin de session. Les partages
-- sans historique sont purgés immédiatement, comme prévu par la spec §4
-- ("aucune donnée ne survit à la session sans sauvegarde explicite").
create or replace function public.purge_expired_location_shares()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.location_shares
  set is_active = false, ended_at = coalesce(ended_at, now())
  where is_active and expires_at < now();

  delete from public.location_pings
  where share_id in (
    select id from public.location_shares
    where not is_active
      and not history_enabled and not history_global
      and expires_at < now()
  );

  delete from public.location_pings
  where share_id in (
    select id from public.location_shares
    where not is_active
      and (history_enabled or history_global)
      and expires_at < now() - interval '1 hour'
  );
end;
$$;

do $$
begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'purge-expired-location-shares';
exception when others then null;
end $$;

select cron.schedule(
  'purge-expired-location-shares',
  '*/15 * * * *',
  $$select public.purge_expired_location_shares();$$
);

-- ============================================================
-- Auto/iOS — réveil par push silencieux (Milestone D du plan
-- d'implémentation). Android n'a besoin d'aucune fonction ici : l'alarme
-- exacte système est gérée entièrement côté client
-- (lib/sharing/location_auto_alarm_service.dart).
-- ============================================================

-- ---------- Partages Auto dus pour un check-in maintenant ----------
-- `auto_times` est stocké en UTC (converti côté client avant l'envoi à
-- create_location_share, voir LocationShareCreateScreen._formatTimeOfDay
-- — sans quoi cette comparaison contre `now()` en UTC serait fausse pour
-- tout utilisateur hors UTC). Tolérance d'une minute pile : le cron qui
-- appelle send-auto-checkin-push tourne à la minute (voir
-- trigger_auto_checkin_push ci-dessous).
create or replace function public.due_auto_location_shares()
returns table (share_id uuid)
language sql
stable
security definer
set search_path = public
as $$
  select s.id
  from public.location_shares s
  where s.is_active and s.mode = 'auto' and s.expires_at > now()
    and exists (
      select 1 from unnest(s.auto_times) as auto_time
      where date_trunc('minute', auto_time)
          = date_trunc('minute', (now() at time zone 'utc')::time)
    );
$$;

-- ---------- Tokens iOS des destinataires d'un ensemble de partages ------
-- Administrateur + membres `app`/`accounts_only` acceptés, pour chacun
-- des `p_share_ids` — un seul appel plutôt qu'un aller-retour par partage
-- depuis l'Edge Function.
create or replace function public.location_share_ios_recipients(p_share_ids uuid[])
returns table (token text)
language sql
stable
security definer
set search_path = public
as $$
  select distinct pt.token
  from public.push_tokens pt
  where pt.platform = 'ios'
    and pt.user_id in (
      select s.owner_id from public.location_shares s where s.id = any(p_share_ids)
      union
      select m.user_id from public.location_share_members m
      where m.share_id = any(p_share_ids)
        and m.channel in ('app', 'accounts_only')
        and m.invite_status = 'accepted'
        and m.user_id is not null
    );
$$;

-- ---------- Déclenchement périodique de send-auto-checkin-push ----------
-- Pas de précédent pg_net/net.http_post ailleurs dans ce repo (voir plan
-- d'implémentation) : ceci est le mécanisme de repli qui fonctionne sur
-- tout projet Supabase, quel que soit son plan. SI le projet Supabase
-- utilisé supporte les "Cron Triggers for Edge Functions" natifs
-- (dashboard > Edge Functions > Triggers), PRÉFÉRER ce mécanisme natif à
-- la place et ne jamais activer les deux en même temps (double envoi) —
-- vérifier au moment du déploiement, pas devinable depuis ce repo.
--
-- Le secret partagé (vérifié dans send-auto-checkin-push/index.ts) est
-- stocké via Supabase Vault, jamais en clair ici. À créer une fois dans le
-- SQL Editor du dashboard (valeur au choix, longue et aléatoire) :
--   select vault.create_secret('<valeur choisie>', 'cron_shared_secret');
-- Puis configurer la MÊME valeur côté Edge Function :
--   npx supabase secrets set CRON_SHARED_SECRET=<même valeur>
--
-- ⚠️ Remplacer <PROJECT_REF> ci-dessous par la référence réelle du projet
-- Supabase avant d'exécuter ce bloc (visible dans l'URL du dashboard ou
-- Settings > API) — pas connaissable depuis ce repo.
create extension if not exists pg_net;

create or replace function public.trigger_auto_checkin_push()
returns void
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  v_secret text;
begin
  select decrypted_secret into v_secret
  from vault.decrypted_secrets where name = 'cron_shared_secret';

  if v_secret is null then
    raise warning 'trigger_auto_checkin_push: secret "cron_shared_secret" introuvable dans Vault, envoi annulé.';
    return;
  end if;

  perform net.http_post(
    url := 'https://<PROJECT_REF>.supabase.co/functions/v1/send-auto-checkin-push',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_secret, 'Content-Type', 'application/json'),
    body := '{}'::jsonb
  );
end;
$$;

do $$
begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'trigger-auto-checkin-push';
exception when others then null;
end $$;

select cron.schedule(
  'trigger-auto-checkin-push',
  '* * * * *',
  $$select public.trigger_auto_checkin_push();$$
);
