-- SLA: parity round 6 (docs/parity/capabilities/sla.json)
-- Ports the sweep from edge:sla-check into SQL (run_sla_sweep) and adds:
--   • severity-based thresholds (policy.priority now FILTERS entities by
--     priority instead of only labeling severity)
--   • per-customer SLA tiers (sla_tiers + sla_tier_assignments; a tier
--     multiplier tightens/loosens thresholds per company or email)
--   • clock-stop on waiting (sla_clock_pauses + auto-pause trigger on
--     tickets.status = 'waiting'; paused minutes are excluded from elapsed)
--   • escalation actions on breach (sla_policies.escalation_actions jsonb,
--     applied by an AFTER INSERT trigger on sla_violations: bump_priority,
--     notify → platform event, create_task → crm_tasks, accrue_credit)
--   • service-credit accounting (service_credits + manage_service_credit)
--   • remediation workflow (manage_sla_remediation → crm_tasks link)
--   • compliance reporting (sla_compliance_report)
--
-- The sla_check skill flips handler edge:sla-check → rpc:run_sla_sweep; the
-- edge function remains as a thin compatibility wrapper for fleet installs.
--
-- Idempotent DDL. Forward-dated for the Lovable-managed migrate runner
-- (backdated files are silently skipped).

-- ── 1. Schema additions ──────────────────────────────────────────────────────
ALTER TABLE public.sla_policies
  ADD COLUMN IF NOT EXISTS escalation_actions jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE public.sla_violations
  ADD COLUMN IF NOT EXISTS escalated_at timestamptz,
  ADD COLUMN IF NOT EXISTS escalation_log jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS remediation_task_id uuid,
  ADD COLUMN IF NOT EXISTS remediation_status text,
  ADD COLUMN IF NOT EXISTS remediation_note text;

CREATE TABLE IF NOT EXISTS public.sla_tiers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  description text,
  threshold_multiplier numeric NOT NULL DEFAULT 1.0 CHECK (threshold_multiplier > 0),
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.sla_tiers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins manage sla_tiers" ON public.sla_tiers;
CREATE POLICY "Admins manage sla_tiers" ON public.sla_tiers
  FOR ALL USING (has_role(auth.uid(), 'admin'::app_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::app_role));
DROP POLICY IF EXISTS "Staff view sla_tiers" ON public.sla_tiers;
CREATE POLICY "Staff view sla_tiers" ON public.sla_tiers
  FOR SELECT USING (has_role(auth.uid(), 'admin'::app_role)
      OR has_role(auth.uid(), 'approver'::app_role)
      OR has_role(auth.uid(), 'writer'::app_role));

CREATE TABLE IF NOT EXISTS public.sla_tier_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tier_id uuid NOT NULL REFERENCES public.sla_tiers(id) ON DELETE CASCADE,
  company_id uuid REFERENCES public.companies(id) ON DELETE CASCADE,
  customer_email text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (company_id IS NOT NULL OR customer_email IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS sla_tier_assignments_company_uq
  ON public.sla_tier_assignments (company_id) WHERE company_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS sla_tier_assignments_email_uq
  ON public.sla_tier_assignments (lower(customer_email)) WHERE customer_email IS NOT NULL;
ALTER TABLE public.sla_tier_assignments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins manage sla_tier_assignments" ON public.sla_tier_assignments;
CREATE POLICY "Admins manage sla_tier_assignments" ON public.sla_tier_assignments
  FOR ALL USING (has_role(auth.uid(), 'admin'::app_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::app_role));
DROP POLICY IF EXISTS "Staff view sla_tier_assignments" ON public.sla_tier_assignments;
CREATE POLICY "Staff view sla_tier_assignments" ON public.sla_tier_assignments
  FOR SELECT USING (has_role(auth.uid(), 'admin'::app_role)
      OR has_role(auth.uid(), 'approver'::app_role)
      OR has_role(auth.uid(), 'writer'::app_role));

CREATE TABLE IF NOT EXISTS public.sla_clock_pauses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type text NOT NULL,
  entity_id text NOT NULL,
  paused_at timestamptz NOT NULL DEFAULT now(),
  resumed_at timestamptz,
  reason text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS sla_clock_pauses_entity_idx
  ON public.sla_clock_pauses (entity_type, entity_id);
ALTER TABLE public.sla_clock_pauses ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins manage sla_clock_pauses" ON public.sla_clock_pauses;
CREATE POLICY "Admins manage sla_clock_pauses" ON public.sla_clock_pauses
  FOR ALL USING (has_role(auth.uid(), 'admin'::app_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::app_role));
DROP POLICY IF EXISTS "Staff view sla_clock_pauses" ON public.sla_clock_pauses;
CREATE POLICY "Staff view sla_clock_pauses" ON public.sla_clock_pauses
  FOR SELECT USING (has_role(auth.uid(), 'admin'::app_role)
      OR has_role(auth.uid(), 'approver'::app_role)
      OR has_role(auth.uid(), 'writer'::app_role));

CREATE TABLE IF NOT EXISTS public.service_credits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  violation_id uuid REFERENCES public.sla_violations(id) ON DELETE SET NULL,
  company_id uuid REFERENCES public.companies(id) ON DELETE SET NULL,
  customer_email text,
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  currency text NOT NULL DEFAULT 'SEK',
  status text NOT NULL DEFAULT 'accrued',
  reason text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  applied_at timestamptz,
  created_by uuid
);
ALTER TABLE public.service_credits DROP CONSTRAINT IF EXISTS service_credits_status_check;
ALTER TABLE public.service_credits
  ADD CONSTRAINT service_credits_status_check CHECK (status IN ('accrued','applied','waived'));
ALTER TABLE public.service_credits ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins manage service_credits" ON public.service_credits;
CREATE POLICY "Admins manage service_credits" ON public.service_credits
  FOR ALL USING (has_role(auth.uid(), 'admin'::app_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::app_role));
DROP POLICY IF EXISTS "Staff view service_credits" ON public.service_credits;
CREATE POLICY "Staff view service_credits" ON public.service_credits
  FOR SELECT USING (has_role(auth.uid(), 'admin'::app_role)
      OR has_role(auth.uid(), 'approver'::app_role)
      OR has_role(auth.uid(), 'writer'::app_role));

-- ── 2. Clock-stop plumbing ───────────────────────────────────────────────────
-- Paused minutes inside [p_start, p_end], measured on the same clock as the
-- sweep (business minutes when a schedule exists, wall minutes otherwise).
CREATE OR REPLACE FUNCTION public.sla_paused_minutes(
  p_entity_type text,
  p_entity_id text,
  p_start timestamptz,
  p_end timestamptz,
  p_use_business_hours boolean DEFAULT NULL
) RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_use_bh boolean;
  v_total numeric := 0;
  v_row record;
  v_from timestamptz;
  v_to timestamptz;
BEGIN
  v_use_bh := COALESCE(p_use_business_hours, EXISTS (SELECT 1 FROM public.business_hours));
  FOR v_row IN
    SELECT paused_at, COALESCE(resumed_at, p_end) AS resumed_at
      FROM public.sla_clock_pauses
     WHERE entity_type = p_entity_type AND entity_id = p_entity_id
       AND paused_at < p_end
       AND COALESCE(resumed_at, p_end) > p_start
  LOOP
    v_from := GREATEST(v_row.paused_at, p_start);
    v_to := LEAST(v_row.resumed_at, p_end);
    IF v_to <= v_from THEN CONTINUE; END IF;
    IF v_use_bh THEN
      v_total := v_total + COALESCE(public.business_minutes_between(v_from, v_to), 0);
    ELSE
      v_total := v_total + floor(extract(epoch FROM (v_to - v_from)) / 60);
    END IF;
  END LOOP;
  RETURN GREATEST(v_total, 0);
END; $$;

-- Auto clock-stop: a ticket entering 'waiting' pauses its SLA clock; leaving
-- 'waiting' resumes it. Manual pauses via manage_sla_clock work for any entity.
CREATE OR REPLACE FUNCTION public.auto_pause_sla_on_ticket_waiting()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
    IF NEW.status::text = 'waiting' THEN
      INSERT INTO public.sla_clock_pauses (entity_type, entity_id, reason)
      SELECT 'ticket', NEW.id::text, 'waiting on customer'
      WHERE NOT EXISTS (
        SELECT 1 FROM public.sla_clock_pauses
         WHERE entity_type = 'ticket' AND entity_id = NEW.id::text AND resumed_at IS NULL
      );
    ELSIF OLD.status::text = 'waiting' THEN
      UPDATE public.sla_clock_pauses
         SET resumed_at = now()
       WHERE entity_type = 'ticket' AND entity_id = NEW.id::text AND resumed_at IS NULL;
    END IF;
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_auto_pause_sla_ticket ON public.tickets;
CREATE TRIGGER trg_auto_pause_sla_ticket
  AFTER UPDATE ON public.tickets
  FOR EACH ROW EXECUTE FUNCTION public.auto_pause_sla_on_ticket_waiting();

CREATE OR REPLACE FUNCTION public.manage_sla_clock(
  p_action text,
  p_entity_type text DEFAULT NULL,
  p_entity_id text DEFAULT NULL,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_row public.sla_clock_pauses;
  v_result jsonb;
BEGIN
  IF p_action = 'list' THEN
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
      RAISE EXCEPTION 'Only staff can view SLA clock pauses';
    END IF;
    SELECT jsonb_build_object('success', true, 'pauses', COALESCE(jsonb_agg(to_jsonb(p.*) ORDER BY p.paused_at DESC), '[]'::jsonb)) INTO v_result
    FROM (
      SELECT * FROM public.sla_clock_pauses
       WHERE (p_entity_type IS NULL OR entity_type = p_entity_type)
         AND (p_entity_id IS NULL OR entity_id = p_entity_id)
       ORDER BY paused_at DESC LIMIT 100
    ) p;
    RETURN v_result;
  END IF;

  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer')) THEN
    RAISE EXCEPTION 'Only admins/writers can pause/resume SLA clocks';
  END IF;
  IF p_entity_type IS NULL OR p_entity_id IS NULL THEN
    RAISE EXCEPTION 'entity_type and entity_id are required';
  END IF;

  IF p_action = 'pause' THEN
    IF EXISTS (SELECT 1 FROM public.sla_clock_pauses
                WHERE entity_type = p_entity_type AND entity_id = p_entity_id AND resumed_at IS NULL) THEN
      RAISE EXCEPTION 'Clock is already paused for % %', p_entity_type, p_entity_id;
    END IF;
    INSERT INTO public.sla_clock_pauses (entity_type, entity_id, reason, created_by)
    VALUES (p_entity_type, p_entity_id, p_reason, auth.uid())
    RETURNING * INTO v_row;
    RETURN jsonb_build_object('success', true, 'pause', to_jsonb(v_row));

  ELSIF p_action = 'resume' THEN
    UPDATE public.sla_clock_pauses
       SET resumed_at = now()
     WHERE entity_type = p_entity_type AND entity_id = p_entity_id AND resumed_at IS NULL
    RETURNING * INTO v_row;
    IF v_row.id IS NULL THEN
      RAISE EXCEPTION 'No open pause for % %', p_entity_type, p_entity_id;
    END IF;
    RETURN jsonb_build_object('success', true, 'pause', to_jsonb(v_row));
  END IF;

  RAISE EXCEPTION 'Unknown action: % (use pause|resume|list)', p_action;
END; $$;

-- ── 3. Tiers ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_sla_tier(
  p_action text,
  p_tier_id uuid DEFAULT NULL,
  p_name text DEFAULT NULL,
  p_description text DEFAULT NULL,
  p_threshold_multiplier numeric DEFAULT NULL,
  p_company_id uuid DEFAULT NULL,
  p_customer_email text DEFAULT NULL,
  p_assignment_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_tier public.sla_tiers;
  v_assign public.sla_tier_assignments;
  v_result jsonb;
BEGIN
  IF p_action IN ('list','list_assignments') THEN
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
      RAISE EXCEPTION 'Only staff can view SLA tiers';
    END IF;
  ELSE
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin')) THEN
      RAISE EXCEPTION 'Only admins can manage SLA tiers';
    END IF;
  END IF;

  IF p_action = 'create' THEN
    IF p_name IS NULL THEN RAISE EXCEPTION 'name is required'; END IF;
    INSERT INTO public.sla_tiers (name, description, threshold_multiplier)
    VALUES (p_name, p_description, COALESCE(p_threshold_multiplier, 1.0))
    RETURNING * INTO v_tier;
    RETURN jsonb_build_object('success', true, 'tier', to_jsonb(v_tier));

  ELSIF p_action = 'update' THEN
    IF p_tier_id IS NULL THEN RAISE EXCEPTION 'tier_id is required'; END IF;
    UPDATE public.sla_tiers
       SET name = COALESCE(p_name, name),
           description = COALESCE(p_description, description),
           threshold_multiplier = COALESCE(p_threshold_multiplier, threshold_multiplier)
     WHERE id = p_tier_id RETURNING * INTO v_tier;
    IF v_tier.id IS NULL THEN RAISE EXCEPTION 'Tier % not found', p_tier_id; END IF;
    RETURN jsonb_build_object('success', true, 'tier', to_jsonb(v_tier));

  ELSIF p_action = 'delete' THEN
    IF p_tier_id IS NULL THEN RAISE EXCEPTION 'tier_id is required'; END IF;
    DELETE FROM public.sla_tiers WHERE id = p_tier_id;
    RETURN jsonb_build_object('success', true, 'deleted', FOUND);

  ELSIF p_action = 'assign' THEN
    IF p_tier_id IS NULL OR (p_company_id IS NULL AND p_customer_email IS NULL) THEN
      RAISE EXCEPTION 'tier_id and company_id or customer_email are required';
    END IF;
    -- One tier per customer: replace any existing assignment.
    DELETE FROM public.sla_tier_assignments
     WHERE (p_company_id IS NOT NULL AND company_id = p_company_id)
        OR (p_customer_email IS NOT NULL AND lower(customer_email) = lower(p_customer_email));
    INSERT INTO public.sla_tier_assignments (tier_id, company_id, customer_email)
    VALUES (p_tier_id, p_company_id, p_customer_email)
    RETURNING * INTO v_assign;
    RETURN jsonb_build_object('success', true, 'assignment', to_jsonb(v_assign));

  ELSIF p_action = 'unassign' THEN
    DELETE FROM public.sla_tier_assignments
     WHERE id = p_assignment_id
        OR (p_assignment_id IS NULL AND p_company_id IS NOT NULL AND company_id = p_company_id)
        OR (p_assignment_id IS NULL AND p_customer_email IS NOT NULL AND lower(customer_email) = lower(p_customer_email));
    RETURN jsonb_build_object('success', true, 'removed', FOUND);

  ELSIF p_action = 'list' THEN
    SELECT jsonb_build_object('success', true, 'tiers', COALESCE(jsonb_agg(jsonb_build_object(
      'id', t.id, 'name', t.name, 'description', t.description,
      'threshold_multiplier', t.threshold_multiplier,
      'assignments', (SELECT count(*) FROM public.sla_tier_assignments a WHERE a.tier_id = t.id)
    ) ORDER BY t.threshold_multiplier), '[]'::jsonb)) INTO v_result
    FROM public.sla_tiers t;
    RETURN v_result;

  ELSIF p_action = 'list_assignments' THEN
    SELECT jsonb_build_object('success', true, 'assignments', COALESCE(jsonb_agg(jsonb_build_object(
      'id', a.id, 'tier', t.name, 'threshold_multiplier', t.threshold_multiplier,
      'company_id', a.company_id, 'company_name', c.name, 'customer_email', a.customer_email
    ) ORDER BY a.created_at DESC), '[]'::jsonb)) INTO v_result
    FROM public.sla_tier_assignments a
    JOIN public.sla_tiers t ON t.id = a.tier_id
    LEFT JOIN public.companies c ON c.id = a.company_id
    WHERE (p_tier_id IS NULL OR a.tier_id = p_tier_id);
    RETURN v_result;
  END IF;

  RAISE EXCEPTION 'Unknown action: % (use create|update|delete|assign|unassign|list|list_assignments)', p_action;
END; $$;

-- Tier multiplier for an entity's customer (company beats email; default 1.0).
CREATE OR REPLACE FUNCTION public.sla_tier_multiplier(p_company_id uuid, p_email text)
RETURNS numeric
LANGUAGE sql STABLE
SET search_path TO 'public'
AS $$
  SELECT COALESCE((
    SELECT t.threshold_multiplier
      FROM public.sla_tier_assignments a
      JOIN public.sla_tiers t ON t.id = a.tier_id
     WHERE (p_company_id IS NOT NULL AND a.company_id = p_company_id)
        OR (p_email IS NOT NULL AND a.customer_email IS NOT NULL AND lower(a.customer_email) = lower(p_email))
     ORDER BY (a.company_id IS NOT NULL) DESC
     LIMIT 1
  ), 1.0);
$$;

-- ── 4. Escalation actions on breach ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_sla_escalation(
  p_action text,
  p_policy_id uuid,
  p_actions jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_item jsonb;
  v_current jsonb;
BEGIN
  IF p_action = 'get' THEN
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
      RAISE EXCEPTION 'Only staff can view escalation config';
    END IF;
    SELECT escalation_actions INTO v_current FROM public.sla_policies WHERE id = p_policy_id;
    IF v_current IS NULL AND NOT EXISTS (SELECT 1 FROM public.sla_policies WHERE id = p_policy_id) THEN
      RAISE EXCEPTION 'Policy % not found', p_policy_id;
    END IF;
    RETURN jsonb_build_object('success', true, 'policy_id', p_policy_id, 'escalation_actions', COALESCE(v_current, '[]'::jsonb));
  END IF;

  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin')) THEN
    RAISE EXCEPTION 'Only admins can change escalation config';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.sla_policies WHERE id = p_policy_id) THEN
    RAISE EXCEPTION 'Policy % not found', p_policy_id;
  END IF;

  IF p_action = 'set' THEN
    IF p_actions IS NULL OR jsonb_typeof(p_actions) <> 'array' THEN
      RAISE EXCEPTION 'actions must be an array of {"action": …} objects';
    END IF;
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_actions) LOOP
      IF COALESCE(v_item->>'action','') NOT IN ('bump_priority','notify','create_task','accrue_credit') THEN
        RAISE EXCEPTION 'Unknown escalation action: % (use bump_priority|notify|create_task|accrue_credit)', v_item->>'action';
      END IF;
      IF v_item->>'action' = 'accrue_credit' AND COALESCE((v_item->>'amount_cents')::bigint, 0) <= 0 THEN
        RAISE EXCEPTION 'accrue_credit requires a positive amount_cents';
      END IF;
    END LOOP;
    UPDATE public.sla_policies SET escalation_actions = p_actions, updated_at = now() WHERE id = p_policy_id;
    RETURN jsonb_build_object('success', true, 'policy_id', p_policy_id, 'escalation_actions', p_actions);

  ELSIF p_action = 'clear' THEN
    UPDATE public.sla_policies SET escalation_actions = '[]'::jsonb, updated_at = now() WHERE id = p_policy_id;
    RETURN jsonb_build_object('success', true, 'policy_id', p_policy_id, 'escalation_actions', '[]'::jsonb);
  END IF;

  RAISE EXCEPTION 'Unknown action: % (use set|get|clear)', p_action;
END; $$;

CREATE OR REPLACE FUNCTION public.apply_sla_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_actions jsonb;
  v_item jsonb;
  v_log jsonb := '[]'::jsonb;
  v_ticket public.tickets;
  v_new_priority text;
  v_task_id uuid;
  v_company uuid;
  v_email text;
BEGIN
  SELECT escalation_actions INTO v_actions FROM public.sla_policies WHERE id = NEW.policy_id;
  IF v_actions IS NULL OR jsonb_array_length(v_actions) = 0 THEN
    RETURN NEW;
  END IF;

  -- Resolve the customer once (used by accrue_credit)
  IF NEW.entity_type = 'ticket' THEN
    SELECT company_id, contact_email INTO v_company, v_email FROM public.tickets WHERE id::text = NEW.entity_id;
  ELSIF NEW.entity_type = 'order' THEN
    SELECT company_id, customer_email INTO v_company, v_email FROM public.orders WHERE id::text = NEW.entity_id;
  ELSIF NEW.entity_type = 'chat' THEN
    SELECT NULL::uuid, customer_email INTO v_company, v_email FROM public.chat_conversations WHERE id::text = NEW.entity_id;
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_actions) LOOP
    BEGIN
      IF v_item->>'action' = 'bump_priority' AND NEW.entity_type = 'ticket' THEN
        SELECT * INTO v_ticket FROM public.tickets WHERE id::text = NEW.entity_id;
        IF v_ticket.id IS NOT NULL THEN
          v_new_priority := COALESCE(v_item->>'to',
            CASE v_ticket.priority::text
              WHEN 'low' THEN 'medium'
              WHEN 'medium' THEN 'high'
              WHEN 'high' THEN 'urgent'
              ELSE 'urgent' END);
          UPDATE public.tickets SET priority = v_new_priority::ticket_priority, updated_at = now()
           WHERE id = v_ticket.id AND priority::text <> v_new_priority;
          v_log := v_log || jsonb_build_object('action','bump_priority','from',v_ticket.priority,'to',v_new_priority);
        END IF;

      ELSIF v_item->>'action' = 'notify' THEN
        PERFORM public.emit_platform_event('sla.violation.escalated', jsonb_build_object(
          'violation_id', NEW.id, 'policy_id', NEW.policy_id,
          'entity_type', NEW.entity_type, 'entity_id', NEW.entity_id,
          'metric', NEW.metric, 'severity', NEW.severity,
          'actual_minutes', NEW.actual_minutes, 'threshold_minutes', NEW.threshold_minutes,
          'message', v_item->>'message'
        ), 'sla');
        v_log := v_log || jsonb_build_object('action','notify','event','sla.violation.escalated');

      ELSIF v_item->>'action' = 'create_task' THEN
        INSERT INTO public.crm_tasks (title, description, due_date, priority, assigned_to)
        VALUES (
          COALESCE(v_item->>'title', format('SLA breach: %s %s (%s)', NEW.entity_type, NEW.entity_id, NEW.metric)),
          format('SLA violation %s — %s exceeded %s min (actual %s min). Investigate and remediate.',
                 NEW.id, NEW.metric, NEW.threshold_minutes, NEW.actual_minutes),
          CURRENT_DATE + 1, 'high', NULLIF(v_item->>'assigned_to','')::uuid
        ) RETURNING id INTO v_task_id;
        v_log := v_log || jsonb_build_object('action','create_task','task_id',v_task_id);

      ELSIF v_item->>'action' = 'accrue_credit' THEN
        INSERT INTO public.service_credits (violation_id, company_id, customer_email, amount_cents, currency, reason)
        VALUES (NEW.id, v_company, v_email, (v_item->>'amount_cents')::bigint,
                COALESCE(v_item->>'currency','SEK'),
                format('SLA breach on %s %s (%s)', NEW.entity_type, NEW.entity_id, NEW.metric));
        v_log := v_log || jsonb_build_object('action','accrue_credit','amount_cents',(v_item->>'amount_cents')::bigint);
      END IF;
    EXCEPTION WHEN others THEN
      v_log := v_log || jsonb_build_object('action', v_item->>'action', 'error', SQLERRM);
    END;
  END LOOP;

  UPDATE public.sla_violations
     SET escalated_at = now(), escalation_log = v_log
   WHERE id = NEW.id;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_apply_sla_escalation ON public.sla_violations;
CREATE TRIGGER trg_apply_sla_escalation
  AFTER INSERT ON public.sla_violations
  FOR EACH ROW EXECUTE FUNCTION public.apply_sla_escalation();

-- ── 5. Service credits ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_service_credit(
  p_action text,
  p_credit_id uuid DEFAULT NULL,
  p_violation_id uuid DEFAULT NULL,
  p_company_id uuid DEFAULT NULL,
  p_customer_email text DEFAULT NULL,
  p_amount_cents bigint DEFAULT NULL,
  p_currency text DEFAULT NULL,
  p_reason text DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_row public.service_credits;
  v_result jsonb;
BEGIN
  IF p_action = 'list' THEN
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
      RAISE EXCEPTION 'Only staff can view service credits';
    END IF;
    SELECT jsonb_build_object('success', true,
      'credits', COALESCE(jsonb_agg(to_jsonb(c.*) ORDER BY c.created_at DESC), '[]'::jsonb),
      'total_accrued_cents', COALESCE(sum(c.amount_cents) FILTER (WHERE c.status = 'accrued'), 0)
    ) INTO v_result
    FROM public.service_credits c
    WHERE (p_company_id IS NULL OR c.company_id = p_company_id)
      AND (p_customer_email IS NULL OR lower(c.customer_email) = lower(p_customer_email));
    RETURN v_result;
  END IF;

  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin')) THEN
    RAISE EXCEPTION 'Only admins can manage service credits';
  END IF;

  IF p_action = 'accrue' THEN
    IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
      RAISE EXCEPTION 'amount_cents must be positive';
    END IF;
    IF p_violation_id IS NULL AND p_company_id IS NULL AND p_customer_email IS NULL THEN
      RAISE EXCEPTION 'violation_id, company_id or customer_email is required';
    END IF;
    INSERT INTO public.service_credits (violation_id, company_id, customer_email, amount_cents, currency, reason, notes, created_by)
    VALUES (p_violation_id, p_company_id, p_customer_email, p_amount_cents, COALESCE(p_currency,'SEK'), p_reason, p_notes, auth.uid())
    RETURNING * INTO v_row;
    RETURN jsonb_build_object('success', true, 'credit', to_jsonb(v_row));

  ELSIF p_action IN ('apply','waive') THEN
    IF p_credit_id IS NULL THEN RAISE EXCEPTION 'credit_id is required'; END IF;
    UPDATE public.service_credits
       SET status = CASE WHEN p_action = 'apply' THEN 'applied' ELSE 'waived' END,
           applied_at = CASE WHEN p_action = 'apply' THEN now() ELSE applied_at END,
           notes = COALESCE(p_notes, notes)
     WHERE id = p_credit_id AND status = 'accrued'
    RETURNING * INTO v_row;
    IF v_row.id IS NULL THEN
      RAISE EXCEPTION 'Credit % not found or not in accrued status', p_credit_id;
    END IF;
    RETURN jsonb_build_object('success', true, 'credit', to_jsonb(v_row));
  END IF;

  RAISE EXCEPTION 'Unknown action: % (use accrue|apply|waive|list)', p_action;
END; $$;

-- ── 6. Remediation workflow ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_sla_remediation(
  p_action text,
  p_violation_id uuid DEFAULT NULL,
  p_assigned_to uuid DEFAULT NULL,
  p_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_v public.sla_violations;
  v_task_id uuid;
  v_result jsonb;
BEGIN
  IF p_action = 'list' THEN
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
      RAISE EXCEPTION 'Only staff can view remediations';
    END IF;
    SELECT jsonb_build_object('success', true, 'remediations', COALESCE(jsonb_agg(jsonb_build_object(
      'violation_id', v.id, 'entity_type', v.entity_type, 'entity_id', v.entity_id,
      'metric', v.metric, 'severity', v.severity,
      'remediation_status', v.remediation_status, 'remediation_note', v.remediation_note,
      'remediation_task_id', v.remediation_task_id, 'task_title', t.title,
      'task_completed_at', t.completed_at, 'created_at', v.created_at
    ) ORDER BY v.created_at DESC), '[]'::jsonb)) INTO v_result
    FROM public.sla_violations v
    LEFT JOIN public.crm_tasks t ON t.id = v.remediation_task_id
    WHERE v.remediation_status IS NOT NULL;
    RETURN v_result;
  END IF;

  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer')) THEN
    RAISE EXCEPTION 'Only admins/writers can manage remediations';
  END IF;
  IF p_violation_id IS NULL THEN RAISE EXCEPTION 'violation_id is required'; END IF;
  SELECT * INTO v_v FROM public.sla_violations WHERE id = p_violation_id;
  IF v_v.id IS NULL THEN RAISE EXCEPTION 'Violation % not found', p_violation_id; END IF;

  IF p_action = 'open' THEN
    IF v_v.remediation_status = 'open' THEN
      RAISE EXCEPTION 'Remediation already open for violation %', p_violation_id;
    END IF;
    INSERT INTO public.crm_tasks (title, description, due_date, priority, assigned_to)
    VALUES (
      format('Remediate SLA breach: %s %s (%s)', v_v.entity_type, v_v.entity_id, v_v.metric),
      COALESCE(p_note, format('Remediation for SLA violation %s: threshold %s min, actual %s min.',
        v_v.id, v_v.threshold_minutes, v_v.actual_minutes)),
      CURRENT_DATE + 1, 'high', p_assigned_to
    ) RETURNING id INTO v_task_id;
    UPDATE public.sla_violations
       SET remediation_status = 'open', remediation_task_id = v_task_id, remediation_note = p_note
     WHERE id = p_violation_id;
    RETURN jsonb_build_object('success', true, 'violation_id', p_violation_id, 'remediation_task_id', v_task_id, 'remediation_status', 'open');

  ELSIF p_action = 'complete' THEN
    IF v_v.remediation_status IS DISTINCT FROM 'open' THEN
      RAISE EXCEPTION 'No open remediation for violation %', p_violation_id;
    END IF;
    UPDATE public.crm_tasks
       SET completed_at = now(), completion_note = COALESCE(p_note, 'SLA remediation completed')
     WHERE id = v_v.remediation_task_id AND completed_at IS NULL;
    UPDATE public.sla_violations
       SET remediation_status = 'completed', remediation_note = COALESCE(p_note, remediation_note)
     WHERE id = p_violation_id;
    RETURN jsonb_build_object('success', true, 'violation_id', p_violation_id, 'remediation_status', 'completed');
  END IF;

  RAISE EXCEPTION 'Unknown action: % (use open|complete|list)', p_action;
END; $$;

-- ── 7. The sweep, in SQL ─────────────────────────────────────────────────────
-- Port of edge:sla-check with severity filtering, tier-adjusted thresholds and
-- clock-stop. Policy.priority ≠ 'all' now FILTERS entities by priority (where
-- the entity has one: tickets, chats) instead of only labeling the violation.
CREATE OR REPLACE FUNCTION public.run_sla_sweep(p_entity_type text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_policy record;
  v_ent record;
  v_use_bh boolean;
  v_min_mult numeric;
  v_counts jsonb := '{}'::jsonb;
  v_fresh jsonb := '[]'::jsonb;
  v_policies_checked integer := 0;
  v_table text;
  v_start_col text;
  v_open_cond text;
  v_priority_col text;
  v_email_col text;
  v_company_col text;
  v_sql text;
  v_elapsed numeric;
  v_paused numeric;
  v_eff_threshold numeric;
  v_severity text;
  v_checked integer;
  v_opened integer;
  v_resolved integer;
  v_viol record;
  v_still_open boolean;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
    RAISE EXCEPTION 'Only staff can run the SLA sweep';
  END IF;

  v_use_bh := EXISTS (SELECT 1 FROM public.business_hours);
  -- Tier multipliers can be < 1 (premium customers get tighter SLAs), so the
  -- wall-clock pre-filter must use the smallest multiplier in play.
  SELECT LEAST(COALESCE(min(threshold_multiplier), 1), 1) INTO v_min_mult FROM public.sla_tiers;

  FOR v_policy IN
    SELECT * FROM public.sla_policies
     WHERE enabled = true
       AND (p_entity_type IS NULL OR entity_type = p_entity_type)
  LOOP
    v_policies_checked := v_policies_checked + 1;

    CASE v_policy.entity_type
      WHEN 'ticket' THEN
        v_table := 'tickets'; v_start_col := 'created_at';
        v_open_cond := 'resolved_at IS NULL AND status::text NOT IN (''closed'',''resolved'')';
        v_priority_col := 'priority'; v_email_col := 'contact_email'; v_company_col := 'company_id';
      WHEN 'order' THEN
        v_table := 'orders'; v_start_col := 'created_at';
        v_open_cond := 'shipped_at IS NULL AND status::text NOT IN (''cancelled'',''refunded'')';
        v_priority_col := NULL; v_email_col := 'customer_email'; v_company_col := 'company_id';
      WHEN 'lead' THEN
        v_table := 'leads'; v_start_col := 'created_at';
        v_open_cond := 'ai_qualified_at IS NULL AND converted_at IS NULL';
        v_priority_col := NULL; v_email_col := 'email'; v_company_col := 'company_id';
      WHEN 'chat' THEN
        v_table := 'chat_conversations'; v_start_col := 'created_at';
        v_open_cond := 'conversation_status::text NOT IN (''closed'',''resolved'')';
        v_priority_col := 'priority'; v_email_col := 'customer_email'; v_company_col := NULL;
      WHEN 'booking' THEN
        v_table := 'bookings'; v_start_col := 'created_at';
        v_open_cond := 'confirmation_sent_at IS NULL AND status::text NOT IN (''cancelled'',''confirmed'')';
        v_priority_col := NULL; v_email_col := 'customer_email'; v_company_col := NULL;
      ELSE
        CONTINUE; -- unknown entity type — skip rather than guess
    END CASE;

    v_checked := 0; v_opened := 0; v_resolved := 0;

    v_sql := format(
      'SELECT id::text AS id, %I AS started_at, %s AS priority, %s AS email, %s AS company_id
         FROM public.%I
        WHERE (%s)
          AND %I < now() - (interval ''1 minute'' * %s)',
      v_start_col,
      CASE WHEN v_priority_col IS NOT NULL THEN format('%I::text', v_priority_col) ELSE 'NULL::text' END,
      CASE WHEN v_email_col IS NOT NULL THEN format('%I::text', v_email_col) ELSE 'NULL::text' END,
      CASE WHEN v_company_col IS NOT NULL THEN format('%I::uuid', v_company_col) ELSE 'NULL::uuid' END,
      v_table, v_open_cond, v_start_col,
      (v_policy.threshold_minutes * v_min_mult)::text
    );
    IF v_priority_col IS NOT NULL AND COALESCE(v_policy.priority, 'all') NOT IN ('all','') THEN
      v_sql := v_sql || format(' AND %I::text = %L', v_priority_col, v_policy.priority);
    END IF;
    v_sql := v_sql || ' LIMIT 500';

    FOR v_ent IN EXECUTE v_sql LOOP
      v_checked := v_checked + 1;

      IF v_use_bh THEN
        v_elapsed := COALESCE(public.business_minutes_between(v_ent.started_at, now()), 0);
      ELSE
        v_elapsed := floor(extract(epoch FROM (now() - v_ent.started_at)) / 60);
      END IF;
      v_paused := public.sla_paused_minutes(v_policy.entity_type, v_ent.id, v_ent.started_at, now(), v_use_bh);
      v_elapsed := GREATEST(v_elapsed - v_paused, 0);

      v_eff_threshold := v_policy.threshold_minutes
        * public.sla_tier_multiplier(v_ent.company_id, v_ent.email);

      IF v_elapsed < v_eff_threshold THEN CONTINUE; END IF;

      IF EXISTS (SELECT 1 FROM public.sla_violations
                  WHERE policy_id = v_policy.id AND entity_id = v_ent.id AND resolved_at IS NULL) THEN
        CONTINUE;
      END IF;

      v_severity := CASE
        WHEN COALESCE(v_policy.priority,'all') NOT IN ('all','') THEN v_policy.priority
        ELSE COALESCE(v_ent.priority, 'medium') END;

      INSERT INTO public.sla_violations
        (policy_id, entity_type, entity_id, metric, threshold_minutes, actual_minutes, severity)
      VALUES
        (v_policy.id, v_policy.entity_type, v_ent.id, v_policy.metric,
         round(v_eff_threshold), round(v_elapsed), v_severity);

      v_opened := v_opened + 1;
      v_fresh := v_fresh || jsonb_build_object(
        'policy_id', v_policy.id, 'entity_type', v_policy.entity_type,
        'entity_id', v_ent.id, 'metric', v_policy.metric,
        'actual_minutes', round(v_elapsed), 'threshold_minutes', round(v_eff_threshold),
        'severity', v_severity);
    END LOOP;

    -- Auto-resolve open violations whose entity is no longer "open".
    FOR v_viol IN
      SELECT id, entity_id FROM public.sla_violations
       WHERE policy_id = v_policy.id AND resolved_at IS NULL
    LOOP
      EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I WHERE id::text = $1 AND (%s))', v_table, v_open_cond)
        INTO v_still_open USING v_viol.entity_id;
      IF NOT v_still_open THEN
        UPDATE public.sla_violations
           SET resolved_at = now(), resolved_by = 'sla-sweep'
         WHERE id = v_viol.id;
        v_resolved := v_resolved + 1;
      END IF;
    END LOOP;

    v_counts := jsonb_set(v_counts, ARRAY[v_policy.entity_type], jsonb_build_object(
      'checked', COALESCE((v_counts->v_policy.entity_type->>'checked')::int, 0) + v_checked,
      'open_violations', COALESCE((v_counts->v_policy.entity_type->>'open_violations')::int, 0) + v_opened,
      'resolved', COALESCE((v_counts->v_policy.entity_type->>'resolved')::int, 0) + v_resolved
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'status', 'success',
    'policies_checked', v_policies_checked,
    'business_hours_clock', v_use_bh,
    'counts', v_counts,
    'fresh_violations', v_fresh
  );
END; $$;

-- ── 8. Compliance reporting ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sla_compliance_report(
  p_days integer DEFAULT 30,
  p_entity_type text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_since timestamptz := now() - make_interval(days => GREATEST(COALESCE(p_days,30),1));
  v_by_entity jsonb;
  v_by_severity jsonb;
  v_opened integer;
  v_resolved integer;
  v_open_now integer;
  v_avg_overage numeric;
  v_credits bigint;
  v_escalated integer;
  v_entity record;
  v_entities jsonb := '{}'::jsonb;
  v_total bigint;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
    RAISE EXCEPTION 'Only staff can view compliance reports';
  END IF;

  SELECT count(*) FILTER (WHERE created_at >= v_since),
         count(*) FILTER (WHERE resolved_at >= v_since),
         count(*) FILTER (WHERE resolved_at IS NULL),
         round(avg(actual_minutes::numeric / NULLIF(threshold_minutes,0)) FILTER (WHERE created_at >= v_since), 2),
         count(*) FILTER (WHERE escalated_at IS NOT NULL AND created_at >= v_since)
  INTO v_opened, v_resolved, v_open_now, v_avg_overage, v_escalated
  FROM public.sla_violations
  WHERE (p_entity_type IS NULL OR entity_type = p_entity_type);

  SELECT COALESCE(jsonb_object_agg(entity_type, cnt), '{}'::jsonb) INTO v_by_entity
  FROM (SELECT entity_type, count(*) AS cnt FROM public.sla_violations
         WHERE created_at >= v_since AND (p_entity_type IS NULL OR entity_type = p_entity_type)
         GROUP BY entity_type) x;

  SELECT COALESCE(jsonb_object_agg(COALESCE(severity,'medium'), cnt), '{}'::jsonb) INTO v_by_severity
  FROM (SELECT severity, count(*) AS cnt FROM public.sla_violations
         WHERE created_at >= v_since AND (p_entity_type IS NULL OR entity_type = p_entity_type)
         GROUP BY severity) x;

  SELECT COALESCE(sum(amount_cents), 0) INTO v_credits
  FROM public.service_credits WHERE created_at >= v_since;

  -- Breach rate per entity type: entities created in the window vs violations.
  FOR v_entity IN
    SELECT * FROM (VALUES
      ('ticket','tickets'), ('order','orders'), ('lead','leads'),
      ('chat','chat_conversations'), ('booking','bookings')
    ) AS t(etype, tbl)
    WHERE (p_entity_type IS NULL OR etype = p_entity_type)
  LOOP
    EXECUTE format('SELECT count(*) FROM public.%I WHERE created_at >= $1', v_entity.tbl)
      INTO v_total USING v_since;
    IF v_total > 0 THEN
      v_entities := v_entities || jsonb_build_object(v_entity.etype, jsonb_build_object(
        'created_in_period', v_total,
        'violations_in_period', COALESCE((v_by_entity->>v_entity.etype)::int, 0),
        'compliance_pct', round((1 - LEAST(COALESCE((v_by_entity->>v_entity.etype)::numeric, 0) / v_total, 1)) * 100, 1)
      ));
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'period_days', GREATEST(COALESCE(p_days,30),1),
    'violations_opened', v_opened,
    'violations_resolved', v_resolved,
    'violations_open_now', v_open_now,
    'avg_overage_ratio', v_avg_overage,
    'escalations_fired', v_escalated,
    'service_credits_accrued_cents', v_credits,
    'by_entity_type', v_by_entity,
    'by_severity', v_by_severity,
    'compliance_by_entity', v_entities
  );
END; $$;
