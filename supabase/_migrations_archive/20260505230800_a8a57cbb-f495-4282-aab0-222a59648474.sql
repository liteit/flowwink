
-- ============================================================
-- 1. POLYMORPHIC ACTIVITIES
-- ============================================================
CREATE TABLE IF NOT EXISTS public.activities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type text NOT NULL,        -- 'deal','order','ticket','invoice','company','lead','contact','project','task'
  entity_id uuid NOT NULL,
  activity_type text NOT NULL,      -- 'note','call','meeting','todo','email','status_change'
  subject text,
  body text,
  due_at timestamptz,
  done_at timestamptz,
  assigned_to uuid,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_activities_entity ON public.activities(entity_type, entity_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_activities_assigned_open ON public.activities(assigned_to, due_at) WHERE done_at IS NULL;

ALTER TABLE public.activities ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated read activities" ON public.activities;
CREATE POLICY "Authenticated read activities" ON public.activities
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Admins manage activities" ON public.activities;
CREATE POLICY "Admins manage activities" ON public.activities
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(),'admin'))
  WITH CHECK (public.has_role(auth.uid(),'admin'));

DROP POLICY IF EXISTS "Users manage own activities" ON public.activities;
CREATE POLICY "Users manage own activities" ON public.activities
  FOR ALL TO authenticated
  USING (created_by = auth.uid() OR assigned_to = auth.uid())
  WITH CHECK (created_by = auth.uid() OR assigned_to = auth.uid());

DROP TRIGGER IF EXISTS trg_activities_updated ON public.activities;
CREATE TRIGGER trg_activities_updated BEFORE UPDATE ON public.activities
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================================
-- 2. MULTI-ADDRESS PER CONTACT
-- ============================================================
CREATE TABLE IF NOT EXISTS public.addresses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_type text NOT NULL,         -- 'company','profile','vendor','lead'
  owner_id uuid NOT NULL,
  address_type text NOT NULL DEFAULT 'other', -- 'billing','shipping','private','other'
  is_primary boolean NOT NULL DEFAULT false,
  label text,
  street text,
  street2 text,
  city text,
  state text,
  postal_code text,
  country text,
  phone text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_addresses_owner ON public.addresses(owner_type, owner_id);

ALTER TABLE public.addresses ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins manage addresses" ON public.addresses;
CREATE POLICY "Admins manage addresses" ON public.addresses
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(),'admin'))
  WITH CHECK (public.has_role(auth.uid(),'admin'));

DROP POLICY IF EXISTS "Users read own profile addresses" ON public.addresses;
CREATE POLICY "Users read own profile addresses" ON public.addresses
  FOR SELECT TO authenticated
  USING (owner_type = 'profile' AND owner_id = auth.uid());

DROP POLICY IF EXISTS "Users manage own profile addresses" ON public.addresses;
CREATE POLICY "Users manage own profile addresses" ON public.addresses
  FOR ALL TO authenticated
  USING (owner_type = 'profile' AND owner_id = auth.uid())
  WITH CHECK (owner_type = 'profile' AND owner_id = auth.uid());

DROP TRIGGER IF EXISTS trg_addresses_updated ON public.addresses;
CREATE TRIGGER trg_addresses_updated BEFORE UPDATE ON public.addresses
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================================
-- 3. OPTIONAL PRODUCTS IN QUOTE
-- ============================================================
ALTER TABLE public.quote_items
  ADD COLUMN IF NOT EXISTS is_optional boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS selected_by_customer boolean NOT NULL DEFAULT true;

-- ============================================================
-- 4. KB SUGGEST ON TICKET
-- ============================================================
ALTER TABLE public.tickets
  ADD COLUMN IF NOT EXISTS suggested_kb_article_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  ADD COLUMN IF NOT EXISTS csat_survey_sent_at timestamptz;

-- ============================================================
-- 5. CSAT EVENT EMITTER ON TICKET RESOLVED
-- ============================================================
CREATE OR REPLACE FUNCTION public.emit_ticket_resolved_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'resolved' AND (OLD.status IS DISTINCT FROM 'resolved') THEN
    -- emit only if helper exists
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname='emit_platform_event') THEN
      PERFORM public.emit_platform_event(
        'ticket.resolved',
        jsonb_build_object(
          'ticket_id', NEW.id,
          'subject', NEW.subject,
          'contact_email', NEW.contact_email,
          'contact_name', NEW.contact_name,
          'company_id', NEW.company_id,
          'lead_id', NEW.lead_id,
          'category', NEW.category,
          'priority', NEW.priority,
          'resolved_at', NEW.resolved_at
        ),
        'tickets'
      );
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_emit_ticket_resolved ON public.tickets;
CREATE TRIGGER trg_emit_ticket_resolved
  AFTER UPDATE OF status ON public.tickets
  FOR EACH ROW
  EXECUTE FUNCTION public.emit_ticket_resolved_event();
