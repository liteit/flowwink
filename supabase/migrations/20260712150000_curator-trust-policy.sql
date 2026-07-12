-- Skill Curator (FlowPilot 2.0 Phase 3) — pin skill self-modification to 'approve'.
--
-- update_skill_instructions lets an agent rewrite a skill's instructions. In 'proving'
-- posture resolve_agent_trust downgrades approve→notify for FlowPilot — right for business
-- actions (the money core is idempotent + guarded), WRONG for self-modification: an operator
-- editing its own skill contracts must always pass a human, or a bad draft compounds into
-- every future decision. agent_trust_policies rows ALWAYS win over the posture (by design,
-- Magnus 2026-07-10: "enkelt att lägga till en policy om det behövs") — this is that policy.
--
-- Idempotent + forward-dated (managed instances skip backdated files).

insert into public.agent_trust_policies (actor, skill_name, effective_trust_level, note)
select 'flowpilot', 'update_skill_instructions', 'approve',
       'Curator write-path: skill self-modification stays human-gated even in proving posture'
where not exists (
  select 1 from public.agent_trust_policies
   where actor = 'flowpilot' and skill_name = 'update_skill_instructions'
);
