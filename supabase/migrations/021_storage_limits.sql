-- 021_storage_limits.sql
-- Defense-in-depth limits on Storage buckets (audit prompts 91/92).
--
-- NOT YET APPLIED to the live database — generated during a security audit
-- while v1.0 is in App Review. Review, confirm the bucket ids match your
-- project, then apply with `supabase db push` or the dashboard SQL editor.
--
-- The iOS client already re-encodes every upload to image/jpeg and strips GPS
-- EXIF, so stored objects are always valid images. These bucket-level caps add
-- a server-side backstop: an oversized or wrong-type object is rejected by
-- Storage even if a client is modified or bypassed.
--
-- file_size_limit is a hard cap (bytes). allowed_mime_types restricts uploads
-- by declared content type. Only buckets known to hold images are MIME-locked;
-- the telemetry bucket keeps a size cap without a MIME restriction.

-- Photo buckets: cap at 15 MB, images only.
UPDATE storage.buckets
SET file_size_limit = 15728640,  -- 15 MB
    allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/heic', 'image/webp']
WHERE id IN ('avatars', 'ride-photos', 'bike-photos', 'maintenance-photos', 'moto-media');

-- Telemetry bucket: cap at 50 MB (JSON-lines can be large); no MIME lock.
UPDATE storage.buckets
SET file_size_limit = 52428800  -- 50 MB
WHERE id = 'ride-telemetry';
