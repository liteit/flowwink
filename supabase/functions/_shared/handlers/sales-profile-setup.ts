// sales_profile_setup — internal skill handler.
//
// Upserts the sales-intelligence profile: type 'company' (site-wide ICP /
// value-prop config) or type 'user' (per-seller profile).
//
// Moved from the standalone `sales-profile-setup` edge function (edge-surface
// refactor B1a, wave 1). Auth-semantics note for the reviewing counterpart:
// the edge function resolved the user from the Authorization header
// (resolveCaller) and required service-or-admin for 'company'. Through
// agent-execute the Authorization was always the service key, so
// resolveCaller returned invalid_token and type:'user' ALWAYS answered
// "Authentication required for user profile" for agent callers. The internal
// handler keeps that behavior for agent callers (no callerUserId) and lets a
// real signed-in user (agent-execute's resolved caller_user_id) save their own
// profile — strictly more correct, never more permissive. The 'company' gate
// is agent-execute's own auth (service/admin), same effective policy.

import type { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import type { HandlerCtx } from './qualify-lead.ts';

export async function executeSalesProfileSetup(
  supabase: SupabaseClient,
  args: Record<string, unknown>,
  ctx: HandlerCtx,
): Promise<Record<string, unknown>> {
  try {
    const raw = args as Record<string, unknown>;

    const type = raw.type as 'company' | 'user' | undefined;
    if (!type || !['company', 'user'].includes(type)) {
      return { error: 'type must be "company" or "user"' };
    }

    // Tolerant arg-mapping: accept either { type, data: {...} } or a flat
    // { type, icp, value_proposition, ... } payload from MCP/FlowChat callers.
    let data: Record<string, unknown>;
    if (raw.data && typeof raw.data === 'object') {
      data = raw.data as Record<string, unknown>;
    } else {
      const { type: _t, user_id: _u, data: _d, ...rest } = raw;
      data = rest as Record<string, unknown>;
    }

    if (!data || Object.keys(data).length === 0) {
      return { error: 'profile fields are required (either as `data` object or flat properties)' };
    }

    const userId = type === 'user'
      ? (ctx.callerUserId ?? null)
      : null;

    if (type === 'user' && !userId) {
      return { error: 'Authentication required for user profile' };
    }

    // Upsert the profile
    const { data: profile, error } = await supabase
      .from('sales_intelligence_profiles')
      .upsert(
        {
          type,
          user_id: userId,
          data,
          updated_at: new Date().toISOString(),
        },
        { onConflict: 'type,user_id' }
      )
      .select()
      .single();

    if (error) {
      console.error('[sales-profile-setup] Upsert error:', error);
      return { error: error.message };
    }

    console.log('[sales-profile-setup] Profile saved:', type, userId);

    return {
      success: true,
      profile,
      message: `${type} profile saved successfully`,
    };
  } catch (error) {
    console.error('[sales-profile-setup] Error:', error);
    return { error: error instanceof Error ? error.message : 'Unknown error' };
  }
}
