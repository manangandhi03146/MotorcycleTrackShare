-- 024_public_rider_profile.sql
-- Fix: a rider's public profile shows the avatar/name but never their bikes or
-- ride stats. Two causes: (1) the iOS profile screen only rendered placeholder
-- cards, and (2) bikes/rides RLS is owner-only, so another rider's data can't
-- be read at all.
--
-- Expose the missing data through privacy-respecting SECURITY DEFINER
-- functions. Each one returns rows ONLY when the target profile is public AND
-- the rider has left the relevant switch on (show_bikes / show_ride_stats), and
-- only ever returns curated, non-sensitive columns. Ride stats are aggregate
-- totals only — never individual rides, routes, or locations.

-- Bikes: make/model/year/nickname only. No photos, odometer, or notes.
create or replace function public.get_public_rider_bikes(p_user_id uuid)
returns table (
  nickname text,
  make     text,
  model    text,
  year     integer
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select b.nickname, b.make, b.model, b.year
  from public.bikes b
  join public.profiles p on p.id = b.user_id
  where b.user_id = p_user_id
    and b.is_archived = false
    and p.is_public = true
    and p.show_bikes = true
  order by b.is_default desc, b.created_at asc;
$$;

-- Ride stats: aggregate totals only.
create or replace function public.get_public_rider_stats(p_user_id uuid)
returns table (
  ride_count       bigint,
  total_distance_m double precision,
  total_duration_s double precision,
  max_speed_mps    double precision,
  max_lean_deg     double precision
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select
    count(*)::bigint,
    coalesce(sum(r.distance_meters), 0),
    coalesce(sum(r.duration_seconds), 0),
    coalesce(max(r.max_speed_mps), 0),
    coalesce(max(greatest(r.max_left_lean_deg, r.max_right_lean_deg)), 0)
  from public.rides r
  join public.profiles p on p.id = r.user_id
  where r.user_id = p_user_id
    and p.is_public = true
    and p.show_ride_stats = true
  having count(*) > 0;
$$;

revoke execute on function public.get_public_rider_bikes(uuid) from public;
revoke execute on function public.get_public_rider_stats(uuid) from public;
grant  execute on function public.get_public_rider_bikes(uuid) to anon, authenticated;
grant  execute on function public.get_public_rider_stats(uuid) to anon, authenticated;
