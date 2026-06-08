
-- Restore demo platform infra missing from dev DB
CREATE TABLE IF NOT EXISTS public.demo_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  module text NOT NULL,
  scenario text NOT NULL DEFAULT 'default',
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  notes text
);

CREATE TABLE IF NOT EXISTS public.demo_run_items (
  id bigserial PRIMARY KEY,
  run_id uuid NOT NULL REFERENCES public.demo_runs(id) ON DELETE CASCADE,
  table_name text NOT NULL,
  row_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_demo_run_items_run ON public.demo_run_items(run_id);
CREATE INDEX IF NOT EXISTS idx_demo_run_items_table ON public.demo_run_items(table_name);

GRANT SELECT ON public.demo_runs TO authenticated;
GRANT SELECT ON public.demo_run_items TO authenticated;
GRANT ALL ON public.demo_runs TO service_role;
GRANT ALL ON public.demo_run_items TO service_role;
GRANT USAGE, SELECT ON SEQUENCE demo_run_items_id_seq TO authenticated;
GRANT ALL ON SEQUENCE demo_run_items_id_seq TO service_role;

ALTER TABLE public.demo_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.demo_run_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "demo_runs admin read" ON public.demo_runs;
CREATE POLICY "demo_runs admin read" ON public.demo_runs
  FOR SELECT TO authenticated USING (has_role(auth.uid(), 'admin'::app_role));

DROP POLICY IF EXISTS "demo_run_items admin read" ON public.demo_run_items;
CREATE POLICY "demo_run_items admin read" ON public.demo_run_items
  FOR SELECT TO authenticated USING (has_role(auth.uid(), 'admin'::app_role));

CREATE OR REPLACE FUNCTION public._demo_register_row(
  p_run_id uuid, p_table_name text, p_row_id uuid
) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  INSERT INTO public.demo_run_items(run_id, table_name, row_id)
  VALUES (p_run_id, p_table_name, p_row_id);
$$;

-- My new seeders (hr/tickets/bookings/newsletter/vendors) write directly to
-- demo_run_items with column name `record_id`. Real column is `row_id`. Patch
-- by replacing them to use the helper. Easier: recreate them.
