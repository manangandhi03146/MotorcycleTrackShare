"use client";

import { useEffect, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { validatePassword } from "@/lib/passwordPolicy";

type OAuthProvider = "google" | "apple";

export default function AuthForm() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const [mode, setMode] = useState<"signin" | "signup" | "forgot">("signin");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [oauthLoading, setOauthLoading] = useState<OAuthProvider | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);

  // Surface errors bounced back from /auth/callback (e.g. provider returned an error).
  useEffect(() => {
    const oauthError = searchParams.get("error");
    if (oauthError) setError(decodeURIComponent(oauthError));
  }, [searchParams]);

  async function handleOAuth(provider: OAuthProvider) {
    setError(null);
    setMessage(null);
    setOauthLoading(provider);

    const supabase = createClient();
    const next = searchParams.get("next") || "/dashboard";
    const redirectTo = `${window.location.origin}/auth/callback?next=${encodeURIComponent(next)}`;

    const { error } = await supabase.auth.signInWithOAuth({
      provider,
      options: { redirectTo },
    });

    if (error) {
      setError(error.message);
      setOauthLoading(null);
    }
    // On success, Supabase redirects the browser — we don't reach the next line.
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);
    setMessage(null);

    const supabase = createClient();
    const trimEmail = email.trim();
    const trimPass = password.trim();

    if (mode === "forgot") {
      const { error } = await supabase.auth.resetPasswordForEmail(trimEmail, {
        redirectTo: `${window.location.origin}/auth/reset`,
      });
      if (error) setError(error.message);
      else setMessage("Check your email for a password reset link.");
      setLoading(false);
      return;
    }

    if (mode === "signup") {
      const policyError = validatePassword(trimPass);
      if (policyError) {
        setError(policyError);
        setLoading(false);
        return;
      }
      const { error } = await supabase.auth.signUp({ email: trimEmail, password: trimPass });
      if (error) setError(friendlyError(error.message));
      else setMessage("Check your email to confirm your account.");
    } else {
      const { error } = await supabase.auth.signInWithPassword({ email: trimEmail, password: trimPass });
      if (error) setError(friendlyError(error.message));
      else router.push("/dashboard");
    }
    setLoading(false);
  }

  function friendlyError(msg: string): string {
    const m = msg.toLowerCase();
    if (m.includes("invalid login credentials") || m.includes("invalid_credentials"))
      return "Incorrect email or password.";
    if (m.includes("email") && m.includes("already"))
      return "An account with this email already exists.";
    if (m.includes("password") && (m.includes("weak") || m.includes("short")))
      return "Password must be at least 12 characters.";
    if (m.includes("network") || m.includes("offline"))
      return "Network error. Check your connection.";
    return "Something went wrong. Please try again.";
  }

  const anyLoading = loading || oauthLoading !== null;

  return (
    <div className="flex min-h-screen flex-col items-center justify-center px-4 py-12">
      <div className="w-full max-w-md">
        <div className="mb-8 text-center">
          <div className="mx-auto mb-4 flex h-20 w-20 items-center justify-center rounded-full bg-[var(--accent)]/15 text-4xl">
            🏍️
          </div>
          <h1 className="text-3xl font-bold text-[var(--text-primary)]">RaceLine</h1>
          <p className="mt-1 text-[var(--text-secondary)]">Telemetry for every ride</p>
        </div>

        <div className="rounded-2xl bg-[var(--surface)] p-6">
          {mode !== "forgot" && (
            <>
              <div className="mb-4 flex flex-col gap-2">
                <AppleButton
                  loading={oauthLoading === "apple"}
                  disabled={anyLoading}
                  onClick={() => handleOAuth("apple")}
                />
                <GoogleButton
                  loading={oauthLoading === "google"}
                  disabled={anyLoading}
                  onClick={() => handleOAuth("google")}
                />
              </div>

              <div className="my-4 flex items-center gap-3">
                <div className="h-px flex-1 bg-[var(--divider)]" />
                <span className="text-xs uppercase tracking-wider text-[var(--text-tertiary)]">
                  or
                </span>
                <div className="h-px flex-1 bg-[var(--divider)]" />
              </div>

              <div className="mb-4 flex rounded-xl bg-[var(--surface2)] p-1">
                {(["signin", "signup"] as const).map((m) => (
                  <button
                    key={m}
                    onClick={() => { setMode(m); setError(null); setMessage(null); }}
                    className={`flex-1 rounded-lg py-2 text-sm font-semibold transition-colors ${
                      mode === m
                        ? "bg-[var(--accent)] text-white"
                        : "text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                    }`}
                  >
                    {m === "signin" ? "Sign In" : "Create Account"}
                  </button>
                ))}
              </div>
            </>
          )}

          {mode === "forgot" && (
            <div className="mb-4">
              <button onClick={() => { setMode("signin"); setError(null); setMessage(null); }}
                className="text-sm text-[var(--accent)] hover:underline"
              >
                ← Back to sign in
              </button>
              <h2 className="mt-2 text-xl font-bold text-[var(--text-primary)]">Reset Password</h2>
              <p className="mt-1 text-sm text-[var(--text-secondary)]">
                Enter your email and we&apos;ll send a reset link.
              </p>
            </div>
          )}

          {message && (
            <div className="mb-4 rounded-xl bg-[var(--accent)]/12 p-3 text-sm text-[var(--text-primary)]">
              {message}
            </div>
          )}

          <form onSubmit={handleSubmit} className="flex flex-col gap-3">
            <input
              type="email"
              placeholder="Email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              required
              className="rounded-xl border border-[var(--divider)] bg-[var(--surface2)] px-4 py-3 text-[var(--text-primary)] placeholder-[var(--text-ghost)] focus:border-[var(--accent)] focus:outline-none"
            />
            {mode !== "forgot" && (
              <input
                type="password"
                placeholder="Password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                required
                className="rounded-xl border border-[var(--divider)] bg-[var(--surface2)] px-4 py-3 text-[var(--text-primary)] placeholder-[var(--text-ghost)] focus:border-[var(--accent)] focus:outline-none"
              />
            )}

            {error && <p className="text-sm text-red-400">{error}</p>}

            <button
              type="submit"
              disabled={anyLoading}
              className="mt-1 rounded-xl bg-[var(--accent)] py-3.5 text-base font-semibold text-white transition-opacity disabled:opacity-60"
            >
              {loading
                ? "…"
                : mode === "signup"
                  ? "Create Account"
                  : mode === "forgot"
                    ? "Send Reset Link"
                    : "Sign In"}
            </button>
          </form>

          {mode === "signin" && (
            <button
              onClick={() => { setMode("forgot"); setError(null); setMessage(null); }}
              className="mt-3 w-full text-center text-sm text-[var(--accent)] hover:underline"
            >
              Forgot password?
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

// MARK: - OAuth buttons

function AppleButton({
  loading,
  disabled,
  onClick,
}: {
  loading: boolean;
  disabled: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className="flex h-12 w-full items-center justify-center gap-2 rounded-xl bg-white text-base font-semibold text-black transition-opacity disabled:opacity-60"
      aria-label="Continue with Apple"
    >
      <AppleLogo />
      <span>{loading ? "Connecting…" : "Continue with Apple"}</span>
    </button>
  );
}

function GoogleButton({
  loading,
  disabled,
  onClick,
}: {
  loading: boolean;
  disabled: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className="flex h-12 w-full items-center justify-center gap-2 rounded-xl border border-[var(--divider)] bg-white text-base font-semibold text-black transition-opacity disabled:opacity-60"
      aria-label="Continue with Google"
    >
      <GoogleLogo />
      <span>{loading ? "Connecting…" : "Continue with Google"}</span>
    </button>
  );
}

function AppleLogo() {
  // SF Symbol-like Apple glyph rendered as SVG (no Apple asset shipped).
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M17.05 12.51c-.02-2.34 1.92-3.47 2.01-3.52-1.1-1.6-2.81-1.82-3.42-1.85-1.46-.15-2.85.86-3.59.86-.74 0-1.88-.84-3.09-.82-1.59.02-3.06.92-3.88 2.34-1.65 2.85-.42 7.07 1.19 9.38.78 1.13 1.71 2.4 2.93 2.36 1.18-.05 1.63-.76 3.06-.76 1.43 0 1.83.76 3.08.74 1.27-.02 2.08-1.15 2.86-2.29.9-1.32 1.27-2.6 1.29-2.67-.03-.01-2.46-.95-2.49-3.77zM14.7 5.74c.65-.79 1.09-1.88.97-2.97-.94.04-2.07.62-2.74 1.41-.6.7-1.13 1.81-.99 2.88 1.04.08 2.11-.53 2.76-1.32z" />
    </svg>
  );
}

function GoogleLogo() {
  // Google's brand four-color G.
  return (
    <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
      <path
        d="M17.64 9.2c0-.637-.057-1.251-.164-1.84H9v3.481h4.844a4.14 4.14 0 01-1.796 2.717v2.258h2.908c1.702-1.567 2.684-3.874 2.684-6.615z"
        fill="#4285F4"
      />
      <path
        d="M9 18c2.43 0 4.467-.806 5.956-2.184l-2.908-2.258c-.806.54-1.837.86-3.048.86-2.344 0-4.328-1.584-5.036-3.711H.957v2.332A8.997 8.997 0 009 18z"
        fill="#34A853"
      />
      <path
        d="M3.964 10.707A5.41 5.41 0 013.682 9c0-.593.102-1.17.282-1.707V4.961H.957A8.996 8.996 0 000 9c0 1.452.348 2.827.957 4.039l3.007-2.332z"
        fill="#FBBC05"
      />
      <path
        d="M9 3.58c1.321 0 2.508.454 3.44 1.345l2.582-2.58C13.463.891 11.426 0 9 0A8.997 8.997 0 00.957 4.961L3.964 7.293C4.672 5.166 6.656 3.58 9 3.58z"
        fill="#EA4335"
      />
    </svg>
  );
}
