-- ============================================================
-- RaceLine — Migration 025: UGC Moderation (App Store Guideline 1.2)
-- Run AFTER 024_public_rider_profile.sql
--
-- Adds the safety primitives Apple requires for user-generated content:
--   1. user_blocks      — block abusive users; their content disappears
--                         for you (and yours for them) via RESTRICTIVE RLS.
--   2. content_reports  — report objectionable content/users for review.
--   3. profiles.accepted_terms_at — records agreement to the community
--                         guidelines / EULA before using social features.
--
-- Design notes:
--   - Block filtering is layered on with AS RESTRICTIVE policies so the
--     existing permissive SELECT policies from 007 are left untouched.
--     Restrictive policies AND with the permissive ones: a row is only
--     visible if it passes BOTH "who can see this" AND "not blocked".
--   - is_blocked_between() is SECURITY DEFINER so it can see block rows in
--     both directions regardless of the caller's own RLS on user_blocks.
-- ============================================================

-- ============================================================
-- user_blocks
-- ============================================================
CREATE TABLE IF NOT EXISTS user_blocks (
    blocker_id  UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    blocked_id  UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (blocker_id, blocked_id),
    CHECK (blocker_id <> blocked_id)
);

CREATE INDEX IF NOT EXISTS idx_user_blocks_blocker ON user_blocks(blocker_id);
CREATE INDEX IF NOT EXISTS idx_user_blocks_blocked ON user_blocks(blocked_id);

ALTER TABLE user_blocks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "blocks: owner reads own"
    ON user_blocks FOR SELECT
    USING (blocker_id = auth.uid());

CREATE POLICY "blocks: owner creates own"
    ON user_blocks FOR INSERT
    WITH CHECK (blocker_id = auth.uid());

CREATE POLICY "blocks: owner removes own"
    ON user_blocks FOR DELETE
    USING (blocker_id = auth.uid());

-- True when a block exists in EITHER direction between the two users.
-- SECURITY DEFINER so RLS on user_blocks doesn't hide the reverse row.
CREATE OR REPLACE FUNCTION is_blocked_between(a UUID, b UUID)
RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1 FROM user_blocks
        WHERE (blocker_id = a AND blocked_id = b)
           OR (blocker_id = b AND blocked_id = a)
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ============================================================
-- content_reports
-- Insert-only for regular users. Reviewed out-of-band via the
-- service role (no SELECT for others).
-- ============================================================
CREATE TABLE IF NOT EXISTS content_reports (
    id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    reporter_id       UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    reported_user_id  UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    content_type      TEXT NOT NULL CHECK (content_type IN (
        'profile', 'shared_route', 'activity', 'group', 'group_ride', 'other'
    )),
    content_id        UUID,
    reason            TEXT NOT NULL CHECK (reason IN (
        'spam', 'harassment', 'hate', 'violence', 'sexual', 'illegal', 'other'
    )),
    details           TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_content_reports_reporter ON content_reports(reporter_id);
CREATE INDEX IF NOT EXISTS idx_content_reports_reported ON content_reports(reported_user_id);
CREATE INDEX IF NOT EXISTS idx_content_reports_created  ON content_reports(created_at DESC);

ALTER TABLE content_reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY "reports: reporter creates own"
    ON content_reports FOR INSERT
    WITH CHECK (reporter_id = auth.uid());

CREATE POLICY "reports: reporter reads own"
    ON content_reports FOR SELECT
    USING (reporter_id = auth.uid());

-- ============================================================
-- profiles.accepted_terms_at — community guidelines / EULA agreement
-- (owner-update policy from migration 002 already lets the user set it)
-- ============================================================
ALTER TABLE profiles
    ADD COLUMN IF NOT EXISTS accepted_terms_at TIMESTAMPTZ;

-- ============================================================
-- Block-aware RESTRICTIVE SELECT policies.
-- These AND on top of the permissive 007 policies: content authored by
-- (or belonging to) someone in a block relationship with the viewer is
-- filtered out of feeds, profile lookups, route lists, and group rides.
-- Own rows always pass (you can't block yourself).
-- ============================================================
CREATE POLICY "profiles: hide blocked"
    ON profiles AS RESTRICTIVE FOR SELECT
    TO authenticated
    USING (NOT is_blocked_between(auth.uid(), id));

CREATE POLICY "activity_feed: hide blocked"
    ON activity_feed AS RESTRICTIVE FOR SELECT
    TO authenticated
    USING (NOT is_blocked_between(auth.uid(), actor_id));

CREATE POLICY "shared_routes: hide blocked"
    ON shared_routes AS RESTRICTIVE FOR SELECT
    TO authenticated
    USING (NOT is_blocked_between(auth.uid(), author_id));

CREATE POLICY "group_rides: hide blocked"
    ON group_rides AS RESTRICTIVE FOR SELECT
    TO authenticated
    USING (NOT is_blocked_between(auth.uid(), author_id));
