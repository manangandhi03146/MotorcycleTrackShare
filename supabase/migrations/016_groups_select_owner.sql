-- ============================================================
-- RaceLine — Migration 016: Allow group owner to SELECT their own group
-- Run AFTER 015_groups_fix_recursion.sql
--
-- Background:
-- GroupService.createGroup does `.insert(payload).select().single()`,
-- so Supabase must not only allow the INSERT but also allow the
-- caller to read back the freshly-inserted row.
--
-- The migration 015 SELECT policy was:
--     is_public = TRUE OR is_group_member(id, auth.uid())
--
-- For a private group, right after INSERT the AFTER trigger runs and
-- adds the owner to group_members — but PostgREST's returning-read
-- fires from the same statement context, and depending on visibility
-- semantics the read-back was still failing with 42501.
--
-- Fix: explicitly allow the owner to read their own group. This is a
-- pure ownership check with no cross-row lookups, so it can't recurse.
-- ============================================================

DROP POLICY IF EXISTS "groups_select_visible" ON groups;

CREATE POLICY "groups_select_visible"
    ON groups FOR SELECT
    TO public
    USING (
        is_public = TRUE
        OR owner_id = auth.uid()
        OR is_group_member(id, auth.uid())
    );

NOTIFY pgrst, 'reload schema';
