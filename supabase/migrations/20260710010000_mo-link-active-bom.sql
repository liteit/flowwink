-- Auto-link a manufacturing order to its product's active BOM on insert.
--
-- Manufacturing QA 2026-07-10: create_manufacturing_order (generic db:manufacturing_orders
-- CRUD) inserts product_id + quantity but leaves bom_id NULL — there is no bom_id skill
-- param and nothing resolved the product's active BOM. A BOM-less MO makes the whole
-- component pipeline blind: check_mo_availability reads mo.bom_id (NULL) → no components →
-- trivially "ok" even when short, and completion consumes no components (finished goods
-- from nothing). An agent that defines a BOM then creates an MO reasonably expects the MO
-- to use it.
--
-- Fix: a BEFORE INSERT trigger links the product's active bom_headers row when bom_id is
-- not explicitly provided — path-independent (agent skill, admin UI, imports all benefit).
-- Idempotent (CREATE OR REPLACE fn + DROP/CREATE trigger).
create or replace function public.mo_link_active_bom()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.bom_id is null and new.product_id is not null then
    select b.id into new.bom_id
      from public.bom_headers b
     where b.product_id = new.product_id and b.is_active = true
     order by b.version desc
     limit 1;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_mo_link_active_bom on public.manufacturing_orders;
create trigger trg_mo_link_active_bom
  before insert on public.manufacturing_orders
  for each row execute function public.mo_link_active_bom();
