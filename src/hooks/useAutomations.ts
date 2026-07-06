import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { toast } from 'sonner';
import type { AgentAutomation } from '@/types/agent';

const QUERY_KEY = ['agent-automations'];

export function useAutomations() {
  return useQuery({
    queryKey: QUERY_KEY,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('agent_automations')
        .select('*')
        .order('created_at', { ascending: false });
      if (error) throw error;
      return data as unknown as AgentAutomation[];
    },
  });
}

export function useUpsertAutomation() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (auto: Partial<AgentAutomation> & { name: string }) => {
      const payload = {
        name: auto.name,
        description: auto.description ?? null,
        trigger_type: auto.trigger_type ?? 'cron',
        trigger_config: auto.trigger_config ?? {},
        skill_id: auto.skill_id ?? null,
        skill_name: auto.skill_name ?? null,
        skill_arguments: auto.skill_arguments ?? {},
        enabled: auto.enabled ?? true,
        executor: auto.executor ?? 'platform',
        created_by: auto.created_by ?? null,
      };

      if (auto.id) {
        const { error } = await supabase
          .from('agent_automations')
          .update(payload as any)
          .eq('id', auto.id);
        if (error) throw error;
      } else {
        const { error } = await supabase
          .from('agent_automations')
          .insert(payload as any);
        if (error) throw error;
      }
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: QUERY_KEY });
      toast.success('Automation saved');
    },
    onError: () => toast.error('Failed to save automation'),
  });
}

export function useToggleAutomation() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, enabled }: { id: string; enabled: boolean }) => {
      const { error } = await supabase
        .from('agent_automations')
        .update({ enabled } as any)
        .eq('id', id);
      if (error) throw error;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: QUERY_KEY });
      toast.success('Automation updated');
    },
    onError: () => toast.error('Failed to toggle automation'),
  });
}

export function useDeleteAutomation() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase
        .from('agent_automations')
        .delete()
        .eq('id', id);
      if (error) throw error;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: QUERY_KEY });
      toast.success('Automation deleted');
    },
    onError: () => toast.error('Failed to delete automation'),
  });
}

/**
 * Trigger an automation immediately, bypassing the cron schedule.
 * Calls agent-execute with the automation's skill + arguments, then
 * updates last_triggered_at + run_count so the UI reflects the run.
 */
export function useRunAutomationNow() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (auto: AgentAutomation) => {
      if (!auto.skill_name && !auto.skill_id) {
        throw new Error('Automation has no skill configured');
      }

      const { data, error } = await supabase.functions.invoke('agent-execute', {
        body: {
          skill_id: auto.skill_id,
          skill_name: auto.skill_name,
          arguments: auto.skill_arguments ?? {},
          agent_type: auto.executor === 'flowpilot' ? 'flowpilot' : 'platform',
        },
      });

      if (error) throw error;

      // Staged envelope (requires_staging skill): the skill did NOT run —
      // a pending operation was created that needs approval. Don't count it
      // as a run and don't toast success (sweep finding #C1).
      const payload = (data as any)?.result ?? data;
      if (payload?.staged === true) {
        return { staged: true, operation_id: payload.operation_id } as any;
      }

      const errMsg = (data as any)?.error ?? null;

      await supabase
        .from('agent_automations')
        .update({
          last_triggered_at: new Date().toISOString(),
          run_count: (auto.run_count ?? 0) + 1,
          last_error: errMsg,
        } as any)
        .eq('id', auto.id);

      if (errMsg) throw new Error(errMsg);
      return data;
    },
    onSuccess: (data: any) => {
      qc.invalidateQueries({ queryKey: QUERY_KEY });
      if (data?.staged === true) {
        toast.info('Skill is gated — a pending operation was created and needs approval before it runs.');
      } else {
        toast.success('Automation executed');
      }
    },
    onError: (err: Error) => toast.error(err.message || 'Run failed'),
  });
}

