export const dynamic = "force-dynamic";

import { createClient } from "@/lib/supabase/server";
import { notFound } from "next/navigation";
import Link from "next/link";
import type { RideSummaryRow, BikeRow } from "@/lib/types";
import { mpsToMph, metersToMiles, secToDisplay } from "@/lib/types";

function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString("en-US", {
    weekday: "long", month: "long", day: "numeric", year: "numeric",
  });
}

export default async function SharePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  // This is a PUBLIC page. Select only the display columns the share card
  // renders — never "*" — so raw telemetry paths, storage keys, user_id, and
  // internal flags can't be exposed here even if row visibility is ever
  // broadened. (Today RLS still scopes rides to their owner.)
  const { data: rideData } = await supabase
    .from("rides")
    .select(
      "name, started_at, ride_type, bike_id, distance_meters, duration_seconds, max_speed_mps, max_right_lean_deg, max_left_lean_deg, tags, notes"
    )
    .eq("id", id)
    .single();

  if (!rideData) notFound();
  const ride = rideData as RideSummaryRow;

  let bike: BikeRow | null = null;
  if (ride.bike_id) {
    const { data } = await supabase
      .from("bikes")
      .select("nickname, year, make, model")
      .eq("id", ride.bike_id)
      .single();
    bike = data as BikeRow | null;
  }

  const maxLean = Math.max(ride.max_right_lean_deg, ride.max_left_lean_deg);
  const bikeName = bike
    ? bike.nickname || `${[bike.year, bike.make, bike.model].filter(Boolean).join(" ")}`
    : null;

  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-[var(--bg)] px-4 py-12">
      {/* Share card */}
      <div className="w-full max-w-md overflow-hidden rounded-2xl bg-[var(--surface)] shadow-2xl">
        {/* Header stripe */}
        <div className="bg-gradient-to-r from-[var(--accent)] to-orange-600 px-6 py-5">
          <div className="flex items-center gap-3">
            <span className="text-3xl">{ride.ride_type === "track" ? "🏁" : "🛣️"}</span>
            <div>
              <p className="text-lg font-bold text-white">{ride.name ?? "Ride"}</p>
              <p className="text-sm text-orange-100">{ride.started_at ? formatDate(ride.started_at) : "—"}</p>
            </div>
          </div>
          {bikeName && (
            <p className="mt-2 text-sm font-medium text-orange-100">🏍️ {bikeName}</p>
          )}
        </div>

        {/* Stats */}
        <div className="grid grid-cols-2 gap-px bg-[var(--divider)]">
          {[
            { label: "Distance", value: `${metersToMiles(ride.distance_meters).toFixed(1)} mi` },
            { label: "Duration", value: secToDisplay(ride.duration_seconds) },
            { label: "Max Speed", value: `${mpsToMph(ride.max_speed_mps).toFixed(0)} mph` },
            { label: "Max Lean", value: `${maxLean.toFixed(1)}°` },
          ].map((s) => (
            <div key={s.label} className="bg-[var(--surface)] p-5">
              <p className="text-xs font-semibold uppercase tracking-widest text-[var(--text-ghost)]">{s.label}</p>
              <p className="mt-1 text-2xl font-bold tabular-nums text-[var(--accent)]">{s.value}</p>
            </div>
          ))}
        </div>

        {/* Tags */}
        {ride.tags && ride.tags.length > 0 && (
          <div className="flex flex-wrap gap-2 px-5 py-4">
            {ride.tags.map((tag) => (
              <span key={tag} className="rounded-full bg-[var(--surface2)] px-3 py-1 text-xs text-[var(--text-secondary)]">
                #{tag}
              </span>
            ))}
          </div>
        )}

        {ride.notes && (
          <div className="border-t border-[var(--divider)] px-5 py-4">
            <p className="text-sm text-[var(--text-secondary)] italic">"{ride.notes}"</p>
          </div>
        )}

        {/* Footer */}
        <div className="border-t border-[var(--divider)] px-5 py-4 flex items-center justify-between">
          <span className="text-xs text-[var(--text-ghost)]">Shared via RaceLine</span>
          <Link href="/" className="text-xs font-semibold text-[var(--accent)] hover:underline">
            Get the app →
          </Link>
        </div>
      </div>
    </div>
  );
}
