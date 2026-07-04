-- Fleet portability for the visitor-intent lead trigger.
--
-- Migration 20260704152107 (Lovable, rzhj) created trigger_score_visitor_intent
-- with the rzhj project URL and anon key hardcoded in the function body. On any
-- other instance (forks, new provisions) that trigger would POST lead ids to
-- rzhj's score-visitor-intent endpoint instead of its own.
--
-- Fix: same mechanism as register_flowpilot_cron(url, anon_key) — a per-instance
-- registration function that rebuilds the trigger function with THIS instance's
-- URL/key baked in. rzhj is unaffected until re-registered (its hardcoded body
-- already points at itself); every other instance must call this during
-- provisioning, right where register_flowpilot_cron is already called
-- (docs/operators/provisioning-and-updates.md).

CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE OR REPLACE FUNCTION public.register_visitor_intent_trigger(
  p_supabase_url text,
  p_anon_key text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_catalog
AS $fn$
BEGIN
  EXECUTE format($body$
    CREATE OR REPLACE FUNCTION public.trigger_score_visitor_intent()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = public
    AS $trg$
    BEGIN
      -- Only fire when a lead has identifiable contact info
      IF NEW.email IS NULL AND NEW.phone IS NULL THEN
        RETURN NEW;
      END IF;

      -- On UPDATE: only fire when email/phone just became present
      IF TG_OP = 'UPDATE' THEN
        IF (OLD.email IS NOT DISTINCT FROM NEW.email)
           AND (OLD.phone IS NOT DISTINCT FROM NEW.phone) THEN
          RETURN NEW;
        END IF;
      END IF;

      PERFORM net.http_post(
        url     := %L,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'apikey', %L,
          'Authorization', 'Bearer ' || %L
        ),
        body    := jsonb_build_object('lead_id', NEW.id)
      );

      RETURN NEW;
    EXCEPTION WHEN OTHERS THEN
      -- Never block a lead insert if the async call fails
      RETURN NEW;
    END;
    $trg$;
  $body$,
    p_supabase_url || '/functions/v1/score-visitor-intent',
    p_anon_key,
    p_anon_key
  );

  DROP TRIGGER IF EXISTS leads_score_on_identify ON public.leads;
  CREATE TRIGGER leads_score_on_identify
    AFTER INSERT OR UPDATE OF email, phone ON public.leads
    FOR EACH ROW
    EXECUTE FUNCTION public.trigger_score_visitor_intent();

  RETURN jsonb_build_object('visitor_intent_trigger', 'registered');
END;
$fn$;

GRANT ALL ON FUNCTION public.register_visitor_intent_trigger(text, text) TO anon;
GRANT ALL ON FUNCTION public.register_visitor_intent_trigger(text, text) TO authenticated;
GRANT ALL ON FUNCTION public.register_visitor_intent_trigger(text, text) TO service_role;
