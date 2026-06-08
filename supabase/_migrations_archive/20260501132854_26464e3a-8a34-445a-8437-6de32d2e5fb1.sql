-- Consolidate agent skill gating into the canonical Approval Engine.
-- Spår A (agent_activity pending_approval) becomes a thin adapter on top of Spår B (approval_requests).

-- 1. Link agent_activity to approval_requests
ALTER TABLE public.agent_activity
  ADD COLUMN IF NOT EXISTS approval_request_id uuid REFERENCES public.approval_requests(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_agent_activity_approval_request
  ON public.agent_activity(approval_request_id)
  WHERE approval_request_id IS NOT NULL;

-- 2. SECURITY DEFINER RPC: create an approval request from a gated skill call.
CREATE OR REPLACE FUNCTION public.request_skill_approval(
  p_skill_name text,
  p_skill_id uuid,
  p_args jsonb,
  p_activity_id uuid,
  p_agent text DEFAULT 'mcp',
  p_conversation_id uuid DEFAULT NULL,
  p_amount_cents bigint DEFAULT NULL,
  p_currency text DEFAULT 'SEK',
  p_reason text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request_id uuid;
  v_rule record;
  v_required_role app_role := 'admin';
  v_rule_id uuid := NULL;
BEGIN
  SELECT er.rule_id, er.required_role
    INTO v_rule
    FROM public.evaluate_approval_required('agent_skill', p_amount_cents, COALESCE(p_currency,'SEK')) er
    LIMIT 1;

  IF FOUND THEN
    v_rule_id := v_rule.rule_id;
    v_required_role := v_rule.required_role;
  END IF;

  INSERT INTO public.approval_requests (
    rule_id, entity_type, entity_id, amount_cents, currency,
    reason, required_role, requested_by, context
  ) VALUES (
    v_rule_id,
    'agent_skill',
    COALESCE(p_activity_id::text, gen_random_uuid()::text),
    p_amount_cents,
    COALESCE(p_currency, 'SEK'),
    COALESCE(p_reason, 'Agent skill "' || p_skill_name || '" requires approval before execution'),
    v_required_role,
    NULL,
    jsonb_build_object(
      'skill_name', p_skill_name,
      'skill_id', p_skill_id,
      'args', p_args,
      'agent', p_agent,
      'conversation_id', p_conversation_id,
      'activity_id', p_activity_id
    )
  )
  RETURNING id INTO v_request_id;

  IF p_activity_id IS NOT NULL THEN
    UPDATE public.agent_activity
       SET approval_request_id = v_request_id
     WHERE id = p_activity_id;
  END IF;

  RETURN v_request_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_skill_approval(text, uuid, jsonb, uuid, text, uuid, bigint, text, text) TO authenticated, service_role, anon;

-- 3. Trigger: mirror approval status onto agent_activity for polling clients
CREATE OR REPLACE FUNCTION public.sync_agent_activity_on_approval()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_activity_id uuid;
BEGIN
  IF NEW.entity_type <> 'agent_skill' THEN
    RETURN NEW;
  END IF;

  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  BEGIN
    v_activity_id := NEW.entity_id::uuid;
  EXCEPTION WHEN others THEN
    RETURN NEW;
  END;

  IF NEW.status = 'approved' THEN
    UPDATE public.agent_activity
       SET status = 'approved'
     WHERE id = v_activity_id AND status = 'pending_approval';
  ELSIF NEW.status = 'rejected' THEN
    UPDATE public.agent_activity
       SET status = 'rejected',
           error_message = COALESCE(NEW.reason, 'Approval rejected')
     WHERE id = v_activity_id AND status = 'pending_approval';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_agent_activity_on_approval ON public.approval_requests;
CREATE TRIGGER trg_sync_agent_activity_on_approval
AFTER UPDATE OF status ON public.approval_requests
FOR EACH ROW
EXECUTE FUNCTION public.sync_agent_activity_on_approval();