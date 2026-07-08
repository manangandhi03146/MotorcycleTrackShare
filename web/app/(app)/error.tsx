"use client";

export default function AppError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <div className="flex min-h-[60vh] flex-col items-center justify-center gap-4 px-4 text-center">
      <div className="text-4xl">⚠️</div>
      <h2 className="text-xl font-bold text-[var(--text-primary)]">Something went wrong</h2>
      <p className="max-w-md text-sm text-[var(--text-secondary)]">
        An unexpected error occurred. Please try again.
      </p>
      {/* Show only the opaque digest, never the raw error message, so internal
          details / stack context are not surfaced to users. */}
      {error.digest && (
        <p className="text-xs text-[var(--text-ghost)]">Error ID: {error.digest}</p>
      )}
      <button
        onClick={reset}
        className="mt-2 rounded-lg bg-[var(--accent)] px-4 py-2 text-sm font-semibold text-white"
      >
        Try again
      </button>
    </div>
  );
}
