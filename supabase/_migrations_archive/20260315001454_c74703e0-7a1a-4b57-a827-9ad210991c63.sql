
-- =============================================================================
-- Register missing agent skills — Gap analysis 2026-03-15
-- =============================================================================

-- 1. VISITOR: browse_products (external) — visitors can ask "what do you sell?"
INSERT INTO public.agent_skills (name, description, handler, category, scope, requires_approval, enabled, instructions, tool_definition)
VALUES (
  'browse_products',
  'Search and list available products for visitors. Supports filtering by type, price range, and availability.',
  'module:products',
  'crm',
  'external',
  false,
  true,
  '## Browse Products
Use this skill when a visitor asks about products, pricing, or what is available to buy.
Always present results in a clear format with name, price, and availability.
If track_inventory is enabled and stock is 0, mark as "Out of stock".',
  '{"type":"function","function":{"name":"browse_products","description":"Search and list available products","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["list"],"default":"list"},"search":{"type":"string","description":"Search term to filter products"},"type":{"type":"string","description":"Filter by product type (one_time, subscription)"},"is_active":{"type":"boolean","default":true}},"required":[]}}}'::jsonb
) ON CONFLICT DO NOTHING;

-- 2. VISITOR: check_availability (external) — "when can I book?"
INSERT INTO public.agent_skills (name, description, handler, category, scope, requires_approval, enabled, instructions, tool_definition)
VALUES (
  'check_availability',
  'Check available booking slots for a given date and service.',
  'module:booking',
  'crm',
  'external',
  false,
  true,
  '## Check Availability
When a visitor wants to know available times, use this to check slots.
Return available time windows clearly. If no slots are available, suggest the next available date.',
  '{"type":"function","function":{"name":"check_availability","description":"Check available booking slots for a date","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["check_availability"],"default":"check_availability"},"date":{"type":"string","description":"Date to check (YYYY-MM-DD)"},"service_id":{"type":"string","description":"Optional service ID to filter"}},"required":["date"]}}}'::jsonb
) ON CONFLICT DO NOTHING;

-- 3. VISITOR: browse_services (external) — "what services do you offer?"
INSERT INTO public.agent_skills (name, description, handler, category, scope, requires_approval, enabled, instructions, tool_definition)
VALUES (
  'browse_services',
  'List available booking services with descriptions, durations, and prices.',
  'module:booking',
  'crm',
  'external',
  false,
  true,
  '## Browse Services
Use when visitors ask about services, pricing, or what you offer.
Present each service with name, description, duration, and price.',
  '{"type":"function","function":{"name":"browse_services","description":"List available booking services","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["list_services"],"default":"list_services"}},"required":[]}}}'::jsonb
) ON CONFLICT DO NOTHING;

-- 4. VISITOR: newsletter_subscribe (external) — "subscribe me"
INSERT INTO public.agent_skills (name, description, handler, category, scope, requires_approval, enabled, instructions, tool_definition)
VALUES (
  'newsletter_subscribe',
  'Subscribe a visitor to the newsletter.',
  'edge:newsletter-subscribe',
  'communication',
  'external',
  false,
  true,
  '## Newsletter Subscribe
When a visitor wants to subscribe to the newsletter, collect their email and optionally name.
Confirm the subscription was successful.',
  '{"type":"function","function":{"name":"newsletter_subscribe","description":"Subscribe to the newsletter","parameters":{"type":"object","properties":{"email":{"type":"string","description":"Email address to subscribe"},"name":{"type":"string","description":"Optional subscriber name"}},"required":["email"]}}}'::jsonb
) ON CONFLICT DO NOTHING;

-- 5. VISITOR: browse_blog (external) — "latest articles?"
INSERT INTO public.agent_skills (name, description, handler, category, scope, requires_approval, enabled, instructions, tool_definition)
VALUES (
  'browse_blog',
  'Search and list published blog posts for visitors.',
  'module:blog',
  'content',
  'external',
  false,
  true,
  '## Browse Blog
Use when visitors ask about blog content, articles, or recent posts.
Only return published posts. Include title, excerpt, and publication date.',
  '{"type":"function","function":{"name":"browse_blog","description":"List published blog posts","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["list_published"],"default":"list_published"},"search":{"type":"string","description":"Search term to filter posts"},"limit":{"type":"number","default":5}},"required":[]}}}'::jsonb
) ON CONFLICT DO NOTHING;

-- 6. ADMIN: manage_newsletter_subscribers (internal)
INSERT INTO public.agent_skills (name, description, handler, category, scope, requires_approval, enabled, instructions, tool_definition)
VALUES (
  'manage_newsletter_subscribers',
  'List, search, and manage newsletter subscribers.',
  'module:newsletter',
  'communication',
  'internal',
  false,
  true,
  '## Manage Subscribers
Use to list, search, count, or remove newsletter subscribers.
Support filtering by status (active, unsubscribed, bounced).',
  '{"type":"function","function":{"name":"manage_newsletter_subscribers","description":"Manage newsletter subscribers","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["list","search","count","remove"],"default":"list"},"search":{"type":"string","description":"Search by email or name"},"status":{"type":"string","description":"Filter by status"},"email":{"type":"string","description":"Email for remove action"},"limit":{"type":"number","default":50}},"required":["action"]}}}'::jsonb
) ON CONFLICT DO NOTHING;

-- 7. ADMIN: manage_booking_availability (internal)
INSERT INTO public.agent_skills (name, description, handler, category, scope, requires_approval, enabled, instructions, tool_definition)
VALUES (
  'manage_booking_availability',
  'Set business hours and block dates for bookings.',
  'module:booking',
  'crm',
  'internal',
  false,
  true,
  '## Booking Availability
Manage business hours (day_of_week 0=Sun to 6=Sat) and blocked dates.
Use to set weekly schedule or block specific dates for holidays.',
  '{"type":"function","function":{"name":"manage_booking_availability","description":"Manage business hours and blocked dates","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["list_hours","set_hours","block_date","unblock_date","list_blocked"],"default":"list_hours"},"day_of_week":{"type":"number","description":"0=Sun, 1=Mon...6=Sat"},"start_time":{"type":"string","description":"HH:MM format"},"end_time":{"type":"string","description":"HH:MM format"},"date":{"type":"string","description":"Date to block/unblock (YYYY-MM-DD)"},"reason":{"type":"string","description":"Reason for blocking"}},"required":["action"]}}}'::jsonb
) ON CONFLICT DO NOTHING;

-- 8. ADMIN: manage_orders (internal) — update order status
INSERT INTO public.agent_skills (name, description, handler, category, scope, requires_approval, enabled, instructions, tool_definition)
VALUES (
  'manage_orders',
  'List, view, and update order status. Supports filtering and status changes.',
  'module:orders',
  'crm',
  'internal',
  false,
  true,
  '## Order Management
List orders, view details, update status (pending, paid, shipped, delivered, cancelled, refunded).
Always confirm before changing status to cancelled or refunded.',
  '{"type":"function","function":{"name":"manage_orders","description":"Manage e-commerce orders","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["list","get","update_status","stats"],"default":"list"},"order_id":{"type":"string","description":"Order ID for get/update"},"status":{"type":"string","description":"New status for update_status"},"period":{"type":"string","enum":["today","week","month","quarter"],"default":"month"},"limit":{"type":"number","default":20}},"required":["action"]}}}'::jsonb
) ON CONFLICT DO NOTHING;

-- 9. ADMIN: manage_inventory (internal) — stock management
INSERT INTO public.agent_skills (name, description, handler, category, scope, requires_approval, enabled, instructions, tool_definition)
VALUES (
  'manage_inventory',
  'View and update product inventory levels. Check low stock alerts and update quantities.',
  'module:products',
  'crm',
  'internal',
  false,
  true,
  '## Inventory Management
Track stock levels, identify low-stock products, update quantities.
When updating stock, always confirm the current level first.',
  '{"type":"function","function":{"name":"manage_inventory","description":"Manage product inventory","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["list_stock","update_stock","low_stock_alerts","back_in_stock_requests"],"default":"list_stock"},"product_id":{"type":"string","description":"Product ID for update"},"quantity":{"type":"number","description":"New stock quantity"},"threshold":{"type":"number","description":"Low stock threshold override"}},"required":["action"]}}}'::jsonb
) ON CONFLICT DO NOTHING;

-- 10. ADMIN: manage_blog_categories (internal)
INSERT INTO public.agent_skills (name, description, handler, category, scope, requires_approval, enabled, instructions, tool_definition)
VALUES (
  'manage_blog_categories',
  'Create, list, and manage blog categories and tags.',
  'module:blog',
  'content',
  'internal',
  false,
  true,
  '## Blog Categories & Tags
Manage the taxonomy for blog posts. Create categories with slugs, list existing ones, assign to posts.',
  '{"type":"function","function":{"name":"manage_blog_categories","description":"Manage blog categories and tags","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["list_categories","create_category","list_tags","create_tag"],"default":"list_categories"},"name":{"type":"string","description":"Category/tag name"},"slug":{"type":"string","description":"URL-friendly slug"},"description":{"type":"string","description":"Category description"}},"required":["action"]}}}'::jsonb
) ON CONFLICT DO NOTHING;

-- 11. ADMIN: analyze_chat_feedback (internal)
INSERT INTO public.agent_skills (name, description, handler, category, scope, requires_approval, enabled, instructions, tool_definition)
VALUES (
  'analyze_chat_feedback',
  'Review and analyze chat feedback ratings to identify improvement areas.',
  'module:analytics',
  'analytics',
  'internal',
  false,
  true,
  '## Chat Feedback Analysis
Analyze visitor chat feedback (thumbs up/down) to identify:
- Common questions with negative feedback
- Topics where KB coverage is weak
- Overall satisfaction trends',
  '{"type":"function","function":{"name":"analyze_chat_feedback","description":"Analyze chat feedback ratings","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["summary","negative_only","by_period"],"default":"summary"},"period":{"type":"string","enum":["week","month","quarter"],"default":"month"},"limit":{"type":"number","default":50}},"required":["action"]}}}'::jsonb
) ON CONFLICT DO NOTHING;

-- 12. VISITOR: register_webinar (external) — visitors can register
INSERT INTO public.agent_skills (name, description, handler, category, scope, requires_approval, enabled, instructions, tool_definition)
VALUES (
  'register_webinar',
  'Register a visitor for an upcoming webinar.',
  'module:webinars',
  'communication',
  'external',
  false,
  true,
  '## Webinar Registration
Help visitors register for upcoming webinars. Collect name, email, and optional phone.
Only show upcoming webinars. Confirm registration details.',
  '{"type":"function","function":{"name":"register_webinar","description":"Register for an upcoming webinar","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["list_upcoming","register"],"default":"list_upcoming"},"webinar_id":{"type":"string","description":"Webinar to register for"},"name":{"type":"string","description":"Attendee name"},"email":{"type":"string","description":"Attendee email"},"phone":{"type":"string","description":"Optional phone"}},"required":["action"]}}}'::jsonb
) ON CONFLICT DO NOTHING;
