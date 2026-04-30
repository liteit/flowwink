DROP VIEW IF EXISTS public.survey_nps_stats;
CREATE VIEW public.survey_nps_stats
WITH (security_invoker = on) AS
SELECT
  c.id AS campaign_id,
  c.name AS campaign_name,
  COUNT(r.id) AS total_responses,
  COUNT(*) FILTER (WHERE r.category = 'promoter') AS promoters,
  COUNT(*) FILTER (WHERE r.category = 'passive') AS passives,
  COUNT(*) FILTER (WHERE r.category = 'detractor') AS detractors,
  ROUND(100.0 * (COUNT(*) FILTER (WHERE r.category = 'promoter')::numeric
    - COUNT(*) FILTER (WHERE r.category = 'detractor')::numeric)
    / NULLIF(COUNT(r.id), 0), 1) AS nps_score,
  ROUND(AVG(r.score)::numeric, 2) AS avg_score
FROM public.survey_campaigns c
LEFT JOIN public.survey_responses r ON r.campaign_id = c.id
GROUP BY c.id, c.name;

GRANT SELECT ON public.survey_nps_stats TO authenticated;

CREATE OR REPLACE FUNCTION public.categorize_nps_response()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.score IS NOT NULL THEN
    NEW.category := CASE
      WHEN NEW.score <= 6 THEN 'detractor'
      WHEN NEW.score <= 8 THEN 'passive'
      ELSE 'promoter'
    END;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_survey_send_responded()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  UPDATE public.survey_sends SET responded_at = now() WHERE id = NEW.send_id;
  IF EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_name = 'emit_platform_event') THEN
    PERFORM public.emit_platform_event(
      'survey.responded',
      jsonb_build_object(
        'response_id', NEW.id,
        'campaign_id', NEW.campaign_id,
        'score', NEW.score,
        'category', NEW.category,
        'recipient_email', NEW.recipient_email,
        'lead_id', NEW.lead_id
      ),
      'surveys'
    );
  END IF;
  RETURN NEW;
END;
$$;