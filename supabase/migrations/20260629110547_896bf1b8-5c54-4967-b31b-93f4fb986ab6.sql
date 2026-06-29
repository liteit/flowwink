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