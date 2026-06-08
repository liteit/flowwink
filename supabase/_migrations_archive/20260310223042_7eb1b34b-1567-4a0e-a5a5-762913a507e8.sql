
-- Register resume FlowPilot skills
INSERT INTO public.agent_skills (name, description, handler, category, scope, requires_approval, enabled, instructions, tool_definition)
VALUES
(
  'manage_consultant_profile',
  'Create, update, or list consultant profiles for resume matching',
  'module:resume',
  'content',
  'internal',
  false,
  true,
  'Use this skill to manage the consultant profile database. Actions: "create" (add new consultant), "update" (modify existing), "list" (view all). Always include comprehensive skills arrays and detailed experience_json for best AI matching results.',
  '{
    "type": "function",
    "function": {
      "name": "manage_consultant_profile",
      "description": "Manage consultant profiles — create, update, or list profiles used for AI-powered resume matching",
      "parameters": {
        "type": "object",
        "properties": {
          "action": { "type": "string", "enum": ["create", "update", "list"] },
          "profile_id": { "type": "string", "description": "UUID for update action" },
          "name": { "type": "string" },
          "title": { "type": "string", "description": "Professional title e.g. Senior DevOps Engineer" },
          "skills": { "type": "array", "items": { "type": "string" }, "description": "Technical and soft skills" },
          "experience_years": { "type": "number" },
          "bio": { "type": "string" },
          "summary": { "type": "string", "description": "Professional summary for resume header" },
          "certifications": { "type": "array", "items": { "type": "string" } },
          "languages": { "type": "array", "items": { "type": "string" } },
          "email": { "type": "string" },
          "experience_json": { "type": "array", "description": "Work experience entries [{company, role, period, description}]" },
          "education": { "type": "array", "description": "Education entries [{institution, degree, year}]" }
        },
        "required": ["action"]
      }
    }
  }'::jsonb
),
(
  'match_consultant',
  'Match consultant profiles against a job description with AI scoring, tailored summary and cover letter',
  'module:resume',
  'content',
  'both',
  false,
  true,
  'Use this skill when a visitor or admin provides a job description / assignment brief. The AI will analyze all active consultant profiles and return ranked matches with scores, reasoning, tailored summaries, and professional cover letters. This skill is available to both internal FlowPilot and public chat visitors.',
  '{
    "type": "function",
    "function": {
      "name": "match_consultant",
      "description": "Match consultant profiles against a job description — returns scored matches with tailored CVs and cover letters",
      "parameters": {
        "type": "object",
        "properties": {
          "job_description": { "type": "string", "description": "The job posting or assignment brief to match against" },
          "max_results": { "type": "number", "description": "Max number of matches to return (default 3)" }
        },
        "required": ["job_description"]
      }
    }
  }'::jsonb
);
