import { supabase } from '@/integrations/supabase/client';

/**
 * Call a platform skill through agent-execute — the admin UI's rail into the
 * skill layer (edge-surface refactor B1a).
 *
 * Why this exists: former standalone edge functions (qualify-lead,
 * enrich-company, fetch-fx-rates, …) are re-homed as internal: handlers inside
 * agent-execute, so UI callers go through the skill layer like every other
 * caller. Side effects (wanted, safe-by-construction): calls are audited in
 * agent_activity and respect the skill's trust dial.
 *
 * Returns the handler's result object (unwrapped from agent-execute's
 * { status, result } envelope). Throws on transport errors, execution
 * failures, and pending_approval — callers that want to support staged skills
 * should use useAgentOperate's executeSkill instead, which renders the HIL
 * approval card.
 */
export async function callSkill<T = Record<string, unknown>>(
  skillName: string,
  args: Record<string, unknown> = {},
): Promise<T> {
  const { data, error } = await supabase.functions.invoke('agent-execute', {
    body: { skill_name: skillName, arguments: args, agent_type: 'admin_ui' },
  });

  if (error) throw new Error(error.message);

  if (data?.status === 'pending_approval') {
    throw new Error(
      `Skill "${skillName}" requires approval (trust level "${data?.trust_level ?? 'staged'}"). ` +
      'Run it from the FlowPilot chat to approve, or raise the skill trust level.',
    );
  }

  if (data?.status && data.status !== 'success') {
    const inner = data?.result?.error ?? data?.error ?? `Skill "${skillName}" failed`;
    throw new Error(String(inner));
  }

  const result = (data?.result ?? data) as T & { error?: string };
  // Handlers signal soft failures as { error } with HTTP 200 — surface them.
  if (result && typeof result === 'object' && 'error' in result && result.error) {
    throw new Error(String(result.error));
  }
  return result as T;
}
