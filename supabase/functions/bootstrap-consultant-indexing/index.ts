import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

/**
 * Bootstrap the consultant background-indexing cron job on the *current*
 * Supabase project. Self-contained: derives the project URL from the
 * runtime env, so the Consultants module works out-of-the-box on any
 * self-hosted instance without an admin running SQL manually.
 *
 * Caller must be an authenticated admin user.
 */

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
    const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

    if (!SUPABASE_URL || !SERVICE_KEY) {
      return json({ error: "Project env not configured" }, 500);
    }

    // ----- Verify caller is an authenticated admin --------------------
    const authHeader = req.headers.get("Authorization") ?? "";
    if (!authHeader.startsWith("Bearer ")) {
      return json({ error: "unauthorized" }, 401);
    }
    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: userErr } = await userClient.auth.getUser();
    if (userErr || !user) return json({ error: "unauthorized" }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: isAdmin, error: roleErr } = await admin.rpc("has_role", {
      _user_id: user.id,
      _role: "admin",
    });
    if (roleErr) return json({ error: roleErr.message }, 500);
    if (!isAdmin) return json({ error: "admin role required" }, 403);

    // ----- Parse optional overrides -----------------------------------
    const body = req.method === "POST"
      ? await req.json().catch(() => ({}))
      : {};
    const action = body.action ?? "ensure";

    if (action === "status") {
      const { data, error } = await admin.rpc(
        "consultant_reindex_cron_status",
      );
      if (error) return json({ error: error.message }, 500);
      return json({ ok: true, status: data });
    }

    // ----- Schedule / re-schedule the cron job ------------------------
    const targetUrl = (body.url as string | undefined) ?? SUPABASE_URL;
    const schedule = (body.schedule as string | undefined) ?? "*/10 * * * *";

    const { data, error } = await admin.rpc(
      "ensure_consultant_reindex_cron",
      {
        p_url: targetUrl,
        p_service_key: SERVICE_KEY,
        p_schedule: schedule,
      },
    );
    if (error) return json({ error: error.message }, 500);

    return json({ ok: true, result: data });
  } catch (e) {
    return json(
      { error: e instanceof Error ? e.message : String(e) },
      500,
    );
  }
});
