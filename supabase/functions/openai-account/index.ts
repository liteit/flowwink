import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

/**
 * OpenAI account info — exposes month-to-date usage so the Integrations
 * card can show admins what FlowWink has consumed and warn when a budget
 * threshold is approached.
 *
 * OpenAI does NOT expose remaining credits via a normal sk- key. So we:
 *   1. Validate the key with /v1/models (cheap, 1 request).
 *   2. Aggregate THIS month from our own ai_usage_logs (provider=openai).
 *   3. If an admin key (sk-admin-...) is configured, fetch real org costs.
 *
 * Soft-fails so the UI never crashes.
 */

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

// USD per 1M tokens — approximate, kept conservative (gpt-4.1 family).
const PRICING: Record<string, { in: number; out: number }> = {
  "gpt-4.1": { in: 2.0, out: 8.0 },
  "gpt-4.1-mini": { in: 0.4, out: 1.6 },
  "gpt-4.1-nano": { in: 0.1, out: 0.4 },
  "gpt-4o": { in: 2.5, out: 10.0 },
  "gpt-4o-mini": { in: 0.15, out: 0.6 },
};

function estimateCostUsd(model: string | null, promptTokens: number, completionTokens: number): number {
  const key = (model || "gpt-4.1-mini").toLowerCase();
  const match = Object.keys(PRICING).find((k) => key.startsWith(k)) || "gpt-4.1-mini";
  const p = PRICING[match];
  return (promptTokens / 1_000_000) * p.in + (completionTokens / 1_000_000) * p.out;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) {
    return new Response(
      JSON.stringify({ success: false, error: "OPENAI_API_KEY not configured" }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  const isAdminKey = apiKey.startsWith("sk-admin-");
  const keyType = isAdminKey ? "admin" : "project";

  // 1. Validate key by listing models (cheap and works for both project & admin keys)
  let valid = false;
  let validationError: string | null = null;
  try {
    const res = await fetch("https://api.openai.com/v1/models", {
      headers: { Authorization: `Bearer ${apiKey}` },
    });
    valid = res.ok;
    if (!res.ok) {
      const j = await res.json().catch(() => ({}));
      validationError = j?.error?.message || `HTTP ${res.status}`;
    }
  } catch (e) {
    validationError = e instanceof Error ? e.message : "Network error";
  }

  // 2. Aggregate our own usage logs for the current month
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const now = new Date();
  const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString();

  let monthTokens = 0;
  let monthPromptTokens = 0;
  let monthCompletionTokens = 0;
  let monthRequests = 0;
  let monthCostUsd = 0;

  try {
    const { data, error } = await supabase
      .from("ai_usage_logs")
      .select("model, prompt_tokens, completion_tokens, total_tokens")
      .eq("provider", "openai")
      .gte("created_at", monthStart)
      .limit(10000);
    if (!error && data) {
      monthRequests = data.length;
      for (const row of data) {
        const pt = row.prompt_tokens || 0;
        const ct = row.completion_tokens || 0;
        monthPromptTokens += pt;
        monthCompletionTokens += ct;
        monthTokens += row.total_tokens || pt + ct;
        monthCostUsd += estimateCostUsd(row.model, pt, ct);
      }
    }
  } catch {
    // ignore — soft fail
  }

  // 3. Org-level real costs (admin keys only)
  let orgCostUsd: number | null = null;
  if (isAdminKey && valid) {
    try {
      const startUnix = Math.floor(new Date(monthStart).getTime() / 1000);
      const res = await fetch(
        `https://api.openai.com/v1/organization/costs?start_time=${startUnix}&limit=31`,
        { headers: { Authorization: `Bearer ${apiKey}` } },
      );
      if (res.ok) {
        const j = await res.json();
        let total = 0;
        for (const bucket of j?.data || []) {
          for (const result of bucket?.results || []) {
            total += result?.amount?.value || 0;
          }
        }
        orgCostUsd = total;
      }
    } catch {
      // ignore
    }
  }

  return new Response(
    JSON.stringify({
      success: true,
      valid,
      validation_error: validationError,
      key_type: keyType,
      month_to_date: {
        requests: monthRequests,
        total_tokens: monthTokens,
        prompt_tokens: monthPromptTokens,
        completion_tokens: monthCompletionTokens,
        estimated_cost_usd: Number(monthCostUsd.toFixed(4)),
        org_cost_usd: orgCostUsd,
      },
    }),
    { headers: { ...corsHeaders, "Content-Type": "application/json" } },
  );
});
