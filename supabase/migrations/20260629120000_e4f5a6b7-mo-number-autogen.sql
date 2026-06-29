-- Auto-generate manufacturing_orders.mo_number when omitted.
--
-- create_manufacturing_order is a generic-CRUD skill (db:manufacturing_orders)
-- and its callers don't supply mo_number, but the column is NOT NULL with no
-- default — so a generic insert failed. Pairs with the generic-CRUD action
-- inference (create_* skill name → insert instead of the default list) for
-- finding 8e9fbd31. next_mo_number() already exists in the baseline. Idempotent
-- + forward-dated so the Lovable runner applies it.

CREATE OR REPLACE FUNCTION "public"."tg_mo_set_mo_number"() RETURNS "trigger"
LANGUAGE "plpgsql" SET "search_path" TO 'public' AS $$
BEGIN
  IF NEW.mo_number IS NULL OR btrim(NEW.mo_number) = '' THEN
    NEW.mo_number := public.next_mo_number();
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS "trg_mo_set_mo_number" ON "public"."manufacturing_orders";
CREATE TRIGGER "trg_mo_set_mo_number"
  BEFORE INSERT ON "public"."manufacturing_orders"
  FOR EACH ROW EXECUTE FUNCTION "public"."tg_mo_set_mo_number"();

NOTIFY pgrst, 'reload schema';
