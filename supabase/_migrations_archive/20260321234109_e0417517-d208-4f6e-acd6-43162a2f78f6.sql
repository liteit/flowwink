-- Add origin tracking to skills (OpenClaw-aligned: bundled/managed/workspace)
DO $$ BEGIN
  CREATE TYPE public.skill_origin AS ENUM ('bundled', 'managed', 'agent', 'user');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

ALTER TABLE public.agent_skills 
  ADD COLUMN IF NOT EXISTS origin public.skill_origin NOT NULL DEFAULT 'bundled';

-- Mark existing skills as bundled (they were all code-seeded)
UPDATE public.agent_skills SET origin = 'bundled' WHERE origin IS NULL OR origin = 'bundled';

COMMENT ON COLUMN public.agent_skills.origin IS 'Origin of skill: bundled (code-seeded), managed (installed from skill pack), agent (self-created by FlowPilot), user (manually created in admin UI)';