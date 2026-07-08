/**
 * Client-side password policy for signup and reset.
 *
 * This mirrors — and should stay in sync with — the server-side policy in
 * Supabase Auth (Dashboard → Authentication → Providers → Email):
 * set "Minimum password length" to 12 and enable leaked-password protection
 * there so the policy is enforced server-side, not just here.
 */

const MIN_LENGTH = 12;
const MAX_LENGTH = 128;

// Small blocklist of patterns that satisfy the length rule but are still
// trivially guessable. The 12-char minimum already eliminates almost all of
// the classic top-10k weak passwords.
const WEAK_SUBSTRINGS = [
  "password",
  "raceline",
  "motorcycle",
  "qwertyuiop",
  "1234567890",
  "iloveyou",
  "letmein",
];

export function validatePassword(password: string): string | null {
  if (password.length < MIN_LENGTH) {
    return `Password must be at least ${MIN_LENGTH} characters. A short sentence works well.`;
  }
  if (password.length > MAX_LENGTH) {
    return `Password must be ${MAX_LENGTH} characters or fewer.`;
  }
  const lower = password.toLowerCase();
  for (const weak of WEAK_SUBSTRINGS) {
    if (lower.includes(weak)) {
      return "That password is too easy to guess. Avoid common words like “password” or the app name.";
    }
  }
  // All one repeated character (e.g. "aaaaaaaaaaaa") or simple repeats.
  if (/^(.)\1+$/.test(password)) {
    return "That password is too repetitive. Mix in some different characters.";
  }
  return null;
}
