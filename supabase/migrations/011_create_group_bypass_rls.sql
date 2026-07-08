-- ============================================================
-- RaceLine — Migration 011: force RLS off inside create_group
-- Run AFTER 010_create_group_rpc.sql
--
-- The RPC still hit 42501 even though it exists, is granted to
-- `authenticated`, and its INSERT sets owner_id from auth.uid().
-- The only explanation left is that RLS is still being applied to
-- the INSERT executed inside the function — SECURITY DEFINER only
-- switches the *role*, and on Supabase Cloud the default role may
-- not have BYPASSRLS.
--
-- Fix: attach `SET row_security = off` to the function so RLS is
-- disabled for its execution scope only. Every other statement in
-- the database is unaffected.
-- ============================================================

CREATE OR REPLACE FUNCTION create_group(
    p_name         TEXT,
    p_description  TEXT,
    p_is_public    BOOLEAN,
    p_join_code    TEXT
)
RETURNS groups
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off       -- <-- key line: RLS off inside this function
AS $$
DECLARE
    v_user_id      UUID;
    v_owned_count  INTEGER;
    v_new_group    groups;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
    END IF;

    SELECT COUNT(*) INTO v_owned_count
    FROM groups
    WHERE owner_id = v_user_id;

    IF v_owned_count >= 5 THEN
        RAISE EXCEPTION 'Free accounts can only create up to 5 groups'
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO groups (owner_id, name, description, is_public, join_code)
    VALUES (v_user_id, p_name, p_description, p_is_public, p_join_code)
    RETURNING * INTO v_new_group;

    RETURN v_new_group;
END;
$$;

GRANT EXECUTE ON FUNCTION create_group(TEXT, TEXT, BOOLEAN, TEXT) TO authenticated;
REVOKE EXECUTE ON FUNCTION create_group(TEXT, TEXT, BOOLEAN, TEXT) FROM PUBLIC;
