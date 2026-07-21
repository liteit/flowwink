-- The mcp_* jsonb wrappers stop overriding the account-role layer.
--
-- Generated from the LIVE definitions (scratchpad/gen-wrappers.py) — bodies
-- untouched except the COALESCE fallbacks. The wrappers predate account_for():
-- they filled absent account args with hardcoded BAS numbers and passed them
-- EXPLICITLY to the inner functions, so the role resolution added on
-- 2026-07-21 never fired for gateway callers — which is exactly the agent
-- path. Found by the money-path regression sweep's pre-flight, before the
-- external agent even ran: the parameter-DEFAULT guardrail cannot see
-- literals inside bodies.
--
-- A caller passing an explicit account still wins; an absent one now flows
-- as NULL into the inner COALESCE(param, account_for(role)).

-- mcp_register_fixed_asset: 4 literal fallback(s) removed
-- mcp_dispose_fixed_asset: 3 literal fallback(s) removed
-- mcp_revalue_open_balances: 4 literal fallback(s) removed

CREATE OR REPLACE FUNCTION public.mcp_register_fixed_asset(args jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v public.fixed_assets;
  v_life_months INT;
BEGIN
  v_life_months := COALESCE(
    NULLIF(args->>'useful_life_months','')::INT,
    NULLIF(args->>'useful_life_years','')::INT * 12
  );
  v := public.register_fixed_asset(
    COALESCE(args->>'name', args->>'asset_name'),
    COALESCE(NULLIF(args->>'cost_cents','')::BIGINT, NULLIF(args->>'acquisition_cost_cents','')::BIGINT, NULLIF(args->>'amount_cents','')::BIGINT),
    v_life_months,
    COALESCE(NULLIF(args->>'purchase_date','')::DATE, NULLIF(args->>'acquisition_date','')::DATE, CURRENT_DATE),
    NULLIF(args->>'in_service_date','')::DATE,
    COALESCE(NULLIF(args->>'salvage_cents','')::BIGINT, NULLIF(args->>'residual_cents','')::BIGINT, 0),
    COALESCE(args->>'depreciation_method', args->>'method', 'straight_line'),
    NULLIF(args->>'declining_rate','')::NUMERIC,
    COALESCE(args->>'asset_account', args->>'asset_account_code'),
    COALESCE(args->>'depreciation_account', args->>'depreciation_account_code'),
    COALESCE(args->>'accumulated_account', args->>'accumulated_account_code'),
    COALESCE(args->>'credit_account', args->>'credit_account_code'),
    COALESCE(args->>'description', args->>'notes'),
    COALESCE(NULLIF(args->>'create_journal_entry','')::BOOLEAN, true)
  );
  RETURN to_jsonb(v);
END; $function$;

CREATE OR REPLACE FUNCTION public.mcp_dispose_fixed_asset(args jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN public.dispose_fixed_asset(
    (args->>'asset_id')::UUID,
    COALESCE((args->>'sale_amount_cents')::BIGINT, 0),
    COALESCE((args->>'disposal_date')::DATE, CURRENT_DATE),
    (args->>'proceeds_account'),
    (args->>'gain_account'),
    (args->>'loss_account')
  );
END; $function$;

CREATE OR REPLACE FUNCTION public.mcp_revalue_open_balances(args jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN public.revalue_open_balances(
    COALESCE((args->>'revaluation_date')::DATE, CURRENT_DATE),
    (args->>'fx_gain_account'),
    (args->>'fx_loss_account'),
    (args->>'ar_account'),
    (args->>'ap_account')
  );
END;
$function$;

