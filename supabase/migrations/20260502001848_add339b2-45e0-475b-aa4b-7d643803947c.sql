UPDATE public.agent_skills
SET handler = 'edge:subscriptions'
WHERE handler = 'edge:subscriptions-skills';