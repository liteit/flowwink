
-- 1. Trust Level enum for agent skills
DO $$ BEGIN
  CREATE TYPE public.skill_trust_level AS ENUM ('auto', 'notify', 'approve');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- 2. Add trust_level column to agent_skills (default 'notify' = safe middle ground)
ALTER TABLE public.agent_skills 
  ADD COLUMN IF NOT EXISTS trust_level public.skill_trust_level NOT NULL DEFAULT 'notify';

-- 3. Migrate existing requires_approval data → trust_level
UPDATE public.agent_skills SET trust_level = 'approve' WHERE requires_approval = true;
UPDATE public.agent_skills SET trust_level = 'auto' WHERE requires_approval = false;

-- 4. Outcome tracking enum
DO $$ BEGIN
  CREATE TYPE public.activity_outcome_status AS ENUM ('pending', 'success', 'partial', 'no_effect', 'negative');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- 5. Add outcome columns to agent_activity
ALTER TABLE public.agent_activity
  ADD COLUMN IF NOT EXISTS outcome_status public.activity_outcome_status DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS outcome_data jsonb DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS outcome_evaluated_at timestamptz DEFAULT NULL;
