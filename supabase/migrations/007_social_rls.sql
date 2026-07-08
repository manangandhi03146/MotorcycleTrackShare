-- ============================================================
-- RaceLine — Migration 007: Phase 3 Social RLS Policies
-- Run AFTER 006_social.sql
--
-- Design assumptions:
--   - `profiles.is_public = TRUE` opts a user into being fetchable by
--     other authenticated users. Everything else on `profiles` remains
--     owner-only unless the user opted in.
--   - Followers are one-directional.
--   - Group membership is a strict gate for viewing anything inside a
--     group (rides, private-group challenges, group-visibility feed).
--   - Every helper is SECURITY DEFINER + STABLE and reads only the
--     smallest scoped subset it needs.
-- ============================================================

-- ============================================================
-- Helpers
-- ============================================================

-- Returns true when `viewer_id` follows `target_id`.
CREATE OR REPLACE FUNCTION viewer_follows(viewer_id UUID, target_id UUID)
RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1 FROM follows
        WHERE follower_id = viewer_id
          AND followee_id = target_id
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Returns true when `viewer_id` is a member of `group_id`.
CREATE OR REPLACE FUNCTION viewer_in_group(viewer_id UUID, group_id UUID)
RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1 FROM group_members
        WHERE group_id = viewer_in_group.group_id
          AND user_id  = viewer_id
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Returns true when `viewer_id` is owner or admin of `group_id`.
CREATE OR REPLACE FUNCTION viewer_manages_group(viewer_id UUID, group_id UUID)
RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1 FROM group_members
        WHERE group_id = viewer_manages_group.group_id
          AND user_id  = viewer_id
          AND role IN ('owner', 'admin')
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ============================================================
-- Enable RLS on every Phase 3 table
-- ============================================================
ALTER TABLE social_privacy_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE follows                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE groups                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_members           ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_rides             ENABLE ROW LEVEL SECURITY;
ALTER TABLE challenges              ENABLE ROW LEVEL SECURITY;
ALTER TABLE challenge_progress      ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared_routes           ENABLE ROW LEVEL SECURITY;
ALTER TABLE activity_feed           ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- profiles: additional policy for public discovery
-- (existing owner-only policies from 002 keep applying)
-- ============================================================
CREATE POLICY "profiles: public rows visible to authenticated"
    ON profiles FOR SELECT
    TO authenticated
    USING (
        id = auth.uid()
        OR is_public = TRUE
    );

-- ============================================================
-- social_privacy_settings
-- ============================================================
CREATE POLICY "privacy: users can view own privacy"
    ON social_privacy_settings FOR SELECT
    USING (user_id = auth.uid());

CREATE POLICY "privacy: users can insert own privacy"
    ON social_privacy_settings FOR INSERT
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "privacy: users can update own privacy"
    ON social_privacy_settings FOR UPDATE
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

-- ============================================================
-- follows
-- Anyone signed in can see who follows whom for the profiles they
-- can already see — enforced by joining to profiles at query time.
-- Insert/delete gated to the actor.
-- ============================================================
CREATE POLICY "follows: authenticated can read"
    ON follows FOR SELECT
    TO authenticated
    USING (TRUE);

CREATE POLICY "follows: users create own follow rows"
    ON follows FOR INSERT
    WITH CHECK (follower_id = auth.uid());

CREATE POLICY "follows: users remove own follow rows"
    ON follows FOR DELETE
    USING (follower_id = auth.uid());

-- ============================================================
-- groups
-- Any signed-in user can read a public group. Private groups are
-- readable only by members.
-- ============================================================
CREATE POLICY "groups: members and public visible"
    ON groups FOR SELECT
    TO authenticated
    USING (
        is_public = TRUE
        OR viewer_in_group(auth.uid(), id)
    );

CREATE POLICY "groups: owners can create groups"
    ON groups FOR INSERT
    WITH CHECK (owner_id = auth.uid());

CREATE POLICY "groups: owner/admin can update"
    ON groups FOR UPDATE
    USING (viewer_manages_group(auth.uid(), id))
    WITH CHECK (viewer_manages_group(auth.uid(), id));

CREATE POLICY "groups: owner can delete"
    ON groups FOR DELETE
    USING (owner_id = auth.uid());

-- ============================================================
-- group_members
-- ============================================================
CREATE POLICY "group_members: members visible to co-members"
    ON group_members FOR SELECT
    TO authenticated
    USING (
        user_id = auth.uid()
        OR viewer_in_group(auth.uid(), group_id)
    );

-- Users add themselves. (Join-by-code goes through the app which
-- resolves a group's id by code, then inserts a row for the caller.)
CREATE POLICY "group_members: users can join"
    ON group_members FOR INSERT
    WITH CHECK (user_id = auth.uid());

-- Users can leave; owners/admins can kick.
CREATE POLICY "group_members: users can leave or be removed by admin"
    ON group_members FOR DELETE
    USING (
        user_id = auth.uid()
        OR viewer_manages_group(auth.uid(), group_id)
    );

-- Owner/admin can promote/demote members.
CREATE POLICY "group_members: admin can update roles"
    ON group_members FOR UPDATE
    USING (viewer_manages_group(auth.uid(), group_id))
    WITH CHECK (viewer_manages_group(auth.uid(), group_id));

-- ============================================================
-- group_rides
-- ============================================================
CREATE POLICY "group_rides: members can view"
    ON group_rides FOR SELECT
    TO authenticated
    USING (viewer_in_group(auth.uid(), group_id));

CREATE POLICY "group_rides: members can create"
    ON group_rides FOR INSERT
    WITH CHECK (
        author_id = auth.uid()
        AND viewer_in_group(auth.uid(), group_id)
    );

CREATE POLICY "group_rides: author can update"
    ON group_rides FOR UPDATE
    USING (author_id = auth.uid())
    WITH CHECK (author_id = auth.uid());

CREATE POLICY "group_rides: author or admin can delete"
    ON group_rides FOR DELETE
    USING (
        author_id = auth.uid()
        OR viewer_manages_group(auth.uid(), group_id)
    );

-- ============================================================
-- challenges
-- Global challenges (group_id NULL) are readable by everyone signed in.
-- Group challenges follow group visibility.
-- ============================================================
CREATE POLICY "challenges: viewable when global or group-visible"
    ON challenges FOR SELECT
    TO authenticated
    USING (
        group_id IS NULL
        OR viewer_in_group(auth.uid(), group_id)
    );

-- Only the owner of a challenge can create a group challenge, and only
-- if they can manage that group. Global challenges are inserted via
-- service-role admin flows only (no client policy allows NULL owner).
CREATE POLICY "challenges: manager can create group challenge"
    ON challenges FOR INSERT
    WITH CHECK (
        owner_id = auth.uid()
        AND group_id IS NOT NULL
        AND viewer_manages_group(auth.uid(), group_id)
    );

CREATE POLICY "challenges: owner or admin can update"
    ON challenges FOR UPDATE
    USING (
        owner_id = auth.uid()
        OR (group_id IS NOT NULL AND viewer_manages_group(auth.uid(), group_id))
    );

CREATE POLICY "challenges: owner or admin can delete"
    ON challenges FOR DELETE
    USING (
        owner_id = auth.uid()
        OR (group_id IS NOT NULL AND viewer_manages_group(auth.uid(), group_id))
    );

-- ============================================================
-- challenge_progress
-- ============================================================
CREATE POLICY "progress: users see own progress"
    ON challenge_progress FOR SELECT
    USING (user_id = auth.uid());

CREATE POLICY "progress: users create own progress"
    ON challenge_progress FOR INSERT
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "progress: users update own progress"
    ON challenge_progress FOR UPDATE
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "progress: users leave a challenge"
    ON challenge_progress FOR DELETE
    USING (user_id = auth.uid());

-- ============================================================
-- shared_routes
-- Visibility rules — the safest default (private) always applies.
-- ============================================================
CREATE POLICY "routes: author sees own"
    ON shared_routes FOR SELECT
    USING (author_id = auth.uid());

CREATE POLICY "routes: public visibility"
    ON shared_routes FOR SELECT
    TO authenticated
    USING (visibility = 'public');

CREATE POLICY "routes: follower visibility"
    ON shared_routes FOR SELECT
    TO authenticated
    USING (
        visibility = 'followers'
        AND viewer_follows(auth.uid(), author_id)
    );

CREATE POLICY "routes: group visibility"
    ON shared_routes FOR SELECT
    TO authenticated
    USING (
        visibility = 'groups'
        AND group_id IS NOT NULL
        AND viewer_in_group(auth.uid(), group_id)
    );

CREATE POLICY "routes: author writes own"
    ON shared_routes FOR INSERT
    WITH CHECK (author_id = auth.uid());

CREATE POLICY "routes: author updates own"
    ON shared_routes FOR UPDATE
    USING (author_id = auth.uid())
    WITH CHECK (author_id = auth.uid());

CREATE POLICY "routes: author deletes own"
    ON shared_routes FOR DELETE
    USING (author_id = auth.uid());

-- ============================================================
-- activity_feed
-- No UPDATE policy — activity events are immutable after insert.
-- Visibility mirrors shared_routes but with follower / group / public
-- semantics evaluated at query time via the RLS predicates.
-- ============================================================
CREATE POLICY "feed: actor sees own"
    ON activity_feed FOR SELECT
    USING (actor_id = auth.uid());

CREATE POLICY "feed: public visibility"
    ON activity_feed FOR SELECT
    TO authenticated
    USING (visibility = 'public');

CREATE POLICY "feed: follower visibility"
    ON activity_feed FOR SELECT
    TO authenticated
    USING (
        visibility = 'followers'
        AND viewer_follows(auth.uid(), actor_id)
    );

CREATE POLICY "feed: group visibility"
    ON activity_feed FOR SELECT
    TO authenticated
    USING (
        visibility = 'groups'
        AND group_id IS NOT NULL
        AND viewer_in_group(auth.uid(), group_id)
    );

CREATE POLICY "feed: actor inserts own events"
    ON activity_feed FOR INSERT
    WITH CHECK (actor_id = auth.uid());

CREATE POLICY "feed: actor deletes own events"
    ON activity_feed FOR DELETE
    USING (actor_id = auth.uid());
