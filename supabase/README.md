# RaceLine — Supabase Setup

This directory contains all database migrations, RLS policies, storage policies, and Edge Functions for the RaceLine backend.

---

## Setup Order

Run in this exact order:

1. `migrations/001_schema.sql` — Creates all tables and triggers
2. `migrations/002_rls_policies.sql` — Enables RLS and creates access policies
3. `migrations/003_storage_policies.sql` — Creates storage bucket policies
4. `migrations/004_trigger_hardening.sql` — Hardens auth trigger for OAuth flows
5. `migrations/005_cloud_ride_limit.sql` — Adds the 10-ride free cloud cap
6. `migrations/006_social.sql` — Phase 3: groups, challenges, follows, shared routes, activity feed, privacy
7. `migrations/007_social_rls.sql` — RLS policies + helper functions for Phase 3
8. `migrations/008_group_ownership_limit.sql` — Enforce 5-group free ownership cap via trigger
9. `migrations/009_group_owner_default.sql` — Sets DEFAULT auth.uid() on groups.owner_id and re-seeds the INSERT policy (fixes a 42501 that could occur if 007 didn't fully apply)
10. `migrations/010_create_group_rpc.sql` — Adds a SECURITY DEFINER `create_group` RPC that the client uses instead of a direct INSERT (bypasses the RLS puzzle we hit on the direct path)
11. `migrations/011_create_group_bypass_rls.sql` — Adds `SET row_security = off` to the create_group RPC so RLS is disabled inside its execution scope (fixes 42501 that persisted through migration 010 on some Supabase Cloud projects)
12. `migrations/012_group_owner_trigger.sql` — Trigger-based fallback: BEFORE INSERT trigger forces owner_id := auth.uid(), INSERT policy simplifies to authenticated-only. The app now uses a direct INSERT (no RPC), so PostgREST schema-cache issues stop blocking group creation.
13. `migrations/013_group_insert_policy_public.sql` — Rescopes the groups INSERT policy from `TO authenticated` to `TO public` (with `auth.uid() IS NOT NULL` inside WITH CHECK). Diagnosed after seeing PostgREST-mediated INSERTs fail RLS despite a `WITH CHECK (TRUE)` policy — the role clause wasn't matching for reasons we couldn't identify. Same practical effect (signed-in-only insertion via the trigger + WITH CHECK), just doesn't rely on the connection role name.
14. `migrations/014_groups_full_reset.sql` — **Idempotent full reset of `groups` + `group_members`**: wipes every leftover policy/trigger/function from 006–013, re-grants table privileges to `authenticated`/`service_role`, and rebuilds the whole stack from scratch. Run this any time group creation is misbehaving — it supersedes everything above for these two tables.
15. `migrations/015_groups_fix_recursion.sql` — Fixes 42P17 "infinite recursion detected in policy" by moving every cross-row membership check into SECURITY DEFINER helper functions (`is_group_member`, `is_group_admin`, `is_group_public`) with `row_security = off`. The policies now call the helpers instead of doing inline `EXISTS FROM group_members`, which would otherwise re-trigger the policy on the inner SELECT.
16. `migrations/016_groups_select_owner.sql` — Adds `owner_id = auth.uid()` to the `groups_select_visible` policy so the RETURNING read from `.insert().select().single()` succeeds for private groups the caller just created. This is the migration that finally unblocked group creation end-to-end.
17. `migrations/017_social_polish.sql` — Feed + groups + challenge leaderboard polish: (a) adds `bikeAdded` to the allowed `activity_feed.kind` values plus `bike` as a subject kind; (b) adds an AFTER DELETE trigger on `group_members` that auto-deletes empty groups and transfers ownership to the longest-tenured remaining member when the owner leaves; (c) adds a `mutual_follows(a, b)` helper + SELECT policy so a rider can see their mutual followers' progress on the challenge leaderboard and see mutual followers' profiles in the Riders list.
18. `migrations/018_avatar_storage.sql` — Creates the `avatars` PUBLIC bucket + owner-only write policies. Reads are handled by the bucket's `public = TRUE` flag (URLs work without a SELECT policy) — we intentionally do not grant SELECT so clients can't enumerate everyone's avatars via `list()`.
19. `migrations/019_group_rides_phase4.sql` — Phase 4 group ride navigation. Extends `group_rides` with destination/waypoints/status/visibility/live_location_enabled, adds `group_ride_participants` and `group_ride_live_locations` tables, and adds `rides.group_ride_id` for post-ride linkage. RLS gates ride visibility by group membership, participants by group membership, and live locations by participation. Also adds an AFTER INSERT trigger on `group_rides` so the creator is auto-joined as a participant.

Then:
20. Create storage buckets manually (see below)
21. Deploy Edge Functions (see below)
22. Configure Auth redirect URLs (see below)

---

## Storage Buckets

Create these **private** buckets in Supabase Dashboard → Storage:

| Bucket | Purpose |
|---|---|
| `ride-photos` | Ride cover photos |
| `bike-photos` | Bike profile photos |
| `ride-telemetry` | Raw JSONL telemetry files |
| `maintenance-photos` | Maintenance receipt photos |

**All buckets must be private (not public).** The storage policies in `003_storage_policies.sql` enforce per-user access.

Storage path convention:
```
{user_id}/rides/{ride_id}/photo.jpg
{user_id}/rides/{ride_id}/telemetry.jsonl
{user_id}/bikes/{bike_id}/photo.jpg
{user_id}/maintenance/{record_id}/receipt.jpg
```

---

## Edge Functions

### delete-account

Deletes all user data including database rows and storage objects, then deletes the auth user.

**Deploy:**
```bash
supabase functions deploy delete-account
```

**Required environment variables** (set in Supabase Dashboard → Edge Functions → Secrets):
```
SUPABASE_SERVICE_ROLE_KEY=your_service_role_key
```

> The service role key is a privileged key that bypasses RLS. It must NEVER be exposed to iOS or web clients. Only use it in Edge Functions.

---

## Auth Configuration

In Supabase Dashboard → Authentication → URL Configuration:

**Site URL:**
```
https://YOUR_DOMAIN.com
```

**Redirect URLs (add all):**
```
https://YOUR_DOMAIN.com/auth/callback
http://localhost:3000/auth/callback
tread://auth/callback
```

- `http://localhost:3000/auth/callback` — for local web development only
- `https://YOUR_DOMAIN.com/auth/callback` — for production web
- `tread://auth/callback` — for iOS deep link (password reset, email confirmation)

**Before going to production:** Remove the `localhost` redirect URL and replace `YOUR_DOMAIN.com` with your actual domain.

---

## Schema Overview

### profiles
User settings and preferences. Auto-created on signup via trigger.

Key fields: `preferred_units`, `default_storage_mode`, `hide_route_by_default`, `route_hide_distance_miles`, `cloud_sync_paused`, `sampling_rate_hz`

### bikes
User's motorcycles. `local_id` links to the iOS-side UUID for deduplication.

Key fields: `nickname`, `make`, `model`, `year`, `is_default`, `is_archived`, `photo_path`

### rides
Ride summaries + metadata. Raw telemetry is stored as a file in `ride-telemetry` storage, not as rows.

Key fields: `ride_type` (street/track), `storage_mode`, `has_full_telemetry`, `tags[]`, `visibility` (private by default)

### maintenance_records
Maintenance history per bike.

Key fields: `type`, `title`, `date`, `reminder_interval_days`, `reminder_interval_miles`

### deletion_requests
Tracks account deletion requests for audit/fallback if Edge Function fails.

---

## RLS Summary

All tables use `user_id = auth.uid()` for access control. Users can only see and modify their own data. The `visibility` field on rides is reserved for future public sharing but is private by default and has no SELECT policy for anonymous users yet.

---

## Development Tips

Use the Supabase CLI for local development:

```bash
# Start local Supabase
supabase start

# Run migrations
supabase db reset

# Deploy functions
supabase functions serve
```
