-- 9 mcp_exposed skills had live descriptions WITHOUT "Use when:" / "NOT for:"
-- markers. For 8 of them the code seeds in src/lib/modules/* were already
-- improved with those markers — the live DB simply never got re-bootstrapped,
-- so the instance carried stale descriptions. Sync the live rows to the code
-- text verbatim (so code == DB, no drift). reset_module_data is DB-only and
-- gets a fresh marker-bearing description.
--
-- The Skill Relevance Engine scores on these markers and external agents read
-- them to choose tools, so missing markers cause mis-selection.
UPDATE public.agent_skills SET description = CASE name
  WHEN 'learn_from_data' THEN 'Analyze page views, chat feedback, and lead conversions to distill learnings into persistent memory. Use when: heartbeat learning cycle; extracting insights from operational data; building institutional knowledge. NOT for: analyzing analytics directly (analyze_analytics); generating business digests (weekly_business_digest).'
  WHEN 'lookup_order' THEN 'Look up order status by order ID or customer email. Use when: a customer inquires about their order; verifying order progress; retrieving order details for support. NOT for: managing orders (manage_orders); browsing products (browse_products).'
  WHEN 'manage_automations' THEN 'Create and manage agent automations (cron jobs, event triggers, signal handlers). Use when: setting up recurring tasks; defining automatic event responses; implementing signal processing logic. NOT for: creating objectives (create_objective); processing incoming signals (process_signal).'
  WHEN 'manage_consultant_profile' THEN 'Manage consultant/resume profiles: list, create, update, delete, deduplicate. Use when: adding a new consultant; updating skills or availability; cleaning up duplicate entries. NOT for: matching consultants to jobs (match_consultant); managing company profiles (manage_company).'
  WHEN 'media_browse' THEN 'Browse, search, and manage media files in the media library. Supports listing, getting URLs, deleting files, and clearing library. Use when: finding an uploaded image; managing media assets; cleaning up unused files. NOT for: uploading new files (N/A); updating site branding logo (site_branding_update).'
  WHEN 'reset_module_data' THEN 'Removes demo/simulation data previously created by seed_module_demo (only rows registered in demo_run_items). Use when: clearing demo data before going live; resetting a module to a clean state. NOT for: deleting real customer data, templates, or KB articles — it never touches those.'
  WHEN 'scan_gmail_inbox' THEN 'Scan connected Gmail inbox for business signals — new leads, partnership inquiries, support requests. Use when: identifying incoming business opportunities from email; automating email categorization; flagging important emails. NOT for: sending emails (composio_gmail_send); managing leads directly (manage_leads).'
  WHEN 'scrape_url' THEN 'Scrape a single URL and extract content as markdown. Supports Firecrawl and Jina Reader. Use when: extracting content from a public webpage; converting web pages to markdown; needing text from an accessible URL. NOT for: accessing login-walled sites (browser_fetch); searching multiple pages (search_web).'
  WHEN 'support_assign_conversation' THEN 'Assign or reassign a support conversation to an agent. Use when: a customer query needs agent attention; re-routing a conversation to a specialist; ensuring no support ticket is unassigned. NOT for: listing conversations (support_list_conversations); getting feedback (support_get_feedback).'
  ELSE description
END
WHERE name IN (
  'learn_from_data','lookup_order','manage_automations','manage_consultant_profile',
  'media_browse','reset_module_data','scan_gmail_inbox','scrape_url','support_assign_conversation'
);
