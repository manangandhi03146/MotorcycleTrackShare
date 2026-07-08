-- ============================================================
-- RaceLine — Migration 014: FULL RESET of groups + group_members
-- Run AFTER any earlier group-related migration.
--
-- This migration is idempotent and self-contained. It drops every
-- leftover policy / trigger / helper function on the `groups` and
-- `group_members` tables and re-creates the whole stack from
-- scratch, so any residue from migrations 006, 007, 008, 009, 010,
-- 011, 012, or 013 gets superseded cleanly.
--
-- Contract after this migration runs:
--   - RLS is enabled on both tables.
--   - `authenticated` role has SELECT/INSERT/UPDATE/DELETE grants
--     on both tables. `service_role` too.
--   - INSERT into `groups`:
--       * Requires `auth.uid() IS NOT NULL` (via WITH CHECK).
--       * BEFORE trigger overrides NEW.owner_id := auth.uid() so
--         the client can't spoof ownership.
--       * BEFORE trigger enforces the free-tier 5-owned cap.
--       * AFTER trigger auto-inserts the owner into group_members.
--   - SELECT on `groups`: public groups + groups you're a member of.
--   - UPDATE: owner/admin.
--   - DELETE: owner only.
--
-- Client-side (iOS): send only { name, description, is_public,
-- join_code }. The server fills owner_id via the BEFORE trigger.
-- ============================================================

ALTER TABLE groups         ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_members  ENABLE ROW LEVEL SECURITY;

-- Grants — just in case something revoked them along the way.
GRANT SELECT, INSERT, UPDATE, DELETE ON groups        TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON group_members TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON groups        TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON group_members TO service_role;

-- ============================================================
-- Wipe every policy on both tables (idempotent loop)
-- ============================================================
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT policyname FROM pg_policies
        WHERE schemaname = 'public' AND tablename = 'groups'
    LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON groups', r.policyname);
    END LOOP;

    FOR r IN
        SELECT policyname FROM pg_policies
        WHERE schemaname = 'public' AND tablename = 'group_members'
    LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON group_members', r.policyname);
    END LOOP;
END $$;

-- ============================================================
-- Drop leftover triggers + functions so we can recreate them
-- ============================================================
DROP TRIGGER IF EXISTS on_group_created                ON groups;
DROP TRIGGER IF EXISTS groups_force_owner_id_before    ON groups;
DROP TRIGGER IF EXISTS enforce_group_ownership_limit   ON groups;
DROP TRIGGER IF EXISTS groups_before_insert_tr         ON groups;
DROP TRIGGER IF EXISTS groups_after_insert_tr          ON groups;

DROP FUNCTION IF EXISTS handle_new_group()             CASCADE;
DROP FUNCTION IF EXISTS groups_force_owner_id()        CASCADE;
DROP FUNCTION IF EXISTS check_group_ownership_limit()  CASCADE;
DROP FUNCTION IF EXISTS groups_before_insert()         CASCADE;
DROP FUNCTION IF EXISTS groups_after_insert()          CASCADE;
DROP FUNCTION IF EXISTS create_group(TEXT, TEXT, BOOLEAN, TEXT) CASCADE;

-- Drop the auth.uid() DEFAULT from owner_id — the BEFORE trigger
-- is now the single source of truth so we don't want the DEFAULT
-- silently interfering.
ALTER TABLE groups ALTER COLUMN owner_id DROP DEFAULT;

-- ============================================================
-- BEFORE INSERT trigger on groups
-- Forces owner_id := auth.uid() and enforces the free-tier cap.
-- SECURITY DEFINER + `SET row_security = off` so this always runs
-- regardless of the connection role.
-- ============================================================
CREATE FUNCTION groups_before_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
    v_user_id      UUID;
    v_owned_count  INTEGER;
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

    NEW.owner_id := v_user_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER groups_before_insert_tr
    BEFORE INSERT ON groups
    FOR EACH ROW EXECUTE FUNCTION groups_before_insert();

-- ============================================================
-- AFTER INSERT trigger on groups
-- Auto-adds the owner to group_members.
-- SECURITY DEFINER + row_security off so it inserts even if the
-- group_members RLS policies would otherwise gate it.
-- ============================================================
CREATE FUNCTION groups_after_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
BEGIN
    INSERT INTO group_members (group_id, user_id, role)
    VALUES (NEW.id, NEW.owner_id, 'owner')
    ON CONFLICT (group_id, user_id) DO NOTHING;
    RETURN NEW;
END;
$$;

CREATE TRIGGER groups_after_insert_tr
    AFTER INSERT ON groups
    FOR EACH ROW EXECUTE FUNCTION groups_after_insert();

-- ============================================================
-- Policies on `groups`
-- All scoped `TO public` so they don't depend on PostgREST setting
-- a specific connection role.
-- ============================================================

CREATE POLICY "groups_insert_signed_in"
    ON groups FOR INSERT
    TO public
    WITH CHECK (auth.uid() IS NOT NULL);

CREATE POLICY "groups_select_visible"
    ON groups FOR SELECT
    TO public
    USING (
        is_public = TRUE
        OR EXISTS (
            SELECT 1
            FROM group_members gm
            WHERE gm.group_id = groups.id
              AND gm.user_id  = auth.uid()
        )
    );

CREATE POLICY "groups_update_admin"
    ON groups FOR UPDATE
    TO public
    USING (
        EXISTS (
            SELECT 1
            FROM group_members gm
            WHERE gm.group_id = groups.id
              AND gm.user_id  = auth.uid()
              AND gm.role IN ('owner', 'admin')
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM group_members gm
            WHERE gm.group_id = groups.id
              AND gm.user_id  = auth.uid()
              AND gm.role IN ('owner', 'admin')
        )
    );

CREATE POLICY "groups_delete_owner"
    ON groups FOR DELETE
    TO public
    USING (owner_id = auth.uid());

-- ============================================================
-- Policies on `group_members`
-- ============================================================

CREATE POLICY "group_members_insert_self"
    ON group_members FOR INSERT
    TO public
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "group_members_select_visible"
    ON group_members FOR SELECT
    TO public
    USING (
        user_id = auth.uid()
        OR EXISTS (
            SELECT 1
            FROM group_members gm
            WHERE gm.group_id = group_members.group_id
              AND gm.user_id  = auth.uid()
        )
        OR EXISTS (
            SELECT 1
            FROM groups g
            WHERE g.id = group_members.group_id
              AND g.is_public = TRUE
        )
    );

CREATE POLICY "group_members_delete_self_or_admin"
    ON group_members FOR DELETE
    TO public
    USING (
        user_id = auth.uid()
        OR EXISTS (
            SELECT 1
            FROM group_members gm
            WHERE gm.group_id = group_members.group_id
              AND gm.user_id  = auth.uid()
              AND gm.role IN ('owner', 'admin')
        )
    );

CREATE POLICY "group_members_update_admin"
    ON group_members FOR UPDATE
    TO public
    USING (
        EXISTS (
            SELECT 1
            FROM group_members gm
            WHERE gm.group_id = group_members.group_id
              AND gm.user_id  = auth.uid()
              AND gm.role IN ('owner', 'admin')
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM group_members gm
            WHERE gm.group_id = group_members.group_id
              AND gm.user_id  = auth.uid()
              AND gm.role IN ('owner', 'admin')
        )
    );

-- Force PostgREST to refresh its cached view of these tables/functions.
NOTIFY pgrst, 'reload schema';
