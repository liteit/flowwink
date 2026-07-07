import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { toast } from "sonner";
import { logger } from "@/lib/logger";

type Rpc = "manage_redirect" | "manage_page_translation" | "manage_page_experiment";

async function call<T = unknown>(fn: Rpc, args: Record<string, unknown>): Promise<T> {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const { data, error } = await (supabase.rpc as any)(fn, args);
  if (error) {
    logger.error(`[pages-rpc] ${fn}`, error);
    throw error;
  }
  return data as T;
}

export function usePagesRpcQuery<T>(fn: Rpc, args: Record<string, unknown>, key: unknown[], enabled = true) {
  return useQuery({
    queryKey: [fn, ...key],
    queryFn: () => call<T>(fn, args),
    enabled,
  });
}

export function usePagesRpcMutation(fn: Rpc, invalidateKeys: unknown[][]) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (args: Record<string, unknown>) => call(fn, args),
    onSuccess: () => {
      for (const k of invalidateKeys) qc.invalidateQueries({ queryKey: k });
    },
    onError: (err: unknown) => {
      const msg = err instanceof Error ? err.message : "Operation failed";
      toast.error(msg);
    },
  });
}

export { call as pagesRpc };
