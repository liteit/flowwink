-- check_order_status pointed at `edge:order-status`, an edge function that was
-- never created → the skill failed on every instance where ecommerce/orders is
-- enabled (found via a cross-instance handler sweep). executeOrdersAction
-- already handles check_order_status by skill name, so route it through
-- `module:orders` exactly like the sibling lookup_order skill. Idempotent.
UPDATE public.agent_skills
SET handler = 'module:orders'
WHERE name = 'check_order_status'
  AND handler = 'edge:order-status';
