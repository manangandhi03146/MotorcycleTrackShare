-- ============================================================
-- RaceLine — Migration 012: trigger-based owner_id + simple INSERT policy
-- Run AFTER 011_create_group_bypass_rls.sql
--
-- Why: The create_group RPC (migrations 010 + 011) works in
-- principle but repeatedly hit PGRST202 ("function not in schema
-- cache") on this project. Reloading the cache via
-- `NOTIFY pgrst, 'reload schema'` should fix that, but during a
-- Supabase capacity incident the signal can be delayed or dropped,
-- and we don't want group creation held hostage to the schema-cache
-- pipeline.
--
-- Fallback approach:
--   1. Attach a BEFORE INSERT trigger to `groups` that
--      unconditionally overrides NEW.owner_id with auth.uid().
--      Anyone unauthenticated raises 28000 before the row lands.
--   2. Simplify the INSERT policy so it only requires the caller
--      to be authenticated — the trigger already guarantees
--      owner_id = auth.uid(), so we don't need to double-check
--      inside the policy.
--   3. Re-issue the schema reload for good measure.
--
-- With this in place, the app can go back to a plain
-- `INSERT INTO groups (...)` without needing the RPC at all.
-- ============================================================

CREATE OR REPLACE FUNCTION groups_force_owner_id()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
    END IF;
    NEW.owner_id := auth.uid();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS groups_force_owner_id_before ON groups;
CREATE TRIGGER groups_force_owner_id_before
    BEFORE INSERT ON groups
    FOR EACH ROW EXECUTE FUNCTION groups_force_owner_id();

-- Simplify INSERT policy: the trigger guarantees owner_id = auth.uid(),
-- so the policy just needs to gate on the caller being authenticated.
DROP POLICY IF EXISTS "groups: owners can create groups" ON groups;
DROP POLICY IF EXISTS "groups: authenticated can create" ON groups;
CREATE POLICY "groups: authenticated can create"
    ON groups FOR INSERT
    TO authenticated
    WITH CHECK (TRUE);

NOTIFY pgrst, 'reload schema';
