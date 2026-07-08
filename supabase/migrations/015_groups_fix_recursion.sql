-- ============================================================
-- RaceLine — Migration 015: Fix RLS infinite recursion (42P17)
-- Run AFTER 014_groups_full_reset.sql
--
-- Migration 014 rebuilt the policies with inline `EXISTS (SELECT ...
-- FROM group_members ...)` clauses. When Postgres evaluates those
-- USING clauses on `group_members`, the inner SELECT hits the same
-- table and re-triggers the same policy — infinite recursion.
--
-- Fix: move every cross-row membership check into SECURITY DEFINER
-- helper functions with `row_security = off`. That way the inner
-- SELECT bypasses RLS entirely and the policy can call the helper
-- without recursing.
-- ============================================================

-- ---- Helpers ----
-- Idempotent: DROP first so we can freely change the definition.

DROP FUNCTION IF EXISTS is_group_member(UUID, UUID)  CASCADE;
DROP FUNCTION IF EXISTS is_group_admin(UUID, UUID)   CASCADE;
DROP FUNCTION IF EXISTS is_group_public(UUID)        CASCADE;

CREATE FUNCTION is_group_member(p_group_id UUID, p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
    SELECT EXISTS (
        SELECT 1 FROM group_members
        WHERE group_id = p_group_id
          AND user_id  = p_user_id
    );
$$;

CREATE FUNCTION is_group_admin(p_group_id UUID, p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
    SELECT EXISTS (
        SELECT 1 FROM group_members
        WHERE group_id = p_group_id
          AND user_id  = p_user_id
          AND role IN ('owner', 'admin')
    );
$$;

CREATE FUNCTION is_group_public(p_group_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
    SELECT EXISTS (
        SELECT 1 FROM groups
        WHERE id = p_group_id
          AND is_public = TRUE
    );
$$;

GRANT EXECUTE ON FUNCTION is_group_member(UUID, UUID)  TO public;
GRANT EXECUTE ON FUNCTION is_group_admin(UUID, UUID)   TO public;
GRANT EXECUTE ON FUNCTION is_group_public(UUID)        TO public;

-- ---- Rebuild the policies ----
-- Drop every policy on both tables again (idempotent) and rebuild
-- them, this time going through the helpers instead of inline EXISTS.

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
-- groups policies
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
        OR is_group_member(id, auth.uid())
    );

CREATE POLICY "groups_update_admin"
    ON groups FOR UPDATE
    TO public
    USING (is_group_admin(id, auth.uid()))
    WITH CHECK (is_group_admin(id, auth.uid()));

CREATE POLICY "groups_delete_owner"
    ON groups FOR DELETE
    TO public
    USING (owner_id = auth.uid());

-- ============================================================
-- group_members policies
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
        OR is_group_member(group_id, auth.uid())
        OR is_group_public(group_id)
    );

CREATE POLICY "group_members_update_admin"
    ON group_members FOR UPDATE
    TO public
    USING (is_group_admin(group_id, auth.uid()))
    WITH CHECK (is_group_admin(group_id, auth.uid()));

CREATE POLICY "group_members_delete_self_or_admin"
    ON group_members FOR DELETE
    TO public
    USING (
        user_id = auth.uid()
        OR is_group_admin(group_id, auth.uid())
    );

NOTIFY pgrst, 'reload schema';
