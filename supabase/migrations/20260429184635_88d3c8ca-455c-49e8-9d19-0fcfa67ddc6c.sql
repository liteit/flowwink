-- Pull current body and recreate with p_-prefix
DO $$
DECLARE
  v_body text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_body
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname='public' AND p.proname='generate_monthly_expense_report';
  RAISE NOTICE 'Existing definition: %', v_body;
END $$;

DROP FUNCTION IF EXISTS public.generate_monthly_expense_report(text, uuid);

CREATE OR REPLACE FUNCTION public.generate_monthly_expense_report(
  p_period text DEFAULT to_char(CURRENT_DATE, 'YYYY-MM'),
  p_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_report_id uuid;
  v_count int;
  v_period_start date;
  v_period_end date;
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No user_id available');
  END IF;

  v_period_start := to_date(p_period || '-01', 'YYYY-MM-DD');
  v_period_end := (v_period_start + interval '1 month' - interval '1 day')::date;

  -- Reuse existing draft report for the period or create new
  SELECT id INTO v_report_id
  FROM expense_reports
  WHERE user_id = v_user_id AND period = p_period AND status = 'draft'
  LIMIT 1;

  IF v_report_id IS NULL THEN
    INSERT INTO expense_reports (user_id, period, status)
    VALUES (v_user_id, p_period, 'draft')
    RETURNING id INTO v_report_id;
  END IF;

  UPDATE expenses
  SET report_id = v_report_id
  WHERE user_id = v_user_id
    AND report_id IS NULL
    AND status = 'draft'
    AND expense_date BETWEEN v_period_start AND v_period_end;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'success', true,
    'report_id', v_report_id,
    'period', p_period,
    'expenses_attached', v_count
  );
END;
$$;