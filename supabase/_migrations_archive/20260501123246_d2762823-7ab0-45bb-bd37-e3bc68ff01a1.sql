UPDATE public.agent_skills
SET mcp_exposed = true, enabled = true
WHERE name IN (
  'migrate_url',
  'extract_pdf_text',
  'scrape_url',
  'search_web',
  'process_signal',
  'sla_check',
  'competitor_monitor'
);

UPDATE public.agent_skills
SET enabled = true
WHERE mcp_exposed = true AND enabled = false;