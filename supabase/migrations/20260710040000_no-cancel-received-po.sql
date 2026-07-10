-- Block cancelling a purchase order that has received goods.
--
-- Abort-mid-flow QA 2026-07-10 (sibling of the paid-invoice cancel guard): a HALF-RECEIVED
-- PO (5 of 10 units already in stock, goods_receipt rows exist) could be set to
-- status=cancelled with no guard. The physical goods and the vendor liability exist, but a
-- cancelled PO reads as "nothing happened" — the vendor's invoice for the delivered units
-- then matches against a cancelled order, and AP/reorder logic mis-reads the state.
--
-- Fix: BEFORE UPDATE trigger rejects cancellation while any line has received_quantity > 0,
-- directing to the proper operations (return the goods to the vendor, or close the PO short
-- via status 'received' — cancel is only for POs where nothing arrived). Path-independent.
-- Idempotent (CREATE OR REPLACE + DROP/CREATE trigger).
create or replace function public.guard_po_cancel_with_receipts()
returns trigger language plpgsql as $$
declare v_received numeric;
begin
  if new.status = 'cancelled' and old.status <> 'cancelled' then
    select coalesce(sum(received_quantity), 0) into v_received
      from public.purchase_order_lines where purchase_order_id = new.id;
    if v_received > 0 then
      raise exception 'Cannot cancel PO %: % units already received. Return the goods to the vendor or close the PO short (status received) instead — cancel is only for POs with no receipts.',
        old.po_number, v_received;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_po_cancel_with_receipts on public.purchase_orders;
create trigger trg_guard_po_cancel_with_receipts
  before update of status on public.purchase_orders
  for each row execute function public.guard_po_cancel_with_receipts();
