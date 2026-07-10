-- Block cancelling/voiding an invoice that has received money.
--
-- Abort-mid-flow QA 2026-07-10: a HALF-PAID invoice (paid_amount_cents 40000) could be set
-- to status=cancelled with no guard — via the agent skill, the admin UI, or any direct
-- update. The received money then strands on a cancelled invoice: no credit note, no refund
-- trail, and AR views exclude cancelled invoices, so the customer's balance silently
-- disappears from receivables. (Odoo equivalently refuses to cancel an invoice with
-- reconciled payments.)
--
-- Fix: a BEFORE UPDATE trigger rejects the cancelled/void transition while
-- paid_amount_cents > 0, directing to the proper paths (create_credit_note to reverse the
-- billing, or refund + zero the payment first). DB-level so it is path-independent.
-- Idempotent (CREATE OR REPLACE + DROP/CREATE trigger).
create or replace function public.guard_invoice_cancel_with_payments()
returns trigger language plpgsql as $$
begin
  if new.status::text in ('cancelled', 'void')
     and old.status::text not in ('cancelled', 'void')
     and coalesce(new.paid_amount_cents, 0) > 0 then
    raise exception 'Cannot % invoice %: % cents already paid. Reverse the billing with create_credit_note (or refund and clear the payment) before cancelling.',
      new.status, old.invoice_number, new.paid_amount_cents;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_invoice_cancel_with_payments on public.invoices;
create trigger trg_guard_invoice_cancel_with_payments
  before update of status on public.invoices
  for each row execute function public.guard_invoice_cancel_with_payments();
