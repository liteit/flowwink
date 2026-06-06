import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";

/**
 * Returns a map of module name -> number of demo rows currently seeded
 * (counted via demo_run_items joined through demo_runs.module).
 *
 * Single aggregated query, shared across all ModuleCards via React Query cache.
 */
export function useModuleSeedCounts() {
  return useQuery({
    queryKey: ["module-seed-counts"],
    queryFn: async (): Promise<Record<string, number>> => {
      const { data, error } = await supabase
        .from("demo_run_items")
        .select("run_id, demo_runs!inner(module)")
        .limit(100000);
      if (error) throw error;
      const counts: Record<string, number> = {};
      for (const row of (data ?? []) as Array<{ demo_runs: { module: string } | null }>) {
        const mod = row.demo_runs?.module;
        if (!mod) continue;
        counts[mod] = (counts[mod] ?? 0) + 1;
      }
      return counts;
    },
    staleTime: 30_000,
  });
}
