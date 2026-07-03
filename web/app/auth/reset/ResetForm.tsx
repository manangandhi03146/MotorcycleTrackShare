"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { validatePassword } from "@/lib/passwordPolicy";

export default function ResetForm() {
  const router = useRouter();
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    // Supabase puts the session tokens in the URL hash or as a code param.
    // createClient + onAuthStateChange handles both automatically.
    const supabase = createClient();
    const { data: { subscription } } = supabase.auth.onAuthStateChange((event) => {
      if (event === "PASSWORD_RECOVERY") {
        setReady(true);
      }
    });

    // Also check if there's already a session (code was already exchanged)
    supabase.auth.getSession().then(({ data: { session } }) => {
      if (session) setReady(true);
    });

    return () => subscription.unsubscribe();
  }, []);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (password !== confirm) {
      setError("Passwords don't match.");
      return;
    }
    const policyError = validatePassword(password);
    if (policyError) {
      setError(policyError);
      return;
    }

    setLoading(true);
    setError(null);
    const supabase = createClient();
    const { error } = await supabase.auth.updateUser({ password });
    if (error) {
      setError(error.message);
    } else {
      router.push("/dashboard");
    }
    setLoading(false);
  }

  return (
    <div className="flex min-h-screen flex-col items-center justify-center px-4 py-12">
      <div className="w-full max-w-md">
        <div className="mb-8 text-center">
          <div className="mx-auto mb-4 flex h-20 w-20 items-center justify-center rounded-full bg-[var(--accent)]/15 text-4xl">
            🔑
          </div>
          <h1 className="text-2xl font-bold text-[var(--text-primary)]">Set New Password</h1>
          <p className="mt-1 text-[var(--text-secondary)]">
            {ready ? "Enter your new password below." : "Verifying reset link…"}
          </p>
        </div>

        {ready ? (
          <div className="rounded-2xl bg-[var(--surface)] p-6">
            <form onSubmit={handleSubmit} className="flex flex-col gap-3">
              <input
                type="password"
                placeholder="New password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                required
                autoFocus
                className="rounded-xl border border-[var(--divider)] bg-[var(--surface2)] px-4 py-3 text-[var(--text-primary)] placeholder-[var(--text-ghost)] focus:border-[var(--accent)] focus:outline-none"
              />
              <input
                type="password"
                placeholder="Confirm new password"
                value={confirm}
                onChange={(e) => setConfirm(e.target.value)}
                required
                className="rounded-xl border border-[var(--divider)] bg-[var(--surface2)] px-4 py-3 text-[var(--text-primary)] placeholder-[var(--text-ghost)] focus:border-[var(--accent)] focus:outline-none"
              />
              {error && <p className="text-sm text-red-400">{error}</p>}
              <button
                type="submit"
                disabled={loading}
                className="mt-1 rounded-xl bg-[var(--accent)] py-3.5 text-base font-semibold text-white transition-opacity disabled:opacity-60"
              >
                {loading ? "Saving…" : "Set New Password"}
              </button>
            </form>
          </div>
        ) : (
          <div className="flex justify-center">
            <div className="h-8 w-8 animate-spin rounded-full border-2 border-[var(--accent)] border-t-transparent" />
          </div>
        )}
      </div>
    </div>
  );
}
