import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { ALL_WORKSPACE_SOURCES, type WorkspaceSource } from './useWorkspaceChat';

export interface CoworkChatSettings {
  mode: 'strict' | 'cowork';
  allowWorldKnowledge: boolean;
  allowWebSearch: boolean;
  defaultSources: WorkspaceSource[];
}

export const DEFAULT_COWORK_SETTINGS: CoworkChatSettings = {
  mode: 'cowork',
  allowWorldKnowledge: true,
  allowWebSearch: true,
  defaultSources: ALL_WORKSPACE_SOURCES,
};

const KEY = 'cowork_chat';

export function useCoworkSettings() {
  return useQuery({
    queryKey: ['site_settings', KEY],
    queryFn: async (): Promise<CoworkChatSettings> => {
      const { data, error } = await supabase
        .from('site_settings')
        .select('value')
        .eq('key', KEY)
        .maybeSingle();
      if (error) throw error;
      const v = (data?.value || {}) as Partial<CoworkChatSettings>;
      return {
        mode: v.mode === 'strict' ? 'strict' : 'cowork',
        allowWorldKnowledge: v.allowWorldKnowledge !== false,
        allowWebSearch: v.allowWebSearch !== false,
        defaultSources:
          Array.isArray(v.defaultSources) && v.defaultSources.length > 0
            ? (v.defaultSources.filter((s) =>
                ALL_WORKSPACE_SOURCES.includes(s as WorkspaceSource),
              ) as WorkspaceSource[])
            : ALL_WORKSPACE_SOURCES,
      };
    },
  });
}

export function useSaveCoworkSettings() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (next: CoworkChatSettings) => {
      const { error } = await supabase
        .from('site_settings')
        .upsert({ key: KEY, value: next as any }, { onConflict: 'key' });
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['site_settings', KEY] }),
  });
}
