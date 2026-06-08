-- Register paid growth skills for existing installations.
-- These skills exist in setup-flowpilot but were never seeded via migration,
-- so existing sites never received them.

DELETE FROM public.agent_skills WHERE name IN (
  'ad_campaign_create', 'ad_creative_generate', 'ad_performance_check', 'ad_optimize'
);

INSERT INTO public.agent_skills (name, description, handler, category, scope, requires_approval, enabled, instructions, tool_definition)
VALUES
(
  'ad_campaign_create',
  'Create a new ad campaign with objective, budget, target audience, and platform. Requires approval due to budget commitment.',
  'edge:ad-campaign-create',
  'growth',
  'internal',
  true,
  true,
  '# ad_campaign_create

Create a new paid ad campaign on Meta, Google, or LinkedIn.

## When to use
- When admin asks to launch a paid campaign
- When an objective needs paid distribution (awareness, leads, conversions)
- After landing_page_compose to drive traffic to the new page

## Important
- ALWAYS requires approval before committing budget
- Budget is in cents (e.g. 5000 = 50 SEK/day)
- Campaigns start as "draft" — no spend until activated externally
- Link to a landing page created with landing_page_compose for best results

## Workflow
1. Confirm campaign goal and budget with admin
2. Create campaign (pending approval)
3. Generate creatives with ad_creative_generate
4. Check performance with ad_performance_check after launch',
  '{
    "type": "function",
    "function": {
      "name": "ad_campaign_create",
      "description": "Create a new ad campaign. Requires approval because it commits budget.",
      "parameters": {
        "type": "object",
        "properties": {
          "name": { "type": "string", "description": "Campaign name" },
          "platform": { "type": "string", "enum": ["meta", "google", "linkedin"], "description": "Ad platform" },
          "objective": { "type": "string", "enum": ["awareness", "traffic", "leads", "conversions"], "description": "Campaign objective" },
          "budget_cents": { "type": "number", "description": "Daily budget in cents" },
          "currency": { "type": "string", "description": "Currency code (default SEK)" },
          "target_audience": { "type": "object", "description": "Target audience config: demographics, interests, location" },
          "start_date": { "type": "string", "description": "Start date YYYY-MM-DD" },
          "end_date": { "type": "string", "description": "End date YYYY-MM-DD" }
        },
        "required": ["name", "platform", "objective", "budget_cents"]
      }
    }
  }'
),
(
  'ad_creative_generate',
  'Generate ad creative (headline, body, CTA) using AI based on campaign objective and target audience.',
  'edge:ad-creative-generate',
  'growth',
  'internal',
  false,
  true,
  '# ad_creative_generate

Generate AI-written ad copy for an existing campaign.

## When to use
- After creating a campaign with ad_campaign_create
- When admin asks to write ad copy for a campaign
- When refreshing underperforming creatives

## What it produces
- Headline (max 40 chars)
- Body text (max 125 chars)
- CTA text (max 20 chars)

Saved as a draft creative linked to the campaign.

## Tips
- Always provide key_message for best results — the AI will use it as the core hook
- Match tone to the campaign objective: "urgent" for conversions, "professional" for B2B leads
- Generate 2-3 variants and let performance data pick the winner',
  '{
    "type": "function",
    "function": {
      "name": "ad_creative_generate",
      "description": "Generate ad copy and creative using AI for an existing campaign.",
      "parameters": {
        "type": "object",
        "properties": {
          "campaign_id": { "type": "string", "description": "Campaign UUID to generate creative for" },
          "type": { "type": "string", "enum": ["image", "video", "text", "carousel"], "description": "Creative type" },
          "tone": { "type": "string", "enum": ["professional", "casual", "urgent", "storytelling"], "description": "Ad tone" },
          "key_message": { "type": "string", "description": "Core message or value proposition" },
          "cta": { "type": "string", "description": "Call to action text" }
        },
        "required": ["campaign_id", "type"]
      }
    }
  }'
),
(
  'ad_performance_check',
  'Check ad campaign performance metrics: spend, impressions, clicks, CTR, CPC, conversions.',
  'edge:ad-performance-check',
  'growth',
  'internal',
  false,
  true,
  '# ad_performance_check

Read performance metrics for one or all ad campaigns.

## When to use
- During heartbeat to monitor active campaigns
- When admin asks "how are our ads doing?"
- Before running ad_optimize to have fresh data

## Key metrics returned
- spend_cents, impressions, clicks, ctr, cpc_cents, conversions

## Decision table
| CTR | Action |
|-----|--------|
| < 0.5% | Consider pausing — use ad_optimize |
| 0.5–2% | Normal range, monitor |
| > 2% | Scale budget — use ad_optimize |',
  '{
    "type": "function",
    "function": {
      "name": "ad_performance_check",
      "description": "Get performance metrics for ad campaigns.",
      "parameters": {
        "type": "object",
        "properties": {
          "campaign_id": { "type": "string", "description": "Campaign UUID (omit for all campaigns)" },
          "period": { "type": "string", "enum": ["today", "week", "month", "all"], "description": "Time period" }
        }
      }
    }
  }'
),
(
  'ad_optimize',
  'Analyze campaign performance and recommend optimizations: pause underperformers, scale winners, adjust budgets. Requires approval.',
  'edge:ad-optimize',
  'growth',
  'internal',
  true,
  true,
  '# ad_optimize

Optimize ad campaigns based on performance data. Always requires approval.

## When to use
- Weekly during heartbeat after ad_performance_check
- When a campaign has run ≥ 3 days with enough data
- When admin asks to optimize or rebalance campaigns

## Actions
- analyze — read-only analysis, no changes (no approval needed in practice but kept consistent)
- pause_underperformers — pause campaigns below CTR threshold
- scale_winners — increase budget on top performers
- rebalance_budget — redistribute budget across campaigns

## Workflow
1. Run ad_performance_check first
2. Run ad_optimize with action=analyze
3. Present recommendations to admin
4. Run with actual action after approval',
  '{
    "type": "function",
    "function": {
      "name": "ad_optimize",
      "description": "Optimize ad campaigns based on performance data. Requires approval for budget changes.",
      "parameters": {
        "type": "object",
        "properties": {
          "campaign_id": { "type": "string", "description": "Campaign UUID to optimize (omit for all)" },
          "action": { "type": "string", "enum": ["analyze", "pause_underperformers", "scale_winners", "rebalance_budget"], "description": "Optimization action" },
          "threshold_ctr": { "type": "number", "description": "Minimum CTR threshold (default 0.5%)" },
          "threshold_cpc_cents": { "type": "number", "description": "Max CPC in cents before pausing" }
        }
      }
    }
  }'
);
