-- 020_function_hardening.sql
-- Security hardening surfaced by the Supabase database linter (advisors).
--
-- NOT YET APPLIED to the live database — this migration was generated during a
-- security audit while v1.0 is in App Review. Review, then apply with:
--   supabase db push          (or apply via the dashboard SQL editor)
--
-- Two classes of finding are addressed:
--
-- 1. lint 0028/0029 — SECURITY DEFINER trigger functions are reachable as RPC
--    endpoints (/rest/v1/rpc/<fn>) by the anon and authenticated roles. These
--    functions only ever run from table triggers, so no client role needs
--    EXECUTE. Revoking it removes the RPC surface without affecting triggers
--    (triggers run as the table owner regardless of role grants).
--
--    The RLS *helper* functions (is_group_admin, is_group_member,
--    viewer_follows, viewer_in_group, viewer_manages_group, mutual_follows,
--    is_group_public, is_group_ride_participant, is_group_ride_group_member)
--    are deliberately left executable — RLS policies evaluate them in the
--    querying role's context, so revoking EXECUTE would break row access.
--
-- 2. lint 0011 — functions with a mutable search_path. Pinning search_path
--    prevents a search-path-injection attack against SECURITY DEFINER code.

-- 1. Revoke the RPC surface on trigger-only functions.
REVOKE EXECUTE ON FUNCTION public.handle_updated_at()        FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.handle_new_user()          FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.handle_new_privacy_row()   FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.handle_new_group_ride()    FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.handle_group_member_left() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.groups_before_insert()     FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.groups_after_insert()      FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.enforce_ride_limit()       FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable()          FROM anon, authenticated;

-- 2. Pin search_path on the functions the linter flagged as mutable.
-- ALTER FUNCTION only changes the setting, never the body — non-breaking.
ALTER FUNCTION public.handle_updated_at()                        SET search_path = public, pg_temp;
ALTER FUNCTION public.handle_new_privacy_row()                   SET search_path = public, pg_temp;
ALTER FUNCTION public.viewer_follows(uuid, uuid)                 SET search_path = public, pg_temp;
ALTER FUNCTION public.viewer_in_group(uuid, uuid)               SET search_path = public, pg_temp;
ALTER FUNCTION public.viewer_manages_group(uuid, uuid)          SET search_path = public, pg_temp;
