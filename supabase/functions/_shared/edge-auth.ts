// Shared in-body auth gate for privileged `--no-verify-jwt` edge functions.
//
// WHY in-body (not verify_jwt): these functions are called by other edge
// functions with the SERVICE ROLE key and by webhooks/telephony that carry no
// end-user JWT, so they must stay --no-verify-jwt. But that also means the anon
// publishable key (public) passes verify_jwt — it is NOT an identity. So a
// function that runs privileged work with the service-role client (RLS off)
// MUST authenticate the CALLER in-body, or it is an open, RLS-exempt endpoint.
//
// Legitimate callers of the privileged surface are exactly:
//   1. Internal edge functions  → Bearer <SERVICE_ROLE_KEY>
//   2. The admin UI             → Bearer <admin session JWT> (functions.invoke,
//      or a raw fetch that sends supabase.auth.getSession().access_token)
// Anon/publishable keys are rejected.
//
// Reference implementations this consolidates: newsletter/send, signal-ingest,
// create-user, and the inline gates in agent-execute + federation-invite-peer.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export interface EdgeAuth {
  authorized: boolean;
  isService: boolean;
  isAdmin: boolean;
  userId: string | null;
}

/**
 * Authorize a request as either the service role or a user holding `role`.
 * Pass a SERVICE-ROLE supabase client (needs auth.getUser + has_role).
 */
export async function requireServiceOrRole(
  req: Request,
  supabase: SupabaseClient,
  role: string = "admin",
): Promise<EdgeAuth> {
  const token = (req.headers.get("authorization") ?? "")
    .replace(/^Bearer\s+/i, "")
    .trim();
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const publishableKey = Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ?? "";

  if (token && serviceKey && token === serviceKey) {
    return { authorized: true, isService: true, isAdmin: false, userId: null };
  }
  // A JWT that is NOT the anon/publishable key — try to resolve a user + role.
  if (token && token !== anonKey && token !== publishableKey) {
    const { data } = await supabase.auth.getUser(token);
    if (data?.user) {
      const { data: hasRole } = await supabase.rpc("has_role", {
        _user_id: data.user.id,
        _role: role,
      });
      if (hasRole) {
        return { authorized: true, isService: false, isAdmin: true, userId: data.user.id };
      }
    }
  }
  return { authorized: false, isService: false, isAdmin: false, userId: null };
}

/** Convenience 401 response with CORS headers. */
export function unauthorized(corsHeaders: Record<string, string>): Response {
  return new Response(JSON.stringify({ error: "Unauthorized" }), {
    status: 401,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
