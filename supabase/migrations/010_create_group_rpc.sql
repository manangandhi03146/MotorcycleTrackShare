-- ============================================================
-- RaceLine — Migration 010: create_group RPC (SECURITY DEFINER)
-- Run AFTER 009_group_owner_default.sql
--
-- We kept hitting 42501 on direct INSERT into `groups` despite
-- (a) matching the pattern that works fine for `shared_routes`,
-- (b) sourcing owner_id from the current auth session, and
-- (c) letting the DB fill owner_id via DEFAULT auth.uid().
--
-- Rather than continue guessing about JWT propagation for the
-- INSERT-under-RLS path, expose a small SECURITY DEFINER RPC.
-- The function:
--   - Reads auth.uid() itself and raises 28000 if unauthenticated
--   - Enforces the free-tier 5-owned-groups cap
--   - Performs the INSERT (bypasses RLS because SECURITY DEFINER)
--   - Returns the created row
--
-- The row still ends up owned by auth.uid(), so all the
-- follow-on SELECT / UPDATE / DELETE RLS remains untouched.
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

-- The `authenticated` role is the one PostgREST assigns to signed-in users.
GRANT EXECUTE ON FUNCTION create_group(TEXT, TEXT, BOOLEAN, TEXT) TO authenticated;

REVOKE EXECUTE ON FUNCTION create_group(TEXT, TEXT, BOOLEAN, TEXT) FROM PUBLIC;
