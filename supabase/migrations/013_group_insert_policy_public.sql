-- ============================================================
-- RaceLine — Migration 013: groups INSERT policy scoped to `public`
-- Run AFTER 012_group_owner_trigger.sql
--
-- Diagnosis:
--   Migration 012 replaced the INSERT policy with WITH CHECK (TRUE),
--   scoped `TO authenticated`. Direct SQL INSERT with an explicit
--   `SET LOCAL role = authenticated` succeeded. But PostgREST-mediated
--   INSERTs from the app still returned 42501, and disabling RLS on
--   the table made the app INSERT succeed.
--
-- Conclusion: PostgREST isn't setting the connection role to
-- `authenticated` for INSERTs on this project (root cause unknown —
-- possibly related to the ongoing Supabase capacity incident).
-- Since we already control auth-required insertion via the trigger
-- + auth.uid() check, we simply broaden the role clause to `public`
-- and enforce authentication inside WITH CHECK instead.
--
-- Same practical effect: only signed-in users can create a group,
-- and the trigger forces owner_id to auth.uid() regardless of what
-- the client sent. But the policy now applies regardless of which
-- role PostgREST assigns.
-- ============================================================

DROP POLICY IF EXISTS "groups: authenticated can create" ON groups;
DROP POLICY IF EXISTS "groups: owners can create groups" ON groups;

CREATE POLICY "groups: signed-in can create"
    ON groups FOR INSERT
    TO public
    WITH CHECK (auth.uid() IS NOT NULL);

NOTIFY pgrst, 'reload schema';
