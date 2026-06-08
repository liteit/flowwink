DELETE FROM public.agent_skills WHERE name IN ('get_contract_content','search_contracts','send_contract_for_signature');

INSERT INTO public.agent_skills (name, description, category, handler, scope, tool_definition, instructions, enabled, mcp_exposed, origin, trust_level) VALUES
('get_contract_content',
 'Fetch the full markdown body of a contract for LLM consumption. Use when: external operator (ClawWink) or agent needs to read, summarize, or analyze the actual agreement text. Returns title, counterparty, status, value and the entire body_markdown. NOT for: listing contracts (use manage_contract action=list) or attached PDFs (use list_contract_documents).',
 'commerce', 'db:contracts', 'internal',
 '{"type":"function","function":{"name":"get_contract_content","description":"Return contract metadata + full markdown body — LLM-friendly, no parsing required.","parameters":{"type":"object","properties":{"contract_id":{"type":"string","description":"UUID of the contract"}},"required":["contract_id"]}}}'::jsonb,
 'Query public.contracts by id. Return id, title, counterparty_name, counterparty_email, status, contract_type, value_cents, currency, start_date, end_date, signed_at, version and body_markdown. The body_markdown field is the source of truth — pass directly to LLM context.',
 true, true, 'bundled', 'auto'),
('search_contracts',
 'Free-text search across contracts (title, counterparty, body content) using pg_trgm fuzzy matching. Use when: admin or operator asks "hitta avtalet med X", "vilka avtal nämner Y-klausul", "sök NDA med ACME". NOT for: filtering by status only (use manage_contract action=list with status).',
 'commerce', 'db:contracts', 'internal',
 '{"type":"function","function":{"name":"search_contracts","description":"Trigram + ILIKE search across title, counterparty_name and body_markdown.","parameters":{"type":"object","properties":{"query":{"type":"string","description":"Search terms"},"limit":{"type":"number","description":"Max results (default 10)"},"status":{"type":"string","enum":["draft","pending_signature","active","expired","terminated"],"description":"Optional status filter"}},"required":["query"]}}}'::jsonb,
 'Use pg_trgm similarity + ILIKE on title, counterparty_name and body_markdown. Sort by similarity DESC. Return id, title, counterparty_name, status and snippet (first 200 chars of matching body section).',
 true, true, 'bundled', 'auto'),
('send_contract_for_signature',
 'Generate a public signing link for a contract and mark it as pending_signature. Use when: admin or operator wants to send a finished contract to the counterparty for signing. Snapshots the current version, returns a /contract/:token URL the counterparty can visit to accept/reject without logging in. NOT for: creating contracts or signing on behalf of someone.',
 'commerce', 'db:contracts', 'internal',
 '{"type":"function","function":{"name":"send_contract_for_signature","description":"Issue a public signing token + URL for a contract that has body_markdown filled in.","parameters":{"type":"object","properties":{"contract_id":{"type":"string","description":"UUID of the contract"}},"required":["contract_id"]}}}'::jsonb,
 'Verify contract.body_markdown is non-empty (refuse if blank — "write the agreement first"). Snapshot to contract_versions, generate accept_token if missing, set status=pending_signature, sent_at=now(). Return { url, token, version }. URL pattern: {site_origin}/contract/{token}.',
 true, true, 'bundled', 'auto');