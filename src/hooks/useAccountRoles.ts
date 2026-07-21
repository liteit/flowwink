import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { useToast } from "@/hooks/use-toast";

export interface AccountRole {
  id: string;
  locale: string;
  role: string;
  account_code: string;
  description: string | null;
}

/**
 * Rows from `account_roles` for a given locale pack. These map platform-level
 * bookkeeping roles (bank, vat_output, sales_revenue…) to a chart-of-accounts
 * `account_code`. Bookkeeping RPCs post to roles, not codes — so remapping a
 * role here is how an admin says "our bank is 1931, not 1930" without SQL.
 */
export function useAccountRoles(locale: string | null | undefined) {
  return useQuery({
    queryKey: ["account-roles", locale],
    enabled: !!locale,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("account_roles")
        .select("id, locale, role, account_code, description")
        .eq("locale", locale as string)
        .order("role");
      if (error) throw error;
      return (data ?? []) as AccountRole[];
    },
  });
}

/** Update the `account_code` for a single role. Admin-only via RLS. */
export function useUpdateAccountRole() {
  const qc = useQueryClient();
  const { toast } = useToast();
  return useMutation({
    mutationFn: async ({ id, account_code }: { id: string; account_code: string }) => {
      const { error } = await supabase
        .from("account_roles")
        .update({ account_code })
        .eq("id", id);
      if (error) throw error;
    },
    onSuccess: (_data, vars) => {
      qc.invalidateQueries({ queryKey: ["account-roles"] });
      toast({
        title: "Role remapped",
        description: `Now posts to account ${vars.account_code}.`,
      });
    },
    onError: (err: any) => {
      toast({
        title: "Failed to update role",
        description: err?.message ?? "Unknown error",
        variant: "destructive",
      });
    },
  });
}
