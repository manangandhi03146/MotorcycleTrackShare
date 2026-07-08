-- ============================================================
-- RaceLine — Migration 019: Phase 4 Group Ride Navigation
-- Run AFTER 018_avatar_storage.sql
--
-- Extends the existing `group_rides` table into a full "shared ride
-- with destination + waypoints" concept, adds a participants table
-- and a live-location table for optional in-ride sharing. Wires
-- `rides.group_ride_id` so a locally-recorded ride can be linked
-- back to the group ride it was part of.
--
-- Design principles:
--   - Live locations are OPT-IN and only visible to fellow group
--     members. The RLS gates reads/writes accordingly.
--   - Group ride visibility follows the parent group's visibility
--     unless the ride explicitly opts to be public. Default: group-only.
--   - No paywall / no upgrade wall — feature is available to all
--     signed-in users. See product doc "Phase 4".
-- ============================================================

-- ============================================================
-- 1. Extend group_rides
-- ============================================================

ALTER TABLE group_rides
    ADD COLUMN IF NOT EXISTS destination_name       TEXT,
    ADD COLUMN IF NOT EXISTS destination_address    TEXT,
    ADD COLUMN IF NOT EXISTS destination_latitude   DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS destination_longitude  DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS waypoints              JSONB   NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS google_maps_url        TEXT,
    ADD COLUMN IF NOT EXISTS status                 TEXT    NOT NULL DEFAULT 'planned',
    ADD COLUMN IF NOT EXISTS visibility             TEXT    NOT NULL DEFAULT 'group_only',
    ADD COLUMN IF NOT EXISTS live_location_enabled  BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS started_at             TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS completed_at           TIMESTAMPTZ;

ALTER TABLE group_rides
    DROP CONSTRAINT IF EXISTS group_rides_status_check;
ALTER TABLE group_rides
    ADD CONSTRAINT group_rides_status_check
    CHECK (status IN ('planned', 'active', 'completed', 'cancelled'));

ALTER TABLE group_rides
    DROP CONSTRAINT IF EXISTS group_rides_visibility_check;
ALTER TABLE group_rides
    ADD CONSTRAINT group_rides_visibility_check
    CHECK (visibility IN ('group_only', 'public'));

-- ============================================================
-- 2. group_ride_participants
-- ============================================================

CREATE TABLE IF NOT EXISTS group_ride_participants (
    group_ride_id  UUID NOT NULL REFERENCES group_rides(id) ON DELETE CASCADE,
    user_id        UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    status         TEXT NOT NULL DEFAULT 'joined'
        CHECK (status IN ('interested', 'joined', 'riding', 'completed', 'cancelled')),
    joined_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (group_ride_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_group_ride_participants_user   ON group_ride_participants(user_id);
CREATE INDEX IF NOT EXISTS idx_group_ride_participants_ride   ON group_ride_participants(group_ride_id);

DROP TRIGGER IF EXISTS group_ride_participants_updated_at ON group_ride_participants;
CREATE TRIGGER group_ride_participants_updated_at
    BEFORE UPDATE ON group_ride_participants
    FOR EACH ROW EXECUTE FUNCTION handle_updated_at();

-- Author auto-joins as a participant on ride creation.
CREATE OR REPLACE FUNCTION handle_new_group_ride()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
BEGIN
    INSERT INTO group_ride_participants (group_ride_id, user_id, status)
    VALUES (NEW.id, NEW.author_id, 'joined')
    ON CONFLICT (group_ride_id, user_id) DO NOTHING;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_group_ride_created ON group_rides;
CREATE TRIGGER on_group_ride_created
    AFTER INSERT ON group_rides
    FOR EACH ROW EXECUTE FUNCTION handle_new_group_ride();

-- ============================================================
-- 3. group_ride_live_locations
-- One row per (group_ride, user). Updated in-place. RLS below
-- restricts visibility to fellow participants.
-- ============================================================

CREATE TABLE IF NOT EXISTS group_ride_live_locations (
    group_ride_id     UUID NOT NULL REFERENCES group_rides(id) ON DELETE CASCADE,
    user_id           UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    latitude          DOUBLE PRECISION NOT NULL,
    longitude         DOUBLE PRECISION NOT NULL,
    heading           DOUBLE PRECISION,
    speed_mps         DOUBLE PRECISION,
    sharing_enabled   BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (group_ride_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_live_locations_ride ON group_ride_live_locations(group_ride_id);

DROP TRIGGER IF EXISTS group_ride_live_locations_updated_at ON group_ride_live_locations;
CREATE TRIGGER group_ride_live_locations_updated_at
    BEFORE UPDATE ON group_ride_live_locations
    FOR EACH ROW EXECUTE FUNCTION handle_updated_at();

-- ============================================================
-- 4. rides.group_ride_id linkage
-- ============================================================

ALTER TABLE rides
    ADD COLUMN IF NOT EXISTS group_ride_id UUID REFERENCES group_rides(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_rides_group_ride ON rides(group_ride_id);

-- ============================================================
-- 5. Helpers for RLS
-- ============================================================

-- Is the viewer a participant on this group ride?
DROP FUNCTION IF EXISTS is_group_ride_participant(UUID, UUID) CASCADE;
CREATE FUNCTION is_group_ride_participant(p_ride_id UUID, p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
    SELECT EXISTS (
        SELECT 1 FROM group_ride_participants
        WHERE group_ride_id = p_ride_id AND user_id = p_user_id
    );
$$;

GRANT EXECUTE ON FUNCTION is_group_ride_participant(UUID, UUID) TO public;

-- Is the viewer a member of the parent group of this group ride?
DROP FUNCTION IF EXISTS is_group_ride_group_member(UUID, UUID) CASCADE;
CREATE FUNCTION is_group_ride_group_member(p_ride_id UUID, p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM group_rides gr
        JOIN group_members gm ON gm.group_id = gr.group_id
        WHERE gr.id = p_ride_id AND gm.user_id = p_user_id
    );
$$;

GRANT EXECUTE ON FUNCTION is_group_ride_group_member(UUID, UUID) TO public;

-- ============================================================
-- 6. RLS: group_rides
-- Migration 006 already set up member-only SELECT; we extend it to
-- also permit public rides visible to anyone signed in, and allow
-- the creator to UPDATE (edit) or cancel their own ride.
-- ============================================================

ALTER TABLE group_rides ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "group_rides: members can view"       ON group_rides;
DROP POLICY IF EXISTS "group_rides: members can create"     ON group_rides;
DROP POLICY IF EXISTS "group_rides: author can update"      ON group_rides;
DROP POLICY IF EXISTS "group_rides: author or admin can delete" ON group_rides;
DROP POLICY IF EXISTS "group_rides: visible to members or public" ON group_rides;

CREATE POLICY "group_rides: visible to members or public"
    ON group_rides FOR SELECT
    TO authenticated
    USING (
        visibility = 'public'
        OR is_group_member(group_id, auth.uid())
    );

CREATE POLICY "group_rides: members can create"
    ON group_rides FOR INSERT
    TO authenticated
    WITH CHECK (
        author_id = auth.uid()
        AND is_group_member(group_id, auth.uid())
    );

CREATE POLICY "group_rides: author or admin can update"
    ON group_rides FOR UPDATE
    TO authenticated
    USING (
        author_id = auth.uid()
        OR is_group_admin(group_id, auth.uid())
    )
    WITH CHECK (
        author_id = auth.uid()
        OR is_group_admin(group_id, auth.uid())
    );

CREATE POLICY "group_rides: author or admin can delete"
    ON group_rides FOR DELETE
    TO authenticated
    USING (
        author_id = auth.uid()
        OR is_group_admin(group_id, auth.uid())
    );

-- ============================================================
-- 7. RLS: group_ride_participants
-- ============================================================

ALTER TABLE group_ride_participants ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "participants: visible to co-participants or group" ON group_ride_participants;
DROP POLICY IF EXISTS "participants: users can join"                       ON group_ride_participants;
DROP POLICY IF EXISTS "participants: users can update own status"          ON group_ride_participants;
DROP POLICY IF EXISTS "participants: users can leave"                      ON group_ride_participants;

-- Anyone in the parent group can see who has RSVPed to a ride they
-- can see, plus the caller can always see their own row.
CREATE POLICY "participants: visible to co-participants or group"
    ON group_ride_participants FOR SELECT
    TO authenticated
    USING (
        user_id = auth.uid()
        OR is_group_ride_group_member(group_ride_id, auth.uid())
    );

-- Only members of the parent group can join a ride, and only for
-- themselves.
CREATE POLICY "participants: users can join"
    ON group_ride_participants FOR INSERT
    TO authenticated
    WITH CHECK (
        user_id = auth.uid()
        AND is_group_ride_group_member(group_ride_id, auth.uid())
    );

-- Users can only change their own participant row (status / etc).
CREATE POLICY "participants: users can update own status"
    ON group_ride_participants FOR UPDATE
    TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

-- Users can leave their own participant slot.
CREATE POLICY "participants: users can leave"
    ON group_ride_participants FOR DELETE
    TO authenticated
    USING (user_id = auth.uid());

-- ============================================================
-- 8. RLS: group_ride_live_locations
-- ============================================================

ALTER TABLE group_ride_live_locations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "live_loc: participants can view"        ON group_ride_live_locations;
DROP POLICY IF EXISTS "live_loc: users write own location"     ON group_ride_live_locations;
DROP POLICY IF EXISTS "live_loc: users update own location"    ON group_ride_live_locations;
DROP POLICY IF EXISTS "live_loc: users delete own location"    ON group_ride_live_locations;

-- Only fellow participants of the same group ride (or the owning
-- user) can read a location row. The `sharing_enabled` flag is
-- enforced application-side too — a client should stop reading
-- when it flips to FALSE — but the RLS below is the real gate.
CREATE POLICY "live_loc: participants can view"
    ON group_ride_live_locations FOR SELECT
    TO authenticated
    USING (
        user_id = auth.uid()
        OR is_group_ride_participant(group_ride_id, auth.uid())
    );

CREATE POLICY "live_loc: users write own location"
    ON group_ride_live_locations FOR INSERT
    TO authenticated
    WITH CHECK (
        user_id = auth.uid()
        AND is_group_ride_participant(group_ride_id, auth.uid())
    );

CREATE POLICY "live_loc: users update own location"
    ON group_ride_live_locations FOR UPDATE
    TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "live_loc: users delete own location"
    ON group_ride_live_locations FOR DELETE
    TO authenticated
    USING (user_id = auth.uid());

-- ============================================================
NOTIFY pgrst, 'reload schema';
