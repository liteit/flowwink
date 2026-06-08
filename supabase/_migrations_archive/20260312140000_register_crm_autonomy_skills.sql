-- Register qualify_lead and enrich_company as FlowPilot agent skills.
-- FlowPilot objectives and skill instructions already reference these
-- by name, but they were never registered — so FlowPilot could not call them.
-- Also add instructions to prospect_research and prospect_fit_analysis.

-- Remove if already exists (no unique constraint on name)
DELETE FROM public.agent_skills WHERE name IN ('qualify_lead', 'enrich_company');

INSERT INTO public.agent_skills (name, description, handler, category, scope, requires_approval, enabled, instructions, tool_definition)
VALUES
(
  'qualify_lead',
  'Score and qualify a lead using AI analysis of their activity history, engagement data, and profile. Updates lead score and status in the CRM.',
  'edge:qualify-lead',
  'crm',
  'internal',
  false,
  true,
  '# qualify_lead

Use this skill to AI-score and qualify a lead based on their activity history.

## When to use
- When a new lead is created (auto-qualify to establish baseline score)
- After significant lead activity (form submission, page visits, chat engagement)
- As part of lead_pipeline_review to score unqualified leads
- When admin asks to qualify or score a specific lead

## What it does
Fetches the lead + all activities, calculates an AI-powered score (0-100), assigns a qualification status (hot/warm/cold/unqualified), extracts intent signals, and suggests next actions. Updates the lead record in the database.

## Tips
- Always qualify before prospect_research to establish the lead score first
- A score ≥ 70 = hot lead → trigger prospect_research immediately
- Include the lead ID from the CRM leads table',
  '{
    "type": "function",
    "function": {
      "name": "qualify_lead",
      "description": "AI-score and qualify a lead based on activity history and profile data — updates lead score, status, intent signals, and next actions in the CRM",
      "parameters": {
        "type": "object",
        "properties": {
          "leadId": {
            "type": "string",
            "description": "UUID of the lead to qualify"
          }
        },
        "required": ["leadId"]
      }
    }
  }'::jsonb
),
(
  'enrich_company',
  'Enrich a company record with industry, size, description, and contact data by scraping their domain. Updates the company in the CRM.',
  'edge:enrich-company',
  'crm',
  'internal',
  false,
  true,
  '# enrich_company

Use this skill to automatically fill in company data from their domain.

## When to use
- When a new company is created with a domain but missing industry/size/description
- After prospect_research creates a company record
- When admin asks to enrich or update a company profile
- As part of a lead qualification workflow when company data is incomplete

## What it does
Fetches publicly available data about the company from their domain (using configured integrations), extracts industry, company size, description, phone, and address, then persists the enriched data to the companies table.

## Tips
- Provide either domain or companyId (not both needed)
- Skips enrichment if company was already enriched recently
- Chain with prospect_fit_analysis after enrichment for a complete picture',
  '{
    "type": "function",
    "function": {
      "name": "enrich_company",
      "description": "Enrich a company record with industry, size, description, and contact info from their domain — updates the company in the CRM",
      "parameters": {
        "type": "object",
        "properties": {
          "domain": {
            "type": "string",
            "description": "Company domain to enrich (e.g. acme.com)"
          },
          "companyId": {
            "type": "string",
            "description": "UUID of the company record to enrich (alternative to domain)"
          }
        }
      }
    }
  }'::jsonb
);

-- Add instructions to prospect_research and prospect_fit_analysis (missing from initial registration)
UPDATE public.agent_skills
SET instructions = '# prospect_research

Use this skill to deep-research a prospect company before outreach.

## When to use
- When FlowPilot identifies a hot lead (score ≥ 70) and needs context before outreach
- When admin asks to research a prospect or prepare for a meeting
- As part of lead_pipeline_review after qualify_lead surfaces hot leads
- Before running prospect_fit_analysis

## What it does
Chains: web scrape → context search → contact finder → AI analysis.
Creates or updates company and lead records. Generates qualifying Q&A and key insights.

## Skill chain
1. qualify_lead (establish score)
2. prospect_research (deep context)
3. enrich_company (fill company profile)
4. prospect_fit_analysis (fit score + intro letter)'
WHERE name = 'prospect_research' AND (instructions IS NULL OR instructions = '');

UPDATE public.agent_skills
SET instructions = '# prospect_fit_analysis

Use this skill to evaluate strategic fit and generate a personalized introduction letter.

## When to use
- After prospect_research has been run for a company
- When preparing outreach to a decision maker
- When admin asks for a fit score or intro letter for a prospect

## What it does
Loads company data + your sales context, uses contact-finder to identify decision makers,
runs AI fit analysis (score 0-100, problem-solution mapping), and generates a personalized
intro letter addressed to the decision maker.

## Tips
- Always run prospect_research first to have company data populated
- Provide decision_maker_first_name and decision_maker_last_name when known
- The generated intro letter is stored and can be emailed via send_email skill'
WHERE name = 'prospect_fit_analysis' AND (instructions IS NULL OR instructions = '');
