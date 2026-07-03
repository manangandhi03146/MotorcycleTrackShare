import { NextResponse, type NextRequest } from "next/server";
import { createServerClient } from "@supabase/ssr";

/**
 * Supabase OAuth callback. Receives `?code=<authorization-code>` after the
 * provider (Apple / Google) redirects back through the Supabase hosted
 * callback. We swap the code for a session, attach the resulting auth
 * cookies to the redirect response (not the request's cookie store —
 * `NextResponse.redirect` won't carry those over), then bounce the user
 * to `?next=` (or `/dashboard`).
 *
 * Errors land on `/auth?error=<message>` so AuthForm can surface them.
 */
export async function GET(request: NextRequest) {
  const { searchParams, origin } = new URL(request.url);
  const code = searchParams.get("code");
  const next = searchParams.get("next") || "/dashboard";
  const oauthError = searchParams.get("error_description") || searchParams.get("error");

  if (oauthError) {
    return NextResponse.redirect(`${origin}/auth?error=${encodeURIComponent(oauthError)}`);
  }

  if (!code) {
    return NextResponse.redirect(`${origin}/auth?error=${encodeURIComponent("Missing authorization code")}`);
  }

  // Only allow same-origin redirects. Must start with a single "/" — reject
  // protocol-relative ("//evil.com") and backslash ("/\evil.com") forms that
  // browsers resolve to an external host.
  const safeNext =
    next.startsWith("/") && !next.startsWith("//") && !next.startsWith("/\\")
      ? next
      : "/dashboard";
  const response = NextResponse.redirect(`${origin}${safeNext}`);

  // Important: the Supabase server client must write cookies to *this*
  // response object so they survive the redirect.
  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options)
          );
        },
      },
    }
  );

  const { error } = await supabase.auth.exchangeCodeForSession(code);
  if (error) {
    return NextResponse.redirect(`${origin}/auth?error=${encodeURIComponent(error.message)}`);
  }

  return response;
}
