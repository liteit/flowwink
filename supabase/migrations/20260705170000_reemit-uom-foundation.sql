-- Re-emit the UoM foundation (drift fix). Live verification 2026-07-05 found
-- the uoms table EMPTY and convert_uom missing from the schema cache on the
-- dev instance — back-dated migration 20260610170000 was silently skipped by
-- the migration ledger (same class as the July-4 drift batch). The tables
-- themselves exist; the function, grants and seeds never landed.
--
-- Forward-dated, idempotent re-emit of: convert_uom (verbatim body from
-- 20260610170000 — signature p_qty/p_from_uom/p_to_uom, which the convert_uom
-- skill's tool_definition now matches exactly), the default Units seed, and a
-- Weight category (kg reference, g, t) so conversions are demonstrable
-- out of the box.

-- convert_uom: convert a quantity between two UoMs in the SAME category.
CREATE OR REPLACE FUNCTION "public"."convert_uom"(
  "p_qty" numeric, "p_from_uom" "uuid", "p_to_uom" "uuid"
) RETURNS numeric
LANGUAGE "plpgsql" STABLE
SET "search_path" TO 'public'
AS $$
DECLARE
  v_from RECORD;
  v_to RECORD;
BEGIN
  IF p_from_uom = p_to_uom OR p_from_uom IS NULL OR p_to_uom IS NULL THEN
    RETURN p_qty;
  END IF;
  SELECT category_id, factor INTO v_from FROM uoms WHERE id = p_from_uom;
  IF NOT FOUND THEN RAISE EXCEPTION 'UoM % not found', p_from_uom; END IF;
  SELECT category_id, factor INTO v_to FROM uoms WHERE id = p_to_uom;
  IF NOT FOUND THEN RAISE EXCEPTION 'UoM % not found', p_to_uom; END IF;
  IF v_from.category_id <> v_to.category_id THEN
    RAISE EXCEPTION 'Cannot convert between UoMs in different categories';
  END IF;
  RETURN p_qty * v_from.factor / v_to.factor;
END;
$$;

ALTER FUNCTION "public"."convert_uom"(numeric, "uuid", "uuid") OWNER TO "postgres";
GRANT ALL ON FUNCTION "public"."convert_uom"(numeric, "uuid", "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."convert_uom"(numeric, "uuid", "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."convert_uom"(numeric, "uuid", "uuid") TO "service_role";

-- Default "Units" category + reference unit (fixed UUIDs → idempotent)
INSERT INTO "public"."uom_categories" ("id", "name")
VALUES ('11111111-1111-4111-8111-111111111111', 'Units')
ON CONFLICT ("name") DO NOTHING;

INSERT INTO "public"."uoms" ("id", "category_id", "name", "code", "factor", "is_reference")
VALUES ('22222222-2222-4222-8222-222222222222',
        '11111111-1111-4111-8111-111111111111', 'Unit', 'unit', 1, true)
ON CONFLICT ("category_id", "name") DO NOTHING;

-- Weight category: kg (reference), g, t
INSERT INTO "public"."uom_categories" ("id", "name")
VALUES ('33333333-3333-4333-8333-333333333333', 'Weight')
ON CONFLICT ("name") DO NOTHING;

INSERT INTO "public"."uoms" ("id", "category_id", "name", "code", "factor", "is_reference")
VALUES
  ('44444444-4444-4444-8444-444444444441', '33333333-3333-4333-8333-333333333333', 'kg', 'kg', 1, true),
  ('44444444-4444-4444-8444-444444444442', '33333333-3333-4333-8333-333333333333', 'g',  'g',  0.001, false),
  ('44444444-4444-4444-8444-444444444443', '33333333-3333-4333-8333-333333333333', 't',  't',  1000, false)
ON CONFLICT ("category_id", "name") DO NOTHING;
