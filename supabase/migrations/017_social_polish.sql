-- ============================================================
-- RaceLine — Migration 017: Social polish (feed kinds, group lifecycle,
-- mutual-follower leaderboard, profile visibility for mutuals)
-- Run AFTER 016_groups_select_owner.sql
--
-- Covers four product changes:
--   1. Feed only surfaces route shares + new-bike additions. We add
--      `bikeAdded` to the allowed activity_feed.kind values (and `bike`
--      to subject_kind) so the emit path works.
--   2. Groups auto-delete when the last member leaves, and ownership
--      auto-transfers to the longest-tenured remaining member when the
--      owner leaves. Owner can also DELETE the group manually — that
--      already works via migration 014's `groups_delete_owner` policy.
--   3. Challenge leaderboards restrict to mutual followers of the
--      current user. RLS is extended so the caller can read
--      challenge_progress rows for users they're mutual with.
--   4. Mutual-follower visibility on `profiles` so leaderboards +
--      Riders list can render display names even when the other user
--      hasn't marked their profile public.
-- ============================================================

-- ============================================================
-- 1. Feed: allow `bikeAdded` kind + `bike` subject
-- ============================================================

ALTER TABLE activity_feed
    DROP CONSTRAINT IF EXISTS activity_feed_kind_check;

ALTER TABLE activity_feed
    ADD CONSTRAINT activity_feed_kind_check
    CHECK (kind IN (
        'rideCompleted',
        'challengeJoined',
        'challengeCompleted',
        'maintenanceLogged',
        'groupRideCreated',
        'sharedRoutePosted',
        'joinedGroup',
        'bikeAdded'
    ));

ALTER TABLE activity_feed
    DROP CONSTRAINT IF EXISTS activity_feed_subject_kind_check;

ALTER TABLE activity_feed
    ADD CONSTRAINT activity_feed_subject_kind_check
    CHECK (subject_kind IS NULL OR subject_kind IN (
        'ride', 'challenge', 'maintenance', 'group_ride',
        'shared_route', 'group', 'bike'
    ));

-- ============================================================
-- 2. Groups: auto-delete empty + ownership transfer
-- ============================================================

DROP TRIGGER IF EXISTS on_group_member_left ON group_members;
DROP FUNCTION IF EXISTS handle_group_member_left() CASCADE;

CREATE FUNCTION handle_group_member_left()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
    v_remaining_count  INTEGER;
    v_current_owner_id UUID;
    v_new_owner_id     UUID;
BEGIN
    -- When `pg_trigger_depth() > 1` we're firing because the caller ran
    -- `DELETE FROM groups` and the FK cascade is removing each member.
    -- In that case the group is going away anyway, so any cleanup here
    -- would be duplicate work and could recurse into the same cascade.
    IF pg_trigger_depth() > 1 THEN
        RETURN OLD;
    END IF;

    SELECT COUNT(*) INTO v_remaining_count
    FROM group_members
    WHERE group_id = OLD.group_id;

    IF v_remaining_count = 0 THEN
        -- Last member left. Nuke the group. ON DELETE CASCADE on the
        -- child tables (group_rides, challenges, shared_routes with
        -- group_id, activity_feed with group_id) cleans up references.
        DELETE FROM groups WHERE id = OLD.group_id;
        RETURN OLD;
    END IF;

    SELECT owner_id INTO v_current_owner_id
    FROM groups
    WHERE id = OLD.group_id;

    -- If the leaver was the owner AND there's no longer any member row
    -- for the current owner, promote the longest-tenured remaining
    -- member to owner and update groups.owner_id.
    IF v_current_owner_id = OLD.user_id THEN
        SELECT user_id INTO v_new_owner_id
        FROM group_members
        WHERE group_id = OLD.group_id
        ORDER BY joined_at ASC, user_id ASC
        LIMIT 1;

        IF v_new_owner_id IS NOT NULL THEN
            UPDATE group_members
                SET role = 'owner'
                WHERE group_id = OLD.group_id
                  AND user_id  = v_new_owner_id;

            UPDATE groups
                SET owner_id = v_new_owner_id
                WHERE id = OLD.group_id;
        END IF;
    END IF;

    RETURN OLD;
END;
$$;

CREATE TRIGGER on_group_member_left
    AFTER DELETE ON group_members
    FOR EACH ROW EXECUTE FUNCTION handle_group_member_left();

-- ============================================================
-- 3. Mutual-follower helper + challenge_progress SELECT for mutuals
-- ============================================================

DROP FUNCTION IF EXISTS mutual_follows(UUID, UUID) CASCADE;

CREATE FUNCTION mutual_follows(viewer_id UUID, target_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
    SELECT
        viewer_id = target_id
        OR (
            EXISTS (SELECT 1 FROM follows WHERE follower_id = viewer_id AND followee_id = target_id)
            AND
            EXISTS (SELECT 1 FROM follows WHERE follower_id = target_id AND followee_id = viewer_id)
        );
$$;

GRANT EXECUTE ON FUNCTION mutual_follows(UUID, UUID) TO public;

DROP POLICY IF EXISTS "progress: mutuals can see each other's progress" ON challenge_progress;

CREATE POLICY "progress: mutuals can see each other's progress"
    ON challenge_progress FOR SELECT
    TO authenticated
    USING (mutual_follows(auth.uid(), user_id));

-- ============================================================
-- 4. Profile visibility: mutual followers can see basic profile
-- ============================================================

DROP POLICY IF EXISTS "profiles: mutuals visible to each other" ON profiles;

CREATE POLICY "profiles: mutuals visible to each other"
    ON profiles FOR SELECT
    TO authenticated
    USING (mutual_follows(auth.uid(), id));

-- ============================================================
NOTIFY pgrst, 'reload schema';
