-- instance_sync_status() v2 — match migrations by IDENTITY, not by timestamp.
--
-- Stage-3 on rzhj surfaced a real design flaw in v1: it compared the ledger's
-- max(version) against the manifest's filename timestamp. That holds on
-- CLI-deployed instances (supabase db push stamps `version` = the filename
-- timestamp) but NOT on Lovable-managed instances, which stamp `version` with
-- the RUN TIME. So on dev, migration 20260720010000 was applied and readable,
-- yet the ledger HEAD read 20260719211911 (its run time) — a permanent
-- false-red on the schema layer for the one managed instance we watch most.
--
-- Fix: return the applied migrations' identity (version + name) so the consumer
-- can match each repo migration by EITHER its timestamp (CLI) OR its descriptive
-- name (managed) — robust to both stamping conventions. Still exposes the raw
-- head/count for display. Read-only, SECURITY DEFINER + service_role escape,
-- to_regclass-guarded, forward-dated.

CREATE OR REPLACE FUNCTION public.instance_sync_status()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, supabase_migrations
AS $fn$
DECLARE
  v_migration_head  text;
  v_migrations_cnt  bigint;
  v_applied         jsonb := '[]'::jsonb;
  v_skills_total    bigint;
  v_skills_enabled  bigint;
  v_skills_updated  timestamptz;
  v_stamp           jsonb;
BEGIN
  IF NOT (auth.role() = 'service_role' OR public.has_role(auth.uid(), 'admin')) THEN
    RAISE EXCEPTION 'instance_sync_status: admin or service_role required';
  END IF;

  IF to_regclass('supabase_migrations.schema_migrations') IS NOT NULL THEN
    BEGIN
      SELECT max(version), count(*) INTO v_migration_head, v_migrations_cnt
      FROM supabase_migrations.schema_migrations;

      -- Applied identities. Both columns matter: `version` matches CLI-stamped
      -- ledgers, `name` matches managed ledgers (run-time version, but the file's
      -- descriptive name is preserved). Bounded to the most recent 800 — far more
      -- than any repo's migration count, and keeps the payload small.
      SELECT coalesce(jsonb_agg(jsonb_build_object('version', m.version, 'name', m.name)), '[]'::jsonb)
      INTO v_applied
      FROM (
        SELECT version, name
        FROM supabase_migrations.schema_migrations
        ORDER BY version DESC
        LIMIT 800
      ) m;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'instance_sync_status: ledger read failed (%).', SQLERRM;
    END;
  END IF;

  IF to_regclass('public.agent_skills') IS NOT NULL THEN
    SELECT count(*), count(*) FILTER (WHERE enabled), max(updated_at)
    INTO v_skills_total, v_skills_enabled, v_skills_updated
    FROM public.agent_skills;
  END IF;

  SELECT value INTO v_stamp
  FROM public.site_settings WHERE key = 'instance_manifest_stamp';

  RETURN jsonb_build_object(
    'checked_at', now(),
    'schema', jsonb_build_object(
      'migration_head', v_migration_head,
      'migrations_count', v_migrations_cnt,
      'applied', v_applied           -- [{version, name}] — match by either
    ),
    'skills', jsonb_build_object(
      'total', v_skills_total,
      'enabled', v_skills_enabled,
      'last_updated_at', v_skills_updated,
      'stamp', v_stamp
    )
  );
END
$fn$;

GRANT EXECUTE ON FUNCTION public.instance_sync_status() TO anon, authenticated, service_role;
