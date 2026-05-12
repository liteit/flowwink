/**
 * Run async tasks with a maximum concurrency limit.
 * Returns settled results so callers can surface partial failures.
 *
 * Used by bootstrap fan-out (FlowPilot toggle reseeds every active module)
 * to prevent flooding Supabase with 40+ simultaneous upserts.
 */
export async function runWithConcurrency<T, R>(
  items: T[],
  limit: number,
  worker: (item: T, index: number) => Promise<R>
): Promise<Array<{ item: T; ok: true; value: R } | { item: T; ok: false; error: unknown }>> {
  const results: Array<
    { item: T; ok: true; value: R } | { item: T; ok: false; error: unknown }
  > = new Array(items.length);
  let cursor = 0;

  async function take(): Promise<void> {
    while (true) {
      const i = cursor++;
      if (i >= items.length) return;
      try {
        const value = await worker(items[i], i);
        results[i] = { item: items[i], ok: true, value };
      } catch (error) {
        results[i] = { item: items[i], ok: false, error };
      }
    }
  }

  const runners = Array.from({ length: Math.min(limit, items.length) }, () => take());
  await Promise.all(runners);
  return results;
}
