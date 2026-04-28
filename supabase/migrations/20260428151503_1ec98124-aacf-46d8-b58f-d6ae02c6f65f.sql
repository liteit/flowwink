-- Role → Module access matrix
CREATE TABLE IF NOT EXISTS public.role_module_access (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  role public.app_role NOT NULL,
  module_id TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (role, module_id)
);

CREATE INDEX IF NOT EXISTS idx_role_module_access_role ON public.role_module_access(role);
CREATE INDEX IF NOT EXISTS idx_role_module_access_module ON public.role_module_access(module_id);

ALTER TABLE public.role_module_access ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated can read role_module_access" ON public.role_module_access;
CREATE POLICY "Authenticated can read role_module_access"
ON public.role_module_access
FOR SELECT
TO authenticated
USING (true);

DROP POLICY IF EXISTS "Admins manage role_module_access" ON public.role_module_access;
CREATE POLICY "Admins manage role_module_access"
ON public.role_module_access
FOR ALL
TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- Updated_at trigger
DROP TRIGGER IF EXISTS update_role_module_access_updated_at ON public.role_module_access;
CREATE TRIGGER update_role_module_access_updated_at
BEFORE UPDATE ON public.role_module_access
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- Seed defaults (idempotent)
INSERT INTO public.role_module_access (role, module_id) VALUES
  ('sales', 'leads'),
  ('sales', 'companies'),
  ('sales', 'deals'),
  ('sales', 'bookings'),
  ('sales', 'calendar'),
  ('sales', 'salesIntelligence'),
  ('sales', 'resume'),
  ('sales', 'companyInsights'),
  ('hr', 'hr'),
  ('hr', 'recruitment'),
  ('hr', 'contracts'),
  ('accounting', 'invoicing'),
  ('accounting', 'accounting'),
  ('accounting', 'expenses'),
  ('accounting', 'timesheets'),
  ('accounting', 'approvals'),
  ('accounting', 'reconciliation'),
  ('accounting', 'subscriptions'),
  ('support', 'tickets'),
  ('support', 'liveSupport'),
  ('support', 'workspaceChat'),
  ('warehouse', 'ecommerce'),
  ('warehouse', 'inventory'),
  ('purchasing', 'purchasing'),
  ('marketing', 'newsletter'),
  ('marketing', 'webinars'),
  ('marketing', 'forms'),
  ('projects', 'projects')
ON CONFLICT (role, module_id) DO NOTHING;