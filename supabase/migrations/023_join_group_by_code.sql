-- 023_join_group_by_code.sql
-- Fix: users cannot join a PRIVATE group even with the correct invite code.
--
-- The join flow first SELECTs the group by join_code, but the
-- groups_select_visible RLS policy only exposes a group that is public, owned
-- by the caller, or already joined. A non-member therefore cannot see a
-- private group by its code, so the lookup returns nothing and the app reports
-- "invalid join code".
--
-- Fix with a SECURITY DEFINER RPC: the invite code is the shared secret /
-- authorization, so we look the group up bypassing the SELECT policy, add the
-- caller as a member, and return the group. It can ONLY ever add the calling
-- user (auth.uid()) to a group whose code they supplied — it does not let a
-- user join arbitrary groups or read groups they don't have the code for.

create or replace function public.join_group_by_code(p_code text)
returns setof public.groups
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_group public.groups;
  v_uid   uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  select * into v_group
  from public.groups
  where upper(join_code) = upper(trim(p_code))
  limit 1;

  -- No match -> return no rows; the client maps this to "invalid join code".
  if not found then
    return;
  end if;

  -- Idempotent join: re-entering the code for a group you're already in is a
  -- no-op that still returns the group.
  insert into public.group_members (group_id, user_id, role)
  values (v_group.id, v_uid, 'member')
  on conflict (group_id, user_id) do nothing;

  return next v_group;
end;
$$;

revoke execute on function public.join_group_by_code(text) from public;
grant  execute on function public.join_group_by_code(text) to authenticated;
