import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

/**
 * Hunter.io account info — exposes plan + remaining requests for the
 * Integrations card. Soft-fails so the UI never crashes.
 *
 * Docs: https://hunter.io/api-documentation/v2#account
 */

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  const apiKey = Deno.env.get('HUNTER_API_KEY');
  if (!apiKey) {
    return new Response(
      JSON.stringify({ success: false, error: 'HUNTER_API_KEY not configured' }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }

  try {
    const res = await fetch(`https://api.hunter.io/v2/account?api_key=${apiKey}`);
    const json = await res.json();
    if (!res.ok) {
      return new Response(
        JSON.stringify({ success: false, error: json?.errors?.[0]?.details || `HTTP ${res.status}` }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      );
    }

    const d = json?.data ?? {};
    const requests = d?.requests?.searches ?? d?.requests ?? {};
    const used = requests?.used ?? 0;
    const available = requests?.available ?? 0;
    const remaining = Math.max(0, available - used);

    return new Response(
      JSON.stringify({
        success: true,
        plan_name: d?.plan_name ?? null,
        plan_level: d?.plan_level ?? null,
        reset_date: d?.reset_date ?? null,
        searches: { used, available, remaining },
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  } catch (e) {
    return new Response(
      JSON.stringify({ success: false, error: e instanceof Error ? e.message : 'Unknown error' }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }
});
