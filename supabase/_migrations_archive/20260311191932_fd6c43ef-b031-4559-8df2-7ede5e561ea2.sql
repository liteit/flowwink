-- Update search_web skill
UPDATE public.agent_skills
SET 
  handler = 'edge:web-search',
  description = 'Search the web for information. Supports Firecrawl (paid, high quality) and Jina (free tier available). Agent chooses provider based on need.',
  instructions = E'# Web Search — Provider Knowledge\n\n## Providers Available\n- **Firecrawl** (paid): Premium search quality, includes scraped content from results, best for deep research.\n- **Jina Search** (free tier available): Fast, lightweight web search. Good for quick lookups.\n\n## Decision Framework\n1. Default to auto — tries free first, then paid\n2. Use jina for quick fact checks, trend research, cost savings\n3. Use firecrawl for deep research needing full page content\n4. If free returns empty, retry with firecrawl',
  tool_definition = '{"type":"function","function":{"name":"search_web","description":"Search the web. Set preferred_provider based on task needs.","parameters":{"type":"object","properties":{"query":{"type":"string","description":"Search query"},"limit":{"type":"number","description":"Max results (default 5)"},"preferred_provider":{"type":"string","enum":["auto","firecrawl","jina"],"description":"auto (free first), firecrawl (paid, deep), jina (fast, free)"}},"required":["query"]}}}'::jsonb,
  updated_at = now()
WHERE name = 'search_web';

-- Insert scrape_url skill (use DO block to handle upsert without unique constraint)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.agent_skills WHERE name = 'scrape_url') THEN
    INSERT INTO public.agent_skills (name, description, handler, category, scope, requires_approval, enabled, instructions, tool_definition)
    VALUES (
      'scrape_url',
      'Scrape a URL and extract content as markdown. Supports Firecrawl (JS rendering, paid) and Jina Reader (free tier).',
      'edge:web-scrape',
      'search',
      'internal',
      false,
      true,
      E'# Web Scrape — Provider Knowledge\n\n## Providers\n- **Firecrawl** (paid): JS rendering, SPAs, anti-bot. Best for LinkedIn, dynamic sites.\n- **Jina Reader** (free): Clean markdown from static content, blogs, docs.\n\n## Decision Framework\n1. Default auto — free first, paid fallback\n2. jina for blogs, docs, news articles\n3. firecrawl for JS-heavy sites, SPAs, LinkedIn\n4. If content broken/empty, retry with firecrawl',
      '{"type":"function","function":{"name":"scrape_url","description":"Scrape a URL. Set preferred_provider based on site type.","parameters":{"type":"object","properties":{"url":{"type":"string","description":"URL to scrape"},"max_length":{"type":"number","description":"Max content chars (default 10000)"},"preferred_provider":{"type":"string","enum":["auto","firecrawl","jina"],"description":"auto (free first), firecrawl (JS, paid), jina (fast, free)"}},"required":["url"]}}}'::jsonb
    );
  ELSE
    UPDATE public.agent_skills
    SET 
      description = 'Scrape a URL and extract content as markdown. Supports Firecrawl (JS rendering, paid) and Jina Reader (free tier).',
      handler = 'edge:web-scrape',
      instructions = E'# Web Scrape — Provider Knowledge\n\n## Providers\n- **Firecrawl** (paid): JS rendering, SPAs, anti-bot. Best for LinkedIn, dynamic sites.\n- **Jina Reader** (free): Clean markdown from static content, blogs, docs.\n\n## Decision Framework\n1. Default auto — free first, paid fallback\n2. jina for blogs, docs, news articles\n3. firecrawl for JS-heavy sites, SPAs, LinkedIn\n4. If content broken/empty, retry with firecrawl',
      tool_definition = '{"type":"function","function":{"name":"scrape_url","description":"Scrape a URL. Set preferred_provider based on site type.","parameters":{"type":"object","properties":{"url":{"type":"string","description":"URL to scrape"},"max_length":{"type":"number","description":"Max content chars (default 10000)"},"preferred_provider":{"type":"string","enum":["auto","firecrawl","jina"],"description":"auto (free first), firecrawl (JS, paid), jina (fast, free)"}},"required":["url"]}}}'::jsonb,
      updated_at = now()
    WHERE name = 'scrape_url';
  END IF;
END $$;