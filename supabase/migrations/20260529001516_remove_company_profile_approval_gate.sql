-- Remove approval gate from update_company_profile
-- Changed to trust_level='auto' so agents can update company profile without approval
-- This enables FlowPilot to rapidly iterate and enrich business identity

UPDATE public.agent_skills
SET trust_level = 'auto'::public.skill_trust_level
WHERE name = 'update_company_profile';

-- TODO: Audit and document the 4 gated skills that exist in agent_skills but are
-- not declared in any module via defineModule(). They still work but won't be
-- enabled/disabled with module lifecycle. Check /admin/approvals "Gated Skills" tab
-- to identify them. Likely candidates:
-- - Possible unowned approval gate skills that need module ownership
