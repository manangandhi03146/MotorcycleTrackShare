-- ============================================================
-- RaceLine — Migration 018: Avatar storage
-- Run AFTER 017_social_polish.sql
--
-- Creates the `avatars` PUBLIC bucket + write-only-by-owner policies.
--
-- Public buckets serve their objects at
--   {supabase_url}/storage/v1/object/public/avatars/{path}
-- without needing a broad SELECT policy. We DO grant SELECT scoped
-- to the owner because Supabase Storage does `INSERT ... RETURNING *`
-- when the app uploads, and that RETURNING is subject to the SELECT
-- USING clause. Without an owner-scoped SELECT policy the upload
-- fails with "new row violates row-level security policy for objects".
-- Scoping the SELECT to the owner still prevents `list()` from
-- enumerating other users' avatars.
--
-- Storage path convention:
--   {user_id}/avatar.jpg
-- ============================================================

INSERT INTO storage.buckets (id, name, public)
VALUES ('avatars', 'avatars', TRUE)
ON CONFLICT (id) DO UPDATE SET public = EXCLUDED.public;

DROP POLICY IF EXISTS "avatars: signed-in can read"       ON storage.objects;
DROP POLICY IF EXISTS "avatars: users read own avatar"    ON storage.objects;
DROP POLICY IF EXISTS "avatars: users upload own avatar"  ON storage.objects;
DROP POLICY IF EXISTS "avatars: users update own avatar"  ON storage.objects;
DROP POLICY IF EXISTS "avatars: users delete own avatar"  ON storage.objects;

CREATE POLICY "avatars: users read own avatar"
    ON storage.objects FOR SELECT
    TO authenticated
    USING (
        bucket_id = 'avatars'
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

CREATE POLICY "avatars: users upload own avatar"
    ON storage.objects FOR INSERT
    TO authenticated
    WITH CHECK (
        bucket_id = 'avatars'
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

CREATE POLICY "avatars: users update own avatar"
    ON storage.objects FOR UPDATE
    TO authenticated
    USING (
        bucket_id = 'avatars'
        AND (storage.foldername(name))[1] = auth.uid()::text
    )
    WITH CHECK (
        bucket_id = 'avatars'
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

CREATE POLICY "avatars: users delete own avatar"
    ON storage.objects FOR DELETE
    TO authenticated
    USING (
        bucket_id = 'avatars'
        AND (storage.foldername(name))[1] = auth.uid()::text
    );
