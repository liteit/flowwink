-- Surveys: scoring/points + analytics RPC + CSV export RPC
-- Idempotent: adds nullable columns, redefines functions, re-grants.

ALTER TABLE public.survey_templates
  ADD COLUMN IF NOT EXISTS pass_score numeric,
  ADD COLUMN IF NOT EXISTS max_points numeric;

ALTER TABLE public.survey_responses
  ADD COLUMN IF NOT EXISTS points_earned numeric,
  ADD COLUMN IF NOT EXISTS passed boolean;

-- Extend template kind to allow 'quiz' (weighted point scoring)
ALTER TABLE public.survey_templates DROP CONSTRAINT IF EXISTS survey_templates_kind_check;
ALTER TABLE public.survey_templates ADD CONSTRAINT survey_templates_kind_check
  CHECK (kind = ANY (ARRAY['nps','csat','ces','custom','quiz']));

-- Replace submit_survey_response: computes weighted points against per-question
-- `points` and `correct` fields on template.questions, plus optional `passed`
-- flag if template.pass_score is set. Preserves original behaviour for NPS/CSAT.
CREATE OR REPLACE FUNCTION public.submit_survey_response(
  _token text,
  _score integer DEFAULT NULL,
  _comment text DEFAULT NULL,
  _answers jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_send public.survey_sends%ROWTYPE;
  v_tmpl public.survey_templates%ROWTYPE;
  v_response_id uuid;
  v_points numeric := 0;
  v_max numeric := 0;
  v_passed boolean := NULL;
  q jsonb;
  ans jsonb;
BEGIN
  SELECT * INTO v_send FROM public.survey_sends WHERE token = _token;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'invalid_token'); END IF;
  IF v_send.expires_at < now() THEN RETURN jsonb_build_object('success', false, 'error', 'expired'); END IF;
  IF v_send.responded_at IS NOT NULL THEN RETURN jsonb_build_object('success', false, 'error', 'already_responded'); END IF;

  SELECT t.* INTO v_tmpl FROM public.survey_templates t
    JOIN public.survey_campaigns c ON c.template_id = t.id
   WHERE c.id = v_send.campaign_id;

  IF v_tmpl.id IS NOT NULL THEN
    FOR q IN SELECT * FROM jsonb_array_elements(COALESCE(v_tmpl.questions, '[]'::jsonb)) LOOP
      IF (q ? 'points') THEN
        v_max := v_max + COALESCE((q->>'points')::numeric, 0);
        ans := _answers -> (q->>'id');
        IF ans IS NOT NULL AND (q ? 'correct') AND ans = (q->'correct') THEN
          v_points := v_points + COALESCE((q->>'points')::numeric, 0);
        END IF;
      END IF;
    END LOOP;
    IF v_tmpl.pass_score IS NOT NULL THEN
      v_passed := v_points >= v_tmpl.pass_score;
    END IF;
  END IF;

  INSERT INTO public.survey_responses (send_id, campaign_id, template_id, score, comment, answers, recipient_email, lead_id, points_earned, passed)
  SELECT v_send.id, v_send.campaign_id, c.template_id, _score, _comment, _answers, v_send.recipient_email, v_send.lead_id,
         CASE WHEN v_max > 0 THEN v_points ELSE NULL END,
         v_passed
    FROM public.survey_campaigns c WHERE c.id = v_send.campaign_id
   RETURNING id INTO v_response_id;

  RETURN jsonb_build_object(
    'success', true,
    'response_id', v_response_id,
    'points_earned', CASE WHEN v_max > 0 THEN v_points ELSE NULL END,
    'max_points', CASE WHEN v_max > 0 THEN v_max ELSE NULL END,
    'passed', v_passed
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.submit_survey_response(text, integer, text, jsonb) TO anon, authenticated, service_role;

-- Per-campaign analytics with per-question aggregation.
-- Service-role escape so agent-execute (MCP) can call it.
CREATE OR REPLACE FUNCTION public.get_survey_analytics(p_campaign_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_authorized boolean := (auth.role() = 'service_role') OR public.has_role(auth.uid(), 'admin');
  v_out jsonb;
BEGIN
  IF NOT v_authorized THEN
    RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
  END IF;

  WITH camps AS (
    SELECT c.id, c.name, c.template_id, t.kind, t.questions, t.pass_score
      FROM public.survey_campaigns c
      LEFT JOIN public.survey_templates t ON t.id = c.template_id
     WHERE (p_campaign_id IS NULL OR c.id = p_campaign_id)
  ),
  agg AS (
    SELECT
      c.id AS campaign_id,
      c.name AS campaign_name,
      c.kind,
      c.questions,
      c.pass_score,
      count(r.id) AS total_responses,
      count(*) FILTER (WHERE r.category = 'promoter')  AS promoters,
      count(*) FILTER (WHERE r.category = 'passive')   AS passives,
      count(*) FILTER (WHERE r.category = 'detractor') AS detractors,
      round((100.0 * (count(*) FILTER (WHERE r.category = 'promoter') - count(*) FILTER (WHERE r.category = 'detractor')))
            / NULLIF(count(r.id), 0), 1) AS nps_score,
      round(avg(r.score), 2) AS avg_score,
      round(avg(r.points_earned), 2) AS avg_points,
      count(*) FILTER (WHERE r.passed IS TRUE)  AS passed_count,
      count(*) FILTER (WHERE r.passed IS FALSE) AS failed_count,
      coalesce(jsonb_agg(r.answers) FILTER (WHERE r.answers IS NOT NULL AND r.answers <> '{}'::jsonb), '[]'::jsonb) AS all_answers
    FROM camps c
    LEFT JOIN public.survey_responses r ON r.campaign_id = c.id
    GROUP BY c.id, c.name, c.kind, c.questions, c.pass_score
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'campaign_id', agg.campaign_id,
      'campaign_name', agg.campaign_name,
      'kind', agg.kind,
      'pass_score', agg.pass_score,
      'total_responses', agg.total_responses,
      'promoters', agg.promoters,
      'passives', agg.passives,
      'detractors', agg.detractors,
      'nps_score', agg.nps_score,
      'avg_score', agg.avg_score,
      'avg_points', agg.avg_points,
      'passed_count', agg.passed_count,
      'failed_count', agg.failed_count,
      'per_question', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'id', q->>'id',
          'label', q->>'label',
          'type', q->>'type',
          'response_count', (SELECT count(*) FROM jsonb_array_elements(agg.all_answers) a WHERE (a -> (q->>'id')) IS NOT NULL),
          'distribution', (
            SELECT COALESCE(jsonb_object_agg(k, v), '{}'::jsonb) FROM (
              SELECT (a -> (q->>'id'))::text AS k, count(*) AS v
                FROM jsonb_array_elements(agg.all_answers) a
               WHERE (a -> (q->>'id')) IS NOT NULL
               GROUP BY 1
            ) s
          )
        )), '[]'::jsonb)
        FROM jsonb_array_elements(COALESCE(agg.questions, '[]'::jsonb)) q
      )
    )
  ) INTO v_out FROM agg;

  RETURN jsonb_build_object('success', true, 'campaigns', COALESCE(v_out, '[]'::jsonb));
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_survey_analytics(uuid) TO authenticated, service_role;

-- CSV export of survey responses. Returns { success, csv, row_count }.
CREATE OR REPLACE FUNCTION public.export_survey_responses(
  p_campaign_id uuid DEFAULT NULL,
  p_category text DEFAULT NULL,
  p_since timestamptz DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_authorized boolean := (auth.role() = 'service_role') OR public.has_role(auth.uid(), 'admin');
  v_csv text;
  v_count int;
BEGIN
  IF NOT v_authorized THEN RETURN jsonb_build_object('success', false, 'error', 'unauthorized'); END IF;

  WITH rows AS (
    SELECT r.created_at, c.name AS campaign_name, r.recipient_email, r.score, r.category,
           r.points_earned, r.passed, r.comment, r.answers
      FROM public.survey_responses r
      JOIN public.survey_campaigns c ON c.id = r.campaign_id
     WHERE (p_campaign_id IS NULL OR r.campaign_id = p_campaign_id)
       AND (p_category IS NULL OR r.category = p_category)
       AND (p_since IS NULL OR r.created_at >= p_since)
     ORDER BY r.created_at DESC
     LIMIT 10000
  ),
  lines AS (
    SELECT 0 AS ord, 'created_at,campaign,email,score,category,points_earned,passed,comment,answers' AS line
    UNION ALL
    SELECT 1, concat_ws(',',
      to_char(created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      '"' || replace(COALESCE(campaign_name, ''), '"', '""') || '"',
      '"' || replace(COALESCE(recipient_email, ''), '"', '""') || '"',
      COALESCE(score::text, ''),
      COALESCE(category, ''),
      COALESCE(points_earned::text, ''),
      COALESCE(passed::text, ''),
      '"' || replace(COALESCE(comment, ''), '"', '""') || '"',
      '"' || replace(COALESCE(answers::text, ''), '"', '""') || '"'
    ) FROM rows
  )
  SELECT string_agg(line, E'\n' ORDER BY ord),
         count(*) FILTER (WHERE ord = 1)
    INTO v_csv, v_count
    FROM lines;

  RETURN jsonb_build_object('success', true, 'csv', COALESCE(v_csv, ''), 'row_count', COALESCE(v_count, 0));
END;
$$;

GRANT EXECUTE ON FUNCTION public.export_survey_responses(uuid, text, timestamptz) TO authenticated, service_role;