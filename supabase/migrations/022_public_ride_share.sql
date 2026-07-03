-- 022_public_ride_share.sql
-- Make the web /share/[id] page work for rides the owner has marked public,
-- WITHOUT exposing the rides base table to anonymous users.
--
-- The rides table already has a visibility column ('private' | 'public',
-- default 'private') but no RLS policy uses it, so /share/[id] returned
-- nothing for anonymous visitors. Rather than add an anon SELECT policy on
-- rides (which would let anon read every column — user_id, storage paths,
-- session notes — of any public ride via the REST API), expose a curated
-- SECURITY DEFINER function that returns only the display columns the share
-- card renders, and only for rides whose visibility is 'public'.

create or replace function public.get_public_ride(p_ride_id uuid)
returns table (
  name                text,
  ride_type           text,
  started_at          timestamptz,
  duration_seconds    double precision,
  distance_meters     double precision,
  max_speed_mps       double precision,
  max_left_lean_deg   double precision,
  max_right_lean_deg  double precision,
  tags                text[],
  notes               text,
  bike_nickname       text,
  bike_year           integer,
  bike_make           text,
  bike_model          text
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select
    r.name, r.ride_type, r.started_at, r.duration_seconds, r.distance_meters,
    r.max_speed_mps, r.max_left_lean_deg, r.max_right_lean_deg, r.tags, r.notes,
    b.nickname, b.year, b.make, b.model
  from public.rides r
  left join public.bikes b on b.id = r.bike_id
  where r.id = p_ride_id
    and r.visibility = 'public';
$$;

-- This function is intentionally callable by anonymous visitors — it is the
-- public share endpoint. It only ever returns curated columns for public rides.
revoke execute on function public.get_public_ride(uuid) from public;
grant  execute on function public.get_public_ride(uuid) to anon, authenticated;
