import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useToast } from '@/hooks/use-toast';
import type { AppRole } from '@/types/cms';

export type RoleModuleAccessMap = Partial<Record<AppRole, Set<string>>>;

/**
 * Reads the role → module access matrix from `role_module_access`.
 * Returns a map keyed by role with a Set of module_ids.
 *
 * Admin is implicit (sees everything) — not stored in this table.
 */
export function useRoleModuleAccess() {
  return useQuery({
    queryKey: ['role-module-access'],
    queryFn: async (): Promise<RoleModuleAccessMap> => {
      const { data, error } = await supabase
        .from('role_module_access')
        .select('role, module_id');
      if (error) throw error;
      const map: RoleModuleAccessMap = {};
      (data ?? []).forEach((row) => {
        const r = row.role as AppRole;
        if (!map[r]) map[r] = new Set<string>();
        map[r]!.add(row.module_id);
      });
      return map;
    },
    staleTime: 60 * 1000,
  });
}

export function useToggleRoleModuleAccess() {
  const qc = useQueryClient();
  const { toast } = useToast();
  return useMutation({
    mutationFn: async ({
      role,
      moduleId,
      grant,
    }: {
      role: AppRole;
      moduleId: string;
      grant: boolean;
    }) => {
      if (grant) {
        const { error } = await supabase
          .from('role_module_access')
          .insert({ role, module_id: moduleId });
        // Ignore unique violation — already granted
        if (error && !String(error.message).includes('duplicate')) throw error;
      } else {
        const { error } = await supabase
          .from('role_module_access')
          .delete()
          .eq('role', role)
          .eq('module_id', moduleId);
        if (error) throw error;
      }
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['role-module-access'] });
    },
    onError: (e: Error) => {
      toast({
        title: 'Failed to update access',
        description: e.message,
        variant: 'destructive',
      });
    },
  });
}
