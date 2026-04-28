import { useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useToast } from '@/hooks/use-toast';
import type { AppRole } from '@/types/cms';

export function useResetRoleModuleAccess() {
  const qc = useQueryClient();
  const { toast } = useToast();

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ['role-module-access'] });
    qc.invalidateQueries({ queryKey: ['role-access-audit'] });
  };

  const resetOne = useMutation({
    mutationFn: async (role: AppRole) => {
      const { error } = await supabase.rpc('reset_role_module_access', {
        _role: role,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      invalidate();
      toast({ title: 'Role reset to defaults' });
    },
    onError: (e: Error) =>
      toast({
        title: 'Reset failed',
        description: e.message,
        variant: 'destructive',
      }),
  });

  const resetAll = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc('reset_all_role_module_access');
      if (error) throw error;
    },
    onSuccess: () => {
      invalidate();
      toast({ title: 'All roles reset to defaults' });
    },
    onError: (e: Error) =>
      toast({
        title: 'Reset failed',
        description: e.message,
        variant: 'destructive',
      }),
  });

  return { resetOne, resetAll };
}
