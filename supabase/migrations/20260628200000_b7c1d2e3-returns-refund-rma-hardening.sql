-- Returns hardening — two drift/contract fixes surfaced by OpenClaw Game 2 QA.
--
-- 1. refund_return signature drift. The 4-arg overload (with p_final, which
--    lets an operator close an RMA below the expected total) lives in a
--    backdated migration (20260612110000) that the dev ledger skipped, so dev
--    only had the baseline 3-arg refund_return(uuid,integer,text). The
--    refund_return skill schema declares p_final, so calls with it 404'd with
--    "Could not find function public.refund_return(...) in the schema cache".
--    Recreate the 4-arg version forward-dated and drop the 3-arg so there is
--    exactly one overload (no PostgREST ambiguity).
--
-- 2. create_return rma_number. The skill advertises rma_number as
--    "auto-generated if omitted" and the handler is the generic db:returns
--    CRUD, which never calls generate_rma_number() — so an omitted rma_number
--    hit the NOT NULL column and failed. Auto-generate it at the DB level via
--    a BEFORE INSERT trigger so every writer (MCP, frontend, FlowPilot) is
--    covered. generate_rma_number() already exists in the baseline.
--
-- Idempotent + forward-dated so the Lovable runner applies it (backdated
-- migrations below the ledger HEAD are silently skipped).

-- ── 1. refund_return: single 4-arg overload with p_final ────────────────────
DROP FUNCTION IF EXISTS "public"."refund_return"("uuid", integer, "text");

CREATE OR REPLACE FUNCTION "public"."refund_return"(
  "p_return_id" "uuid",
  "p_refund_cents" integer,
  "p_method" "text" DEFAULT 'manual'::"text",
  "p_final" boolean DEFAULT false
) RETURNS "jsonb"
LANGUAGE "plpgsql" SECURITY DEFINER SET "search_path" TO 'public' AS $$
DECLARE
  v_ret RECORD;
  v_expected bigint;
  v_new_total bigint;
  v_done boolean;
BEGIN
  SELECT * INTO v_ret FROM returns WHERE id = p_return_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Return % not found', p_return_id; END IF;
  IF v_ret.status NOT IN ('received','approved') THEN
    RAISE EXCEPTION 'Return not in refundable state (status %)', v_ret.status;
  END IF;
  IF p_refund_cents IS NULL OR p_refund_cents <= 0 THEN
    RAISE EXCEPTION 'refund_cents must be positive';
  END IF;

  SELECT COALESCE(SUM(quantity * unit_refund_cents), 0) - v_ret.restocking_fee_cents
  INTO v_expected FROM return_items WHERE return_id = p_return_id;
  IF v_expected < 0 THEN v_expected := 0; END IF;

  v_new_total := COALESCE(v_ret.refund_amount_cents, 0) + p_refund_cents;
  IF v_expected > 0 AND v_new_total > v_expected THEN
    RAISE EXCEPTION 'Refund % would exceed expected total % (items − restocking fee %)',
      v_new_total, v_expected, v_ret.restocking_fee_cents;
  END IF;

  v_done := p_final OR (v_expected > 0 AND v_new_total >= v_expected);

  UPDATE returns
     SET refund_amount_cents = v_new_total,
         refund_method = p_method,
         refund_processed_at = now(),
         status = CASE WHEN v_done THEN 'refunded' ELSE status END
   WHERE id = p_return_id;

  RETURN jsonb_build_object('success', true, 'return_id', p_return_id,
    'refunded_cents', v_new_total, 'expected_cents', v_expected,
    'remaining_cents', GREATEST(v_expected - v_new_total, 0),
    'status', CASE WHEN v_done THEN 'refunded' ELSE v_ret.status END);
END $$;

GRANT ALL ON FUNCTION "public"."refund_return"("uuid", integer, "text", boolean)
  TO "anon", "authenticated", "service_role";

-- ── 2. returns.rma_number auto-generation ───────────────────────────────────
CREATE OR REPLACE FUNCTION "public"."tg_returns_set_rma_number"() RETURNS "trigger"
LANGUAGE "plpgsql" SET "search_path" TO 'public' AS $$
BEGIN
  IF NEW.rma_number IS NULL OR btrim(NEW.rma_number) = '' THEN
    NEW.rma_number := public.generate_rma_number();
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS "trg_returns_set_rma_number" ON "public"."returns";
CREATE TRIGGER "trg_returns_set_rma_number"
  BEFORE INSERT ON "public"."returns"
  FOR EACH ROW EXECUTE FUNCTION "public"."tg_returns_set_rma_number"();

NOTIFY pgrst, 'reload schema';
