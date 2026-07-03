export const dynamic = "force-dynamic";

import { createClient } from "@/lib/supabase/server";
import { redirect } from "next/navigation";
import type { MaintenanceRow, BikeRow } from "@/lib/types";

const typeIcons: Record<string, string> = {
  oilChange: "🛢️",
  chainCleanLube: "🔗",
  chainAdjustment: "🔧",
  tires: "🔘",
  brakePads: "🛑",
  brakeFluid: "💧",
  coolant: "❄️",
  airFilter: "🌬️",
  custom: "🔩",
};

function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
}

function daysSince(iso: string): number {
  return Math.floor((Date.now() - new Date(iso).getTime()) / (1000 * 60 * 60 * 24));
}

export default async function MaintenancePage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/auth");

  const [{ data: records }, { data: bikes }] = await Promise.all([
    supabase.from("maintenance_records").select("*").order("date", { ascending: false }).limit(1000),
    supabase.from("bikes").select("id, nickname, make, model, year"),
  ]);

  const recordList = (records ?? []) as MaintenanceRow[];
  const bikeMap = Object.fromEntries(
    ((bikes ?? []) as BikeRow[]).map((b) => [
      b.id,
      b.nickname ?? `${b.year ?? ""} ${b.make} ${b.model}`.trim(),
    ])
  );

  const active = recordList.filter((r) => !r.is_archived);
  const overdue = active.filter((r) => {
    if (!r.reminder_interval_days) return false;
    return daysSince(r.date) >= r.reminder_interval_days;
  });

  return (
    <div className="mx-auto max-w-6xl px-4 py-8">
      <h1 className="mb-6 text-2xl font-bold text-[var(--text-primary)]">Maintenance</h1>

      {overdue.length > 0 && (
        <div className="mb-6 flex items-start gap-3 rounded-xl bg-orange-500/10 p-4">
          <span className="text-2xl">⚠️</span>
          <div>
            <p className="font-semibold text-orange-300">
              {overdue.length} item{overdue.length !== 1 ? "s" : ""} overdue
            </p>
            <p className="text-sm text-orange-300/70">
              {overdue.map((r) => r.title).join(", ")}
            </p>
          </div>
        </div>
      )}

      {active.length === 0 ? (
        <div className="rounded-xl bg-[var(--surface)] p-12 text-center">
          <div className="mb-3 text-4xl">🔧</div>
          <p className="text-lg font-semibold text-[var(--text-primary)]">No maintenance records</p>
          <p className="mt-1 text-[var(--text-secondary)]">
            Log service records in the RaceLine iOS app to track your bike's health.
          </p>
        </div>
      ) : (
        <div className="flex flex-col gap-2">
          {active.map((record) => {
            const isDue = record.reminder_interval_days
              ? daysSince(record.date) >= record.reminder_interval_days
              : false;
            const daysUntilDue = record.reminder_interval_days
              ? record.reminder_interval_days - daysSince(record.date)
              : null;

            return (
              <div
                key={record.id}
                className={`flex items-start gap-4 rounded-xl p-4 ${
                  isDue ? "bg-orange-500/8 border border-orange-500/20" : "bg-[var(--surface)]"
                }`}
              >
                <div className={`flex h-10 w-10 flex-shrink-0 items-center justify-center rounded-full text-xl ${
                  isDue ? "bg-orange-500/15" : "bg-[var(--surface2)]"
                }`}>
                  {typeIcons[record.type] ?? "🔩"}
                </div>
                <div className="flex-1 min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <p className="font-semibold text-[var(--text-primary)]">{record.title}</p>
                    {isDue && (
                      <span className="rounded-full bg-red-500 px-2 py-0.5 text-xs font-semibold text-white">
                        Overdue
                      </span>
                    )}
                    {!isDue && daysUntilDue !== null && daysUntilDue <= 14 && (
                      <span className="rounded-full bg-orange-500/20 px-2 py-0.5 text-xs font-semibold text-orange-300">
                        Due in {daysUntilDue}d
                      </span>
                    )}
                  </div>
                  <p className="text-sm text-[var(--text-secondary)]">
                    {formatDate(record.date)}
                    {record.bike_id && bikeMap[record.bike_id] && ` · ${bikeMap[record.bike_id]}`}
                    {record.odometer_miles && ` · ${record.odometer_miles.toFixed(0)} mi`}
                  </p>
                  {record.notes && (
                    <p className="mt-1 text-sm text-[var(--text-ghost)] line-clamp-2">{record.notes}</p>
                  )}
                </div>
                {daysUntilDue !== null && !isDue && (
                  <div className="flex-shrink-0 text-right">
                    <p className="text-xs text-[var(--text-ghost)]">due in</p>
                    <p className="text-sm font-semibold text-[var(--text-secondary)]">{daysUntilDue}d</p>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
