-- Disable broken ticket_triage skill (handler 'ticket_triage' has no prefix → unreachable in agent-execute).
-- Source-of-truth seed has been removed; this drops the orphan DB row from MCP exposure.
UPDATE agent_skills
SET enabled = false, mcp_exposed = false
WHERE name = 'ticket_triage';

-- Sharpen Use-when on prospecting skills so FlowChat picks them when the user
-- asks for prospects even with zero existing customers.
UPDATE agent_skills
SET description = 'Find business contacts and decision-makers by company domain or industry. Use when: prospecting for new leads, finding email addresses for outreach, building target lists from scratch (even when no existing customers exist yet), researching companies in a sector. NOT for: managing existing leads (use manage_leads); creating a single new lead manually (use add_lead).'
WHERE name = 'contact_finder';

UPDATE agent_skills
SET description = 'Scrape a company website to enrich its record with website, phone, industry, size, and description. Use when: enriching a prospect after finding them; auto-populating company data from a domain; building target-account profiles. NOT for: researching individual people (prospect_research); basic CRUD on companies (manage_company).'
WHERE name = 'enrich_company';

UPDATE agent_skills
SET description = 'Search the web for information. Supports Firecrawl and Jina providers. Use when: researching companies/markets/competitors; finding prospect lists from public sources; answering questions requiring current web data; sourcing news or reports. NOT for: scraping a specific URL (scrape_url); fetching login-walled content (browser_fetch).'
WHERE name = 'search_web';