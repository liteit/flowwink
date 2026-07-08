-- mcp_register_fixed_asset: accept both naming conventions an agent may send.
-- OpenClaw finding c33927e2: skill sent acquisition_cost_cents / useful_life_years
-- but the wrapper only read cost_cents / useful_life_months → NOT NULL violation on
-- fixed_assets.cost_cents. Make the wrapper alias-tolerant + convert years→months
-- (fail-forward / agent-safe by construction, not a rigid gate).
CREATE OR REPLACE FUNCTION public.mcp_register_fixed_asset(args jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
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
    COALESCE(args->>'asset_account', args->>'asset_account_code', '1210'),
    COALESCE(args->>'depreciation_account', args->>'depreciation_account_code', '7832'),
    COALESCE(args->>'accumulated_account', args->>'accumulated_account_code', '1219'),
    COALESCE(args->>'credit_account', args->>'credit_account_code', '1930'),
    COALESCE(args->>'description', args->>'notes'),
    COALESCE(NULLIF(args->>'create_journal_entry','')::BOOLEAN, true)
  );
  RETURN to_jsonb(v);
END; $function$;
