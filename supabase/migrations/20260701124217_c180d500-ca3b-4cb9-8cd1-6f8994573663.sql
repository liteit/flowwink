
UPDATE public.site_settings
SET value = jsonb_build_object(
  'company_name', 'Flowwink Business Operating System',
  'about_us', 'Flowwink is a self-hosted Business Operating System (BOS). Set objectives — FlowPilot, our autonomous AI operator, runs content, leads, orders and growth around the clock. One platform replaces a stack of disconnected SaaS tools with real modules (CRM, accounting, invoicing, HR, projects, e-commerce, support) that agents can operate directly.',
  'services', jsonb_build_object(
    'FlowPilot Autonomous Operator', 'AI operator with soul, objectives, memory and heartbeats — runs your business processes 24/7.',
    'Modular Business OS', '60+ opt-in modules covering CRM, accounting, HR, e-commerce, support and more — turn on what you need.',
    'Agent-Native Platform', 'Every capability exposed as MCP skills so external agents (OpenClaw, Claude, GPT) can operate your business.',
    'Self-Hosted Deployment', 'Ship on your own Supabase project — you own the data, the AI keys and the runtime.'
  ),
  'delivered_value', 'Replace 10+ SaaS subscriptions with one autonomous operating system. FlowPilot executes objectives while you sleep — publishing content, qualifying leads, closing deals, sending invoices, reconciling payments.',
  'clients', 'Founders, operators and agencies who want an AI-first back office instead of duct-taped SaaS.',
  'client_testimonials', '',
  'target_industries', jsonb_build_array('SaaS', 'Consulting', 'Agencies', 'E-commerce', 'Professional Services'),
  'differentiators', jsonb_build_array(
    'Autonomous by default — FlowPilot operates, not just assists',
    'Self-hosted — your data, your AI keys, your runtime',
    'Agent-native — full MCP surface for external operators',
    'One platform — 60+ modules instead of a SaaS stack',
    'Open architecture — modules, skills and blocks are all extensible'
  ),
  'value_proposition', 'The autonomous Business Operating System. Set objectives, FlowPilot operates.',
  'icp', 'Founders and small teams (1–20 people) tired of paying for and gluing together 10+ SaaS tools. Prefer self-hosted, want AI to actually run the business — not just chat about it.',
  'competitors', 'Odoo, HubSpot, Salesforce, Notion, Airtable, Monday, ClickUp — plus vertical SaaS stacks.',
  'pricing_notes', 'Self-hosted open-source core. Bring your own OpenAI/Gemini keys. Optional managed hosting.',
  'industry', 'Business Operating System / AI Automation',
  'contact_email', '',
  'contact_phone', '',
  'address', ''
)::jsonb,
updated_at = now()
WHERE key = 'company_profile';

UPDATE public.site_settings
SET value = to_jsonb('Flowwink Business Operating System'::text),
    updated_at = now()
WHERE key = 'company_name';
