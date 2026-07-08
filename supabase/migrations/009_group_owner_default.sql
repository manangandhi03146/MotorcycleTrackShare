-- ============================================================
-- RaceLine — Migration 009: groups.owner_id default + policy re-seed
-- Run AFTER 008_group_ownership_limit.sql
--
-- Solves a persistent 42501 ("new row violates row-level security
-- policy for table \"groups\"") observed on the iOS client even when
-- the JWT was valid.
--
-- Root cause was hard to pin down: same insert pattern that worked
-- for `shared_routes` was failing for `groups`. Most likely
-- explanations are (a) migration 007 didn't fully apply for this
-- project, so the INSERT policy is missing, or (b) the client value
-- was drifting from auth.uid() in some edge case.
--
-- Belt + suspenders fix:
--   1. Set owner_id's DEFAULT to auth.uid(). If the app omits
--      owner_id from the payload, Postgres populates it with the
--      caller's auth.uid() at INSERT time — so the RLS check
--      compares auth.uid() = auth.uid() and always passes.
--   2. Idempotently DROP + CREATE the INSERT policy so it's
--      guaranteed present regardless of what 007 did.
-- ============================================================

ALTER TABLE groups
    ALTER COLUMN owner_id SET DEFAULT auth.uid();

-- Guarantee the INSERT policy is present and correct.
DROP POLICY IF EXISTS "groups: owners can create groups" ON groups;
CREATE POLICY "groups: owners can create groups"
    ON groups FOR INSERT
    WITH CHECK (owner_id = auth.uid());
