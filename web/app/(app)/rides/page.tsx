export const dynamic = "force-dynamic";

import { createClient } from "@/lib/supabase/server";
import { redirect } from "next/navigation";
import Link from "next/link";
import type { RideSummaryRow, BikeRow } from "@/lib/types";
import { mpsToMph, metersToMiles, secToDisplay } from "@/lib/types";
import { LocalDate } from "@/components/LocalDate";

const RIDE_LIST_DATE_OPTS: Intl.DateTimeFormatOptions = {
  month: "short", day: "numeric", year: "numeric",
};

export default async function RidesPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/auth");

  const [{ data: rides }, { data: bikes }] = await Promise.all([
    supabase.from("rides").select("*").order("started_at", { ascending: false }).limit(1000),
    supabase.from("bikes").select("id, nickname, make, model, year"),
  ]);

  const rideList = (rides ?? []) as RideSummaryRow[];
  const bikeMap = Object.fromEntries(
    ((bikes ?? []) as BikeRow[]).map((b) => [
      b.id,
      b.nickname || `${b.year ?? ""} ${b.make} ${b.model}`.trim(),
    ])
  );

  return (
    <div className="mx-auto max-w-6xl px-4 py-8">
      <h1 className="mb-6 text-2xl font-bold text-[var(--text-primary)]">All Rides</h1>

      {rideList.length === 0 ? (
        <div className="rounded-xl bg-[var(--surface)] p-12 text-center">
          <div className="mb-3 text-4xl">🛣️</div>
          <p className="text-lg font-semibold text-[var(--text-primary)]">No rides yet</p>
          <p className="mt-1 text-[var(--text-secondary)]">
            Record rides in the RaceLine iOS app and enable cloud sync to see them here.
          </p>
        </div>
      ) : (
        <div className="flex flex-col gap-2">
          {rideList.map((ride) => (
            <Link key={ride.id} href={`/rides/${ride.id}`}>
              <div className="flex items-center gap-4 rounded-xl bg-[var(--surface)] px-5 py-4 hover:bg-[var(--surface2)] transition-colors">
                <div className="flex h-10 w-10 flex-shrink-0 items-center justify-center rounded-full bg-[var(--accent)]/15 text-lg">
                  {ride.ride_type === "track" ? "🏁" : "🛣️"}
                </div>
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 flex-wrap">
                    <p className="font-semibold text-[var(--text-primary)] truncate">
                      {ride.name ?? "Unnamed Ride"}
                    </p>
                    {ride.ride_type === "track" && (
                      <span className="rounded-full bg-[var(--accent)]/15 px-2 py-0.5 text-xs font-semibold text-[var(--accent)]">
                        Track
                      </span>
                    )}
                  </div>
                  <p className="text-sm text-[var(--text-secondary)]">
                    {ride.started_at ? <LocalDate iso={ride.started_at} options={RIDE_LIST_DATE_OPTS} /> : "—"}
                    {ride.bike_id && bikeMap[ride.bike_id] && ` · ${bikeMap[ride.bike_id]}`}
                    {ride.tags && ride.tags.length > 0 && ` · ${ride.tags.slice(0, 3).join(", ")}`}
                  </p>
                </div>
                <div className="hidden sm:flex items-center gap-6 text-right flex-shrink-0">
                  <div>
                    <p className="text-sm font-semibold text-[var(--text-primary)] tabular-nums">
                      {metersToMiles(ride.distance_meters).toFixed(1)} mi
                    </p>
                    <p className="text-xs text-[var(--text-ghost)]">{secToDisplay(ride.duration_seconds)}</p>
                  </div>
                  <div>
                    <p className="text-sm font-semibold text-[var(--accent)] tabular-nums">
                      {mpsToMph(ride.max_speed_mps).toFixed(0)} mph
                    </p>
                    <p className="text-xs text-[var(--text-ghost)]">
                      {Math.max(ride.max_right_lean_deg, ride.max_left_lean_deg).toFixed(0)}° lean
                    </p>
                  </div>
                </div>
              </div>
            </Link>
          ))}
        </div>
      )}
    </div>
  );
}
