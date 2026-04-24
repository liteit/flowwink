import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { DEFAULT_LOCALE_ID, getPack } from '@/lib/locale-packs';
import { useToast } from '@/hooks/use-toast';

const SETTING_KEY = 'accounting_locale';

/**
 * Tenant-level active locale pack, persisted in site_settings (key/value).
 * Falls back to localStorage / DEFAULT_LOCALE_ID when not set.
 */
export function useTenantLocalePack() {
  const qc = useQueryClient();
  const { toast } = useToast();

  const { data: activeId, isLoading } = useQuery({
    queryKey: ['site-settings', SETTING_KEY],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('site_settings')
        .select('value')
        .eq('key', SETTING_KEY)
        .maybeSingle();
      if (error) throw error;
      const v = (data?.value as any);
      const id =
        (typeof v === 'string' ? v : v?.id) ||
        (typeof window !== 'undefined' ? localStorage.getItem('accounting-locale') : null) ||
        DEFAULT_LOCALE_ID;
      return id as string;
    },
  });

  const setActive = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase
        .from('site_settings')
        .upsert({ key: SETTING_KEY, value: { id } as any }, { onConflict: 'key' });
      if (error) throw error;
      if (typeof window !== 'undefined') localStorage.setItem('accounting-locale', id);
      return id;
    },
    onSuccess: (id) => {
      qc.invalidateQueries({ queryKey: ['site-settings', SETTING_KEY] });
      toast({ title: 'Active locale pack updated', description: getPack(id).label });
    },
    onError: (err: any) => {
      toast({ title: 'Failed to update', description: err.message, variant: 'destructive' });
    },
  });

  return {
    activeId: activeId ?? DEFAULT_LOCALE_ID,
    activePack: getPack(activeId),
    isLoading,
    setActive: setActive.mutate,
    isSaving: setActive.isPending,
  };
}
