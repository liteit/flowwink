-- Defaults table: the baseline matrix
CREATE TABLE IF NOT EXISTS public.role_module_access_defaults (
  role app_role NOT NULL,
  module_id text NOT NULL,
  PRIMARY KEY (role, module_id)
);

ALTER TABLE public.role_module_access_defaults ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated can read defaults" ON public.role_module_access_defaults;
CREATE POLICY "Authenticated can read defaults"
  ON public.role_module_access_defaults
  FOR SELECT
  TO authenticated
  USING (true);

DROP POLICY IF EXISTS "Admins can manage defaults" ON public.role_module_access_defaults;
CREATE POLICY "Admins can manage defaults"
  ON public.role_module_access_defaults
  FOR ALL
  TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- Seed defaults from CURRENT state (only if defaults table is empty)
INSERT INTO public.role_module_access_defaults (role, module_id)
SELECT role, module_id FROM public.role_module_access
ON CONFLICT (role, module_id) DO NOTHING;

-- Reset a single role to defaults
CREATE OR REPLACE FUNCTION public.reset_role_module_access(_role app_role)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only admins can reset role permissions';
  END IF;

  DELETE FROM public.role_module_access WHERE role = _role;

  INSERT INTO public.role_module_access (role, module_id)
  SELECT role, module_id
  FROM public.role_module_access_defaults
  WHERE role = _role
  ON CONFLICT DO NOTHING;

  INSERT INTO public.audit_logs (action, entity_type, user_id, metadata)
  VALUES (
    'role_module_access.reset_role',
    'role_module_access',
    auth.uid(),
    jsonb_build_object('role', _role)
  );
END;
$$;

-- Reset ALL roles to defaults
CREATE OR REPLACE FUNCTION public.reset_all_role_module_access()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only admins can reset role permissions';
  END IF;

  DELETE FROM public.role_module_access;

  INSERT INTO public.role_module_access (role, module_id)
  SELECT role, module_id FROM public.role_module_access_defaults
  ON CONFLICT DO NOTHING;

  INSERT INTO public.audit_logs (action, entity_type, user_id, metadata)
  VALUES (
    'role_module_access.reset_all',
    'role_module_access',
    auth.uid(),
    jsonb_build_object('scope', 'all')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.reset_role_module_access(app_role) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reset_all_role_module_access() TO authenticated;