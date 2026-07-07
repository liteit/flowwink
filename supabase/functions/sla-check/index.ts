// sla-check — compatibility wrapper around the SQL sweep (run_sla_sweep).
//
// Since parity r6 (migration 20260708030000) the sweep lives in Postgres:
// severity-filtered policies, per-customer tier multipliers, clock-stop
// pauses and business-hours elapsed are all applied inside run_sla_sweep().
// The sla_check skill calls the RPC directly (handler rpc:run_sla_sweep);
// this edge function remains for anything still invoking edge:sla-check
// (older automations, external HTTP callers) and simply delegates.

import { getServiceClient } from '../_shared/supabase-clients.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const supabase = getServiceClient();
    const body = await req.json().catch(() => ({}));
    // Accept both the legacy `entity_type` and the RPC-style `p_entity_type`.
    const entityFilter: string | null = body?.entity_type ?? body?.p_entity_type ?? null;

    const { data, error } = await supabase.rpc('run_sla_sweep', {
      p_entity_type: entityFilter,
    });
    if (error) throw new Error(`run_sla_sweep failed: ${error.message}`);

    return new Response(JSON.stringify(data), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  } catch (err) {
    return new Response(
      JSON.stringify({ status: 'failed', error: err instanceof Error ? err.message : String(err) }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }
});
