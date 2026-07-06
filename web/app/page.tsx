import Image from "next/image";
import Link from "next/link";

const features = [
  {
    num: "01",
    title: "Street & track modes",
    desc: "Separate logging profiles: one for Sunday roads, one for session days.",
  },
  {
    num: "02",
    title: "Lean angle",
    desc: "Live left and right lean from your phone’s gyroscope, with your session max.",
  },
  {
    num: "03",
    title: "Ride analytics",
    desc: "Speed, distance, elevation, and hard-braking events for every ride.",
  },
  {
    num: "04",
    title: "Multi-bike garage",
    desc: "Every bike you own, with per-bike stats and full service history.",
  },
  {
    num: "05",
    title: "Maintenance log",
    desc: "Oil, tires, chain: logged with reminders before they’re due.",
  },
  {
    num: "06",
    title: "Web dashboard",
    desc: "Every ride on a bigger screen, synced through your Apple or Google sign-in.",
  },
];

const sessionStats = [
  { label: "Session", value: "22:41", accent: false },
  { label: "Distance", value: "64 mi", accent: false },
  { label: "Top speed", value: "121 mph", accent: false },
  { label: "Max lean", value: "54°", accent: true },
];

export default function LandingPage() {
  return (
    <div className="flex min-h-screen flex-col">
      {/* Header, floating over the hero photo */}
      <header className="absolute inset-x-0 top-0 z-20">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-6 py-5">
          <span className="font-display text-xl font-bold uppercase tracking-[0.08em] text-[var(--text-primary)]">
            RaceLine
          </span>
          <nav className="flex items-center gap-6">
            <Link
              href="/privacy"
              className="text-sm text-[var(--text-primary)]/70 transition-colors hover:text-[var(--text-primary)]"
            >
              Privacy
            </Link>
            <Link
              href="/auth"
              className="rounded-[10px] border border-[var(--text-primary)]/25 px-4 py-2 text-sm font-semibold text-[var(--text-primary)] transition-colors hover:border-[var(--text-primary)]/60"
            >
              Sign in
            </Link>
          </nav>
        </div>
      </header>

      {/* Hero */}
      <section className="relative flex min-h-[92svh] flex-col justify-end">
        <Image
          src="/hero-ride.jpg"
          alt="Rider in black leathers leaning an ember-orange motorcycle through a mountain corner"
          fill
          priority
          sizes="100vw"
          className="object-cover object-center"
        />
        <div className="absolute inset-0 bg-gradient-to-r from-[#181818]/90 via-[#181818]/45 to-[#181818]/10" />
        <div className="absolute inset-x-0 bottom-0 h-2/3 bg-gradient-to-t from-[#181818] via-[#181818]/40 to-transparent" />

        <div className="relative mx-auto w-full max-w-6xl px-6 pb-16 pt-40">
          <h1 className="rise font-display text-[clamp(3.75rem,9vw,8rem)] font-bold uppercase leading-[0.92] tracking-tight text-[var(--text-primary)]">
            Find your line.
            <br />
            <span className="text-[var(--accent)]">Every ride.</span>
          </h1>
          <p className="rise rise-2 mt-6 max-w-xl text-lg leading-relaxed text-[var(--text-primary)]/75">
            RaceLine records speed, lean angle, route, and elevation from the
            phone already in your pocket. Ride, stop, and post a share card
            you’re proud of before your gloves are off.
          </p>
          <div className="rise rise-3 mt-9 flex flex-wrap items-center gap-6">
            <Link
              href="/auth"
              className="flex h-[52px] items-center rounded-[14px] bg-[var(--accent)] px-8 text-base font-semibold text-white transition-colors hover:bg-[var(--accent)]/90"
            >
              Start free
            </Link>
            <Link
              href="/privacy"
              className="text-base font-medium text-[var(--text-primary)]/70 underline decoration-[var(--divider)] underline-offset-4 transition-colors hover:text-[var(--text-primary)]"
            >
              See how privacy works
            </Link>
          </div>
        </div>
      </section>

      {/* Session telemetry strip */}
      <section
        aria-label="Sample session telemetry"
        className="border-y border-[var(--divider)] bg-[var(--surface)]"
      >
        <div className="mx-auto grid max-w-6xl grid-cols-2 lg:grid-cols-4">
          {sessionStats.map((s) => (
            <div
              key={s.label}
              className="px-6 py-7 lg:border-l lg:border-[var(--divider)] lg:first:border-l-0"
            >
              <div className="text-xs uppercase tracking-[0.14em] text-[var(--text-secondary)]">
                {s.label}
              </div>
              <div
                className={`mt-1 font-display text-4xl font-semibold ${
                  s.accent ? "text-[var(--accent)]" : "text-[var(--text-primary)]"
                }`}
              >
                {s.value}
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* Share card showcase */}
      <section className="mx-auto grid w-full max-w-6xl items-center gap-16 px-6 py-24 lg:grid-cols-[1fr_minmax(0,400px)] lg:py-32">
        <div>
          <h2 className="font-display text-5xl font-bold uppercase leading-none tracking-tight text-[var(--text-primary)] sm:text-6xl">
            The ride,
            <br />
            told right.
          </h2>
          <p className="mt-6 max-w-lg text-lg leading-relaxed text-[var(--text-secondary)]">
            Every session ends in a share card: your photo, your route drawn
            over it, and the numbers that mattered. Built to be posted, not
            screenshotted.
          </p>
          <p className="mt-4 max-w-lg text-lg leading-relaxed text-[var(--text-secondary)]">
            Pick the shot, pick the stats, and it’s on your feed while the
            engine is still ticking.
          </p>
        </div>

        {/* Share card mock: photo, route overlay, floating stats */}
        <div className="relative mx-auto w-full max-w-[380px] -rotate-2">
          <div className="relative aspect-[4/5] overflow-hidden rounded-2xl">
            <Image
              src="/share-forest.jpg"
              alt="Naked bike parked on a forest road, the kind of shot a share card is made from"
              fill
              sizes="(min-width: 1024px) 400px, 90vw"
              className="object-cover"
            />
            <div className="absolute inset-x-0 bottom-0 h-1/2 bg-gradient-to-t from-[#181818]/90 to-transparent" />
            <svg
              viewBox="0 0 100 125"
              aria-hidden="true"
              className="absolute inset-0 h-full w-full"
            >
              <path
                d="M 76 14 C 58 24, 84 34, 66 44 C 52 51, 32 50, 35 63 C 38 75, 68 72, 64 84 C 61 93, 42 94, 40 104"
                fill="none"
                stroke="var(--accent)"
                strokeWidth="1.6"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
              <circle cx="76" cy="14" r="2" fill="var(--text-primary)" />
              <circle cx="40" cy="104" r="2" fill="var(--accent)" />
            </svg>
            <div className="absolute inset-x-0 top-0 flex items-center justify-between p-5">
              <span className="font-display text-xs font-semibold uppercase tracking-[0.2em] text-[var(--text-primary)]/85">
                RaceLine
              </span>
              <span className="text-xs font-medium text-[var(--text-primary)]/70">
                JUN 22
              </span>
            </div>
            <div className="absolute inset-x-0 bottom-0 p-5">
              <div className="font-display text-2xl font-semibold text-[var(--text-primary)]">
                Forest loop, Sunday
              </div>
              <div className="mt-3 flex gap-6">
                {[
                  { v: "54°", l: "Max lean" },
                  { v: "61 mi", l: "Distance" },
                  { v: "1:42", l: "Time" },
                ].map((s) => (
                  <div key={s.l}>
                    <div className="font-display text-xl font-semibold text-[var(--text-primary)]">
                      {s.v}
                    </div>
                    <div className="text-[10px] uppercase tracking-[0.14em] text-[var(--text-primary)]/60">
                      {s.l}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Feature spec sheet */}
      <section className="border-y border-[var(--divider)] bg-[var(--surface)]">
        <div className="mx-auto grid max-w-6xl gap-14 px-6 py-24 lg:grid-cols-[minmax(0,360px)_1fr] lg:gap-20">
          <div className="lg:sticky lg:top-24 lg:self-start">
            <h2 className="font-display text-5xl font-bold uppercase leading-none tracking-tight text-[var(--text-primary)]">
              Built for
              <br />
              the ride
            </h2>
            <p className="mt-6 text-lg leading-relaxed text-[var(--text-secondary)]">
              No dashboards, no spreadsheets. RaceLine keeps the numbers that
              make you better and the records that keep your bike healthy.
            </p>
          </div>
          <div>
            {features.map((f) => (
              <div
                key={f.num}
                className="grid grid-cols-[3.5rem_1fr] gap-4 border-b border-[var(--divider)] py-6 first:border-t"
              >
                <span className="font-display text-lg font-semibold text-[var(--text-ghost)]">
                  {f.num}
                </span>
                <div>
                  <h3 className="text-lg font-semibold text-[var(--text-primary)]">
                    {f.title}
                  </h3>
                  <p className="mt-1 text-[var(--text-secondary)]">{f.desc}</p>
                </div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Privacy */}
      <section className="mx-auto w-full max-w-6xl px-6 py-24 lg:py-32">
        <h2 className="font-display text-5xl font-bold uppercase leading-none tracking-tight text-[var(--text-primary)] sm:text-6xl">
          Your route is yours.
        </h2>
        <div className="mt-10 grid max-w-4xl gap-10 md:grid-cols-2">
          <p className="text-lg leading-relaxed text-[var(--text-secondary)]">
            By default, RaceLine syncs summaries only: speed, distance, lean.
            The exact GPS trace of where you rode stays on your phone unless
            you turn on full-route sync yourself.
          </p>
          <p className="text-lg leading-relaxed text-[var(--text-secondary)]">
            Sign in with Apple or Google. No passwords to reuse, and none for
            us to leak.
          </p>
        </div>
        <Link
          href="/privacy"
          className="mt-8 inline-block font-semibold text-[var(--accent)] hover:underline"
        >
          Read the full privacy policy
        </Link>
      </section>

      {/* Closing call, ember drench */}
      <section className="bg-[var(--accent)]">
        <div className="mx-auto flex max-w-6xl flex-col gap-10 px-6 py-20 lg:flex-row lg:items-end lg:justify-between lg:py-24">
          <div>
            <h2 className="font-display text-6xl font-bold uppercase leading-[0.95] tracking-tight text-[#181818] sm:text-7xl">
              Ready when
              <br />
              you are.
            </h2>
            <p className="mt-5 text-lg font-medium text-[#181818]/80">
              Free on iPhone, web dashboard included.
            </p>
          </div>
          <Link
            href="/auth"
            className="flex h-[52px] w-fit items-center rounded-[14px] bg-[#181818] px-8 text-base font-semibold text-[var(--text-primary)] transition-colors hover:bg-[#242424]"
          >
            Start free
          </Link>
        </div>
      </section>

      {/* Footer */}
      <footer className="px-6 py-10">
        <div className="mx-auto flex max-w-6xl flex-col items-center gap-4 sm:flex-row sm:justify-between">
          <span className="font-display text-base font-bold uppercase tracking-[0.08em] text-[var(--text-primary)]">
            RaceLine
          </span>
          <div className="flex gap-6 text-sm text-[var(--text-ghost)]">
            <Link href="/privacy" className="transition-colors hover:text-[var(--text-secondary)]">
              Privacy Policy
            </Link>
            <Link href="/auth" className="transition-colors hover:text-[var(--text-secondary)]">
              Sign in
            </Link>
            <span>© 2026 RaceLine</span>
          </div>
        </div>
      </footer>
    </div>
  );
}
