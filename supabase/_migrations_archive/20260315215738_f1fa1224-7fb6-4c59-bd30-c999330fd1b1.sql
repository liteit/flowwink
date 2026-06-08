
-- Add missing enum values to agent_skill_category
DO $$ BEGIN
  ALTER TYPE public.agent_skill_category ADD VALUE IF NOT EXISTS 'system';
EXCEPTION WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
  ALTER TYPE public.agent_skill_category ADD VALUE IF NOT EXISTS 'commerce';
EXCEPTION WHEN duplicate_object THEN null;
END $$;
