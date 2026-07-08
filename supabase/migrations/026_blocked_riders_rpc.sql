-- ============================================================
-- RaceLine — Migration 026: Blocked-riders lookup RPC
-- Run AFTER 025_moderation.sql
--
-- The "profiles: hide blocked" RESTRICTIVE policy from 025 means a normal
-- SELECT on `profiles` can't return users you've blocked — which breaks the
-- "Blocked accounts" management screen. This SECURITY DEFINER RPC returns the
-- minimal display fields for the riders the CALLER has blocked, and nothing
-- else, so there's no information leak.
-- ============================================================
CREATE OR REPLACE FUNCTION get_blocked_riders()
RETURNS TABLE (id UUID, username TEXT, display_name TEXT, avatar_path TEXT)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT p.id, p.username, p.display_name, p.avatar_path
    FROM profiles p
    JOIN user_blocks b ON b.blocked_id = p.id
    WHERE b.blocker_id = auth.uid();
$$;
