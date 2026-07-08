-- ============================================================
-- RaceLine — Migration 006: Phase 3 Social Schema
-- Run AFTER 005_cloud_ride_limit.sql
--
-- Adds the tables that back Groups / Challenges / Public Profiles /
-- Route sharing / Friend activity / Social privacy settings.
--
-- Design notes:
--   - Every table follows the existing `handle_updated_at()` +
--     `on_auth_user_created` conventions from migration 001.
--   - The `profiles` table is extended in place — social columns are
--     nullable with safe defaults so existing rows keep working.
--   - Follows are one-directional (X follows Y). It's simpler than
--     friend requests and matches how RaceLine's social features work.
--   - Activity feed rows are immutable after insert (no UPDATE policy).
--     They fan out only to viewers allowed by the emitter's privacy
--     settings — that check lives in the RLS layer in 007.
-- ============================================================

-- ============================================================
-- profiles: social extensions
-- ============================================================
ALTER TABLE profiles
    ADD COLUMN IF NOT EXISTS username          TEXT UNIQUE,
    ADD COLUMN IF NOT EXISTS bio               TEXT,
    ADD COLUMN IF NOT EXISTS avatar_path       TEXT,          -- storage path: {user_id}/avatar.jpg
    ADD COLUMN IF NOT EXISTS is_public         BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS show_bikes        BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS show_ride_stats   BOOLEAN NOT NULL DEFAULT TRUE;

CREATE INDEX IF NOT EXISTS idx_profiles_username    ON profiles(username);
CREATE INDEX IF NOT EXISTS idx_profiles_is_public   ON profiles(is_public);

-- ============================================================
-- social_privacy_settings
-- Fine-grained privacy switches. Kept in its own table so it can
-- grow without further profile schema churn.
-- ============================================================
CREATE TABLE IF NOT EXISTS social_privacy_settings (
    user_id                          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    share_rides_by_default           BOOLEAN NOT NULL DEFAULT FALSE,
    hide_ride_start_by_default       BOOLEAN NOT NULL DEFAULT TRUE,
    hide_ride_end_by_default         BOOLEAN NOT NULL DEFAULT TRUE,
    show_ride_activities             BOOLEAN NOT NULL DEFAULT FALSE,
    show_challenge_activities        BOOLEAN NOT NULL DEFAULT TRUE,
    show_maintenance_activities      BOOLEAN NOT NULL DEFAULT FALSE,
    show_group_activities            BOOLEAN NOT NULL DEFAULT TRUE,
    share_default_route_visibility   TEXT NOT NULL DEFAULT 'private'
        CHECK (share_default_route_visibility IN ('private', 'followers', 'groups', 'public')),
    created_at                       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE TRIGGER social_privacy_settings_updated_at
    BEFORE UPDATE ON social_privacy_settings
    FOR EACH ROW EXECUTE FUNCTION handle_updated_at();

-- Auto-create a privacy row when a profile is created.
CREATE OR REPLACE FUNCTION handle_new_privacy_row()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO social_privacy_settings (user_id)
    VALUES (NEW.id)
    ON CONFLICT (user_id) DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_profile_created_privacy ON profiles;
CREATE TRIGGER on_profile_created_privacy
    AFTER INSERT ON profiles
    FOR EACH ROW EXECUTE FUNCTION handle_new_privacy_row();

-- Backfill for existing users:
INSERT INTO social_privacy_settings (user_id)
SELECT id FROM profiles
ON CONFLICT (user_id) DO NOTHING;

-- ============================================================
-- follows
-- Simple one-directional graph: follower_id -> followee_id.
-- ============================================================
CREATE TABLE IF NOT EXISTS follows (
    follower_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    followee_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (follower_id, followee_id),
    CHECK (follower_id <> followee_id)
);

CREATE INDEX IF NOT EXISTS idx_follows_follower  ON follows(follower_id);
CREATE INDEX IF NOT EXISTS idx_follows_followee  ON follows(followee_id);

-- ============================================================
-- groups
-- Motorcycle-focused rider crews. `join_code` is a random 8-char
-- string used by "join by code" flows.
-- ============================================================
CREATE TABLE IF NOT EXISTS groups (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_id        UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    description     TEXT,
    is_public       BOOLEAN NOT NULL DEFAULT FALSE,
    join_code       TEXT UNIQUE NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_groups_owner        ON groups(owner_id);
CREATE INDEX IF NOT EXISTS idx_groups_join_code    ON groups(join_code);
CREATE INDEX IF NOT EXISTS idx_groups_public       ON groups(is_public) WHERE is_public = TRUE;

CREATE OR REPLACE TRIGGER groups_updated_at
    BEFORE UPDATE ON groups
    FOR EACH ROW EXECUTE FUNCTION handle_updated_at();

-- ============================================================
-- group_members
-- ============================================================
CREATE TABLE IF NOT EXISTS group_members (
    group_id        UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    role            TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'admin', 'member')),
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (group_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_group_members_user   ON group_members(user_id);

-- When a group is created the owner is auto-inserted as owner.
CREATE OR REPLACE FUNCTION handle_new_group()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO group_members (group_id, user_id, role)
    VALUES (NEW.id, NEW.owner_id, 'owner')
    ON CONFLICT (group_id, user_id) DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_group_created ON groups;
CREATE TRIGGER on_group_created
    AFTER INSERT ON groups
    FOR EACH ROW EXECUTE FUNCTION handle_new_group();

-- ============================================================
-- group_rides
-- Group ride "posts" — either a proposed upcoming ride or a
-- past ride that was shared with the group.
-- ============================================================
CREATE TABLE IF NOT EXISTS group_rides (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    group_id        UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    author_id       UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    ride_id         UUID REFERENCES rides(id) ON DELETE SET NULL,
    title           TEXT NOT NULL,
    description     TEXT,
    scheduled_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_group_rides_group   ON group_rides(group_id);

CREATE OR REPLACE TRIGGER group_rides_updated_at
    BEFORE UPDATE ON group_rides
    FOR EACH ROW EXECUTE FUNCTION handle_updated_at();

-- ============================================================
-- challenges
-- Curated (usually app-authored) challenges. `owner_id` may be NULL
-- for global challenges and non-NULL for user-authored group challenges.
-- ============================================================
CREATE TABLE IF NOT EXISTS challenges (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_id            UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    group_id            UUID REFERENCES groups(id) ON DELETE CASCADE,
    slug                TEXT UNIQUE NOT NULL,
    title               TEXT NOT NULL,
    description         TEXT,
    challenge_type      TEXT NOT NULL CHECK (challenge_type IN (
        'weeklyMileage',
        'monthlyStreak',
        'mostRides',
        'longestRide',
        'maintenanceStreak',
        'smoothnessImprovement',
        'trackSession'
    )),
    goal_value          DOUBLE PRECISION NOT NULL,
    goal_unit           TEXT NOT NULL,
    starts_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ends_at             TIMESTAMPTZ,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_challenges_active   ON challenges(is_active) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_challenges_group    ON challenges(group_id);

CREATE OR REPLACE TRIGGER challenges_updated_at
    BEFORE UPDATE ON challenges
    FOR EACH ROW EXECUTE FUNCTION handle_updated_at();

-- ============================================================
-- challenge_progress
-- Per-user progress toward a challenge goal.
-- ============================================================
CREATE TABLE IF NOT EXISTS challenge_progress (
    challenge_id    UUID NOT NULL REFERENCES challenges(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    current_value   DOUBLE PRECISION NOT NULL DEFAULT 0,
    completed_at    TIMESTAMPTZ,
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (challenge_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_challenge_progress_user  ON challenge_progress(user_id);

CREATE OR REPLACE TRIGGER challenge_progress_updated_at
    BEFORE UPDATE ON challenge_progress
    FOR EACH ROW EXECUTE FUNCTION handle_updated_at();

-- ============================================================
-- shared_routes
-- A ride's route packaged for sharing. Points array is stored as
-- JSONB so the app can decide how to sanitize before insert
-- (trim first/last N points to hide start/end).
-- ============================================================
CREATE TABLE IF NOT EXISTS shared_routes (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    author_id           UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    ride_id             UUID REFERENCES rides(id) ON DELETE SET NULL,
    title               TEXT NOT NULL,
    description         TEXT,
    distance_meters     DOUBLE PRECISION NOT NULL DEFAULT 0,
    visibility          TEXT NOT NULL DEFAULT 'private'
        CHECK (visibility IN ('private', 'followers', 'groups', 'public')),
    group_id            UUID REFERENCES groups(id) ON DELETE CASCADE,
    hide_start          BOOLEAN NOT NULL DEFAULT TRUE,
    hide_end            BOOLEAN NOT NULL DEFAULT TRUE,
    trim_points         INTEGER NOT NULL DEFAULT 0,
    route_points        JSONB NOT NULL DEFAULT '[]'::JSONB,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_shared_routes_author        ON shared_routes(author_id);
CREATE INDEX IF NOT EXISTS idx_shared_routes_visibility    ON shared_routes(visibility);
CREATE INDEX IF NOT EXISTS idx_shared_routes_group         ON shared_routes(group_id);

CREATE OR REPLACE TRIGGER shared_routes_updated_at
    BEFORE UPDATE ON shared_routes
    FOR EACH ROW EXECUTE FUNCTION handle_updated_at();

-- ============================================================
-- activity_feed
-- Immutable event log used for friend/group activity.
--
-- `subject_id` is a generic reference (ride id, challenge id,
-- shared route id, etc.) — the interpretation depends on `kind`.
-- ============================================================
CREATE TABLE IF NOT EXISTS activity_feed (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    actor_id        UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    kind            TEXT NOT NULL CHECK (kind IN (
        'rideCompleted',
        'challengeJoined',
        'challengeCompleted',
        'maintenanceLogged',
        'groupRideCreated',
        'sharedRoutePosted',
        'joinedGroup'
    )),
    subject_id      UUID,
    subject_kind    TEXT CHECK (subject_kind IN ('ride', 'challenge', 'maintenance', 'group_ride', 'shared_route', 'group')),
    title           TEXT,
    summary         TEXT,
    visibility      TEXT NOT NULL DEFAULT 'followers'
        CHECK (visibility IN ('followers', 'groups', 'public')),
    group_id        UUID REFERENCES groups(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_activity_feed_actor       ON activity_feed(actor_id);
CREATE INDEX IF NOT EXISTS idx_activity_feed_created_at  ON activity_feed(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_feed_visibility  ON activity_feed(visibility);
CREATE INDEX IF NOT EXISTS idx_activity_feed_group       ON activity_feed(group_id);
