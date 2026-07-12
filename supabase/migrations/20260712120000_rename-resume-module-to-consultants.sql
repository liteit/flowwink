-- Rename the "resume" module → "consultants" across every per-instance wire footprint.
--
-- The module already DISPLAYED as "Consultants" (name field); this migration carries the
-- runtime identifiers that live in each instance's DB so the code rename (module id
-- 'resume'→'consultants', block type 'resume-matcher'→'consultant-matcher', edge fn
-- 'resume-match'→'consultant-match') does not strand them. Owner-authorized full wire rename
-- (Magnus 2026-07-12). "resume" the module ≠ "resume" the CV artifact (parse_resume,
-- resume_url in the recruitment module) — those are deliberately untouched.
--
-- Idempotent (safe to re-run): every statement is guarded so a second run is a no-op.
-- Forward-dated so managed/forked instances (whose migrate runner skips backdated files)
-- actually apply it.

-- 1. Skill handlers — dispatch now routes 'module:consultants' / 'edge:consultant-match'.
update public.agent_skills
   set handler = 'module:consultants', updated_at = now()
 where handler = 'module:resume';

update public.agent_skills
   set handler = 'edge:consultant-match', updated_at = now()
 where handler = 'edge:resume-match';

-- 2. Module enable/config flag — useModules drops keys absent from defaults, so the
--    'resume' enabled state must move to 'consultants' or the module reads as disabled.
--    Preserve whatever value the instance had; the old key is removed.
update public.site_settings
   set value = (value - 'resume') || jsonb_build_object('consultants', value -> 'resume')
 where key = 'modules'
   and jsonb_typeof(value) = 'object'
   and value ? 'resume';

-- 3. Stored page content — the block type on any published/draft page. Top-level blocks
--    (how the matcher block is placed by templates). Containment guard makes it idempotent.
update public.pages
   set content_json = (
         select jsonb_agg(
                  case when block ->> 'type' = 'resume-matcher'
                       then jsonb_set(block, '{type}', '"consultant-matcher"')
                       else block
                  end
                )
           from jsonb_array_elements(content_json) as block
       ),
       updated_at = now()
 where jsonb_typeof(content_json) = 'array'
   and content_json @> '[{"type":"resume-matcher"}]'::jsonb;

-- 4. RBAC — role→module access grants keyed by module id (only if the table/rows exist).
do $$
begin
  if to_regclass('public.role_module_access') is not null then
    update public.role_module_access
       set module_id = 'consultants'
     where module_id = 'resume';
  end if;
end $$;

-- 5. Bootstrap run history — cosmetic, keeps the audit log consistent with the new id.
do $$
begin
  if to_regclass('public.bootstrap_runs') is not null then
    update public.bootstrap_runs
       set module_id = 'consultants'
     where module_id = 'resume';
  end if;
end $$;
